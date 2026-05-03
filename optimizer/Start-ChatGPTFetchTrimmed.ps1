param(
  [int]$Port = 9222,
  [int]$KeepMessages = 40,
  [int]$MonitorSeconds = 60,
  [switch]$Restart,
  [string]$ConversationUrl,
  [string]$ExePath,
  [switch]$StayResident,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Test-DebuggerPort {
  param([int]$Port)
  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -UseBasicParsing -TimeoutSec 2 | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Find-ChatGptExe {
  param([string]$ExePath)
  if ($ExePath) {
    if (Test-Path $ExePath) { return (Resolve-Path $ExePath).Path }
    throw "The provided ChatGPT executable path does not exist: $ExePath"
  }

  $package = Get-AppxPackage -Name "OpenAI.ChatGPT-Desktop" -ErrorAction SilentlyContinue
  if ($package -and $package.InstallLocation) {
    $candidate = Join-Path $package.InstallLocation "app\ChatGPT.exe"
    if (Test-Path $candidate) { return $candidate }
  }

  $matches = @(Get-ChildItem -Path "C:\Program Files\WindowsApps" -Directory -Filter "OpenAI.ChatGPT-Desktop_*" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
      $candidate = Join-Path $_.FullName "app\ChatGPT.exe"
      if (Test-Path $candidate) { $candidate }
    })
  if ($matches.Count -gt 0) { return $matches[0] }
  throw "Could not find ChatGPT.exe."
}

function Get-Json {
  param([string]$Url)
  return Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 3
}

function Write-Status {
  param([string]$Message)
  if (-not $Quiet) { Write-Host $Message }
}

function Get-PageTargets {
  param([int]$Port, [int]$WaitSeconds = 45)
  $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
  do {
    $targets = @(Get-Json "http://127.0.0.1:$Port/json/list")
    $pages = @($targets | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl })
    $chatTargets = @($pages | Where-Object { $_.url -match "chatgpt\.com" -or $_.title -match "ChatGPT" })
    if ($chatTargets.Count -gt 0) { return $chatTargets }
    if ($pages.Count -gt 0) { return $pages }
    Start-Sleep -Milliseconds 500
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "No page target found on port $Port."
}

function Receive-WebSocketMessage {
  param([System.Net.WebSockets.ClientWebSocket]$Socket)
  $buffer = [byte[]]::new(1048576)
  $segment = [ArraySegment[byte]]::new($buffer)
  $builder = [System.Text.StringBuilder]::new()
  do {
    $task = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
    while (-not $task.IsCompleted) { Start-Sleep -Milliseconds 25 }
    if ($task.Result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
      throw "DevTools WebSocket closed unexpectedly."
    }
    [void]$builder.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $task.Result.Count))
  } while (-not $task.Result.EndOfMessage)
  return $builder.ToString()
}

function Send-CdpCommand {
  param(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [int]$Id,
    [string]$Method,
    [hashtable]$Params = @{}
  )
  $message = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 50 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
  [void]$Socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  while ($true) {
    $raw = Receive-WebSocketMessage -Socket $Socket
    $json = $raw | ConvertFrom-Json
    if ($json.id -eq $Id) {
      if ($json.error) { throw "CDP command $Method failed: $($json.error.message)" }
      if ($json.result -and $json.result.exceptionDetails) {
        $text = $json.result.exceptionDetails.text
        $description = $json.result.exceptionDetails.exception.description
        throw "CDP command $Method threw in the page: $text $description"
      }
      return $json
    }
  }
}

function Convert-ToJavaScriptLiteral {
  param([object]$Value)
  return ($Value | ConvertTo-Json -Depth 50 -Compress)
}

