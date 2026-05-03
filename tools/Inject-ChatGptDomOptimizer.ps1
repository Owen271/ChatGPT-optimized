param(
  [int]$Port = 9222,
  [int]$RecentLimit = 40,
  [int]$IntrinsicSize = 520,
  [ValidateSet("Auto", "Hidden")]
  [string]$Mode = "Auto",
  [switch]$Aggressive,
  [int]$AggressiveKeep = 120,
  [switch]$DebugOptimizer,
  [switch]$Wait,
  [int]$WaitSeconds = 30
)

$ErrorActionPreference = "Stop"

function Read-TextFile {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path)
}

function Get-Json {
  param([string]$Url)
  return Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 3
}

function Wait-ForDebugger {
  param([int]$Port, [int]$WaitSeconds)

  $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
  do {
    try {
      return Get-Json "http://127.0.0.1:$Port/json/version"
    } catch {
      Start-Sleep -Milliseconds 500
    }
  } while ([DateTime]::UtcNow -lt $deadline)

  throw "No Chromium DevTools endpoint responded on 127.0.0.1:$Port. Start ChatGPT with --remote-debugging-port=$Port first."
}

function Find-ChatGptTarget {
  param([int]$Port)

  $targets = @(Get-Json "http://127.0.0.1:$Port/json/list")
  $pages = @($targets | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl })
  $chatTargets = @(
    $pages | Where-Object {
      ($_.url -match "chatgpt\.com") -or
      ($_.title -match "ChatGPT") -or
      ($_.url -match "openai")
    }
  )

  if ($chatTargets.Count -gt 0) {
    return $chatTargets[0]
  }
  if ($pages.Count -gt 0) {
    return $pages[0]
  }

  throw "DevTools is reachable, but no page target was found."
}

function Receive-WebSocketMessage {
  param(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [int]$TimeoutSeconds = 10
  )

  $buffer = [byte[]]::new(1048576)
  $segment = [ArraySegment[byte]]::new($buffer)
  $builder = [System.Text.StringBuilder]::new()
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

  do {
    $task = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
    while (-not $task.IsCompleted) {
      if ([DateTime]::UtcNow -ge $deadline) {
        throw "Timed out waiting for a DevTools response."
      }
      Start-Sleep -Milliseconds 25
    }

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

  $message = @{
    id = $Id
    method = $Method
    params = $Params
  } | ConvertTo-Json -Depth 20 -Compress

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
  [void]$Socket.SendAsync(
    [ArraySegment[byte]]::new($bytes),
    [System.Net.WebSockets.WebSocketMessageType]::Text,
    $true,
    [Threading.CancellationToken]::None
  ).GetAwaiter().GetResult()

  while ($true) {
    $raw = Receive-WebSocketMessage -Socket $Socket
    $json = $raw | ConvertFrom-Json
    if ($json.id -eq $Id) {
      if ($json.error) {
        throw "CDP command $Method failed: $($json.error.message)"
      }
      return $json
    }
  }
}

function Convert-ToJavaScriptLiteral {
  param([object]$Value)
  return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadPath = Join-Path $scriptDir "chatgpt-dom-optimizer.payload.js"
if (-not (Test-Path $payloadPath)) {
  throw "Payload not found: $payloadPath"
}

if ($Wait) {
  [void](Wait-ForDebugger -Port $Port -WaitSeconds $WaitSeconds)
} else {
  try {
    [void](Get-Json "http://127.0.0.1:$Port/json/version")
  } catch {
    throw "No Chromium DevTools endpoint responded on 127.0.0.1:$Port. Start ChatGPT with Start-ChatGPTOptimized.cmd, or launch ChatGPT with --remote-debugging-port=$Port first."
  }
}

$target = Find-ChatGptTarget -Port $Port
$options = @{
  recentLimit = $RecentLimit
  intrinsicSize = $IntrinsicSize
  mode = $Mode.ToLowerInvariant()
  aggressive = [bool]$Aggressive
  aggressiveKeep = $AggressiveKeep
  debug = [bool]$DebugOptimizer
}

$payload = Read-TextFile $payloadPath
$expression = @"
(function () {
  const options = $(Convert-ToJavaScriptLiteral $options);
  const source = $(Convert-ToJavaScriptLiteral $payload);
  return eval(source.replace(/\}\)\(\{ recentLimit: 40 \}\);\s*$/, "})(" + JSON.stringify(options) + ");"));
})()
"@

$socket = [System.Net.WebSockets.ClientWebSocket]::new()
try {
  [void]$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  [void](Send-CdpCommand -Socket $socket -Id 1 -Method "Runtime.enable")
  [void](Send-CdpCommand -Socket $socket -Id 2 -Method "Page.enable")
  [void](Send-CdpCommand -Socket $socket -Id 3 -Method "Page.addScriptToEvaluateOnNewDocument" -Params @{ source = $expression })
  $result = Send-CdpCommand -Socket $socket -Id 4 -Method "Runtime.evaluate" -Params @{
    expression = $expression
    awaitPromise = $true
    returnByValue = $true
  }

  $status = $result.result.result.value | ConvertTo-Json -Depth 10
  Write-Host "Injected ChatGPT DOM optimizer into: $($target.title) [$($target.url)]"
  Write-Host $status
  Write-Host ""
  Write-Host "Runtime controls available in the ChatGPT page console:"
  Write-Host "  window.__chatgptDomOptimizer.status()"
  Write-Host "  window.__chatgptDomOptimizer.setRecentLimit(40)"
  Write-Host "  window.__chatgptDomOptimizer.disable()"
  Write-Host "  window.__chatgptDomOptimizer.enable()"
} finally {
  $socket.Dispose()
}