function Install-TrimmerIntoTarget {
  param(
    [object]$Target,
    [string]$Expression,
    [string]$ConversationUrl,
    [switch]$KeepAlive
  )

  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  try {
    [void]$socket.ConnectAsync([Uri]$Target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    [void](Send-CdpCommand -Socket $socket -Id 1 -Method "Runtime.enable")
    [void](Send-CdpCommand -Socket $socket -Id 2 -Method "Page.enable")
    [void](Send-CdpCommand -Socket $socket -Id 3 -Method "Page.addScriptToEvaluateOnNewDocument" -Params @{ source = $Expression })
    [void](Send-CdpCommand -Socket $socket -Id 4 -Method "Runtime.evaluate" -Params @{ expression = $Expression; awaitPromise = $true; returnByValue = $true })

    if ($ConversationUrl) {
      [void](Send-CdpCommand -Socket $socket -Id 5 -Method "Page.navigate" -Params @{ url = $ConversationUrl })
      return [pscustomobject]@{ Action = "navigated"; Socket = if ($KeepAlive) { $socket } else { $null } }
    }

    if ([string]$Target.url -match "https://chatgpt\.com/c/[0-9a-fA-F-]{20,}") {
      [void](Send-CdpCommand -Socket $socket -Id 5 -Method "Page.reload" -Params @{ ignoreCache = $true })
      return [pscustomobject]@{ Action = "reloaded"; Socket = if ($KeepAlive) { $socket } else { $null } }
    }

    return [pscustomobject]@{ Action = "installed"; Socket = if ($KeepAlive) { $socket } else { $null } }
  } finally {
    if (-not $KeepAlive) {
      $socket.Dispose()
    }
  }
}

if ($KeepMessages -lt 10) { throw "KeepMessages must be at least 10." }

$existing = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
  if ($Restart) {
    Write-Status "Stopping existing ChatGPT so it can be relaunched with the optimizer..."
    $existing | Stop-Process -Force
    Start-Sleep -Seconds 2
  } elseif (-not (Test-DebuggerPort -Port $Port)) {
    throw "ChatGPT is already running, but DevTools port $Port is not active. Close ChatGPT first, or run this script with -Restart."
  }
}

if (-not (Test-DebuggerPort -Port $Port)) {
  $chatGptExe = Find-ChatGptExe -ExePath $ExePath
  Write-Status "Starting ChatGPT with optimizer support..."
  Start-Process -FilePath $chatGptExe -ArgumentList "--remote-debugging-port=$Port"
  $deadline = [DateTime]::UtcNow.AddSeconds(45)
  while (-not (Test-DebuggerPort -Port $Port)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw "ChatGPT did not expose DevTools port $Port in time." }
    Start-Sleep -Milliseconds 500
  }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadPath = Join-Path $scriptDir "chatgpt-fetch-trimmer.payload.js"
$payload = [System.IO.File]::ReadAllText($payloadPath)
$options = @{ keepMessages = $KeepMessages }
$expression = @"
(function () {
  const options = $(Convert-ToJavaScriptLiteral $options);
  const source = $(Convert-ToJavaScriptLiteral $payload);
  return eval(source.replace(/\}\)\(\{ keepMessages: 40 \}\);\s*$/, "})(" + JSON.stringify(options) + ");"));
})()
"@

$seen = @{}
$sessions = @{}
$navigated = $false
$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $MonitorSeconds))
Write-Status "Installing fetch trimmer. Keeping latest $KeepMessages messages..."

$installedAny = $false
function Install-AvailableTargets {
  $targets = @(Get-PageTargets -Port $Port -WaitSeconds 5)
  foreach ($target in $targets) {
    if ($seen.ContainsKey($target.id)) { continue }

    $urlToNavigate = $null
    if ($ConversationUrl -and -not $navigated) {
      $urlToNavigate = $ConversationUrl
    }

    try {
      $result = Install-TrimmerIntoTarget -Target $target -Expression $expression -ConversationUrl $urlToNavigate -KeepAlive:$StayResident
      $seen[$target.id] = $true
      if ($result.Socket) {
        $sessions[$target.id] = $result.Socket
      }
      Set-Variable -Name installedAny -Value $true -Scope 1
      $installedAny = $true
      if ($urlToNavigate) { $navigated = $true }
      Set-Variable -Name navigated -Value $navigated -Scope 1
      Write-Status "Optimizer $($result.Action) for target: $($target.title) [$($target.url)]"
    } catch {
      Write-Status "Could not inject target $($target.id): $($_.Exception.Message)"
    }
  }
}

do {
  Install-AvailableTargets
  Start-Sleep -Milliseconds 750
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $installedAny) {
  throw "No ChatGPT page target accepted the optimizer."
}

Write-Status "Optimizer ready. Check with: window.__chatgptFetchTrimmer.status()"

if ($StayResident) {
  Write-Status "Resident helper active until ChatGPT exits."
  try {
    while (@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue).Count -gt 0) {
      Install-AvailableTargets
      Start-Sleep -Seconds 2
    }
  } finally {
    foreach ($socket in $sessions.Values) {
      try { $socket.Dispose() } catch {}
    }
  }
}
