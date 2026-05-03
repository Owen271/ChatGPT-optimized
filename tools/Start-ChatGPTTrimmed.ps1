param(
  [int]$Port = 9222,
  [int]$KeepMessages = 80,
  [int]$TimeoutSeconds = 120,
  [switch]$Restart,
  [string]$ExePath,
  [string]$ConversationUrl
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

  $known = "C:\Program Files\WindowsApps\OpenAI.ChatGPT-Desktop_1.2026.43.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe"
  if (Test-Path $known) { return $known }

  $matches = @()
  try {
    $matches = @(Get-ChildItem -Path "C:\Program Files\WindowsApps" -Directory -Filter "OpenAI.ChatGPT-Desktop_*" -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object {
        $candidate = Join-Path $_.FullName "app\ChatGPT.exe"
        if (Test-Path $candidate) { $candidate }
      })
  } catch {
    $matches = @()
  }

  if ($matches.Count -gt 0) { return $matches[0] }
  throw "Could not find ChatGPT.exe. Re-run with -ExePath `"C:\Program Files\WindowsApps\...\ChatGPT.exe`"."
}

function Get-Json {
  param([string]$Url)
  return Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 3
}

function Receive-WebSocketMessage {
  param([System.Net.WebSockets.ClientWebSocket]$Socket, [int]$TimeoutSeconds = 120)

  $buffer = [byte[]]::new(4194304)
  $segment = [ArraySegment[byte]]::new($buffer)
  $builder = [System.Text.StringBuilder]::new()
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

  do {
    $task = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
    while (-not $task.IsCompleted) {
      if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for DevTools." }
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

  $message = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 50 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
  [void]$Socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Wait-CdpCommand {
  param(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [int]$Id,
    [int]$TimeoutSeconds = 120
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $raw = Receive-WebSocketMessage -Socket $Socket -TimeoutSeconds $TimeoutSeconds
    $json = $raw | ConvertFrom-Json
    if ($json.id -eq $Id) {
      if ($json.error) { throw "CDP command failed: $($json.error.message)" }
      return $json
    }
  }
  throw "Timed out waiting for command $Id."
}

function Invoke-CdpCommand {
  param(
    [System.Net.WebSockets.ClientWebSocket]$Socket,
    [ref]$NextId,
    [string]$Method,
    [hashtable]$Params = @{}
  )

  $id = $NextId.Value
  $NextId.Value += 1
  Send-CdpCommand -Socket $Socket -Id $id -Method $Method -Params $Params
  return Wait-CdpCommand -Socket $Socket -Id $id
}

function Get-PageTarget {
  param([int]$Port, [int]$WaitSeconds = 45)
  $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
  do {
    $targets = @(Get-Json "http://127.0.0.1:$Port/json/list")
    $chatTargets = @($targets | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl -and $_.url -match "chatgpt\.com" })
    if ($chatTargets.Count -gt 0) { return $chatTargets[0] }
    $pages = @($targets | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl })
    if ($pages.Count -gt 0) { return $pages[0] }
    Start-Sleep -Milliseconds 500
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "No page target found on port $Port."
}

function Trim-ConversationJson {
  param(
    [string]$Body,
    [int]$KeepMessages
  )

  $json = $Body | ConvertFrom-Json
  if (-not $json.mapping -or -not $json.current_node) {
    return @{
      changed = $false
      body = $Body
      originalNodes = 0
      keptNodes = 0
      originalMessages = 0
      keptMessages = 0
    }
  }

  $mappingProps = @($json.mapping.PSObject.Properties)
  $originalNodes = $mappingProps.Count
  $originalMessages = @($mappingProps | Where-Object { $_.Value.message }).Count
  if ($originalMessages -le $KeepMessages) {
    return @{
      changed = $false
      body = $Body
      originalNodes = $originalNodes
      keptNodes = $originalNodes
      originalMessages = $originalMessages
      keptMessages = $originalMessages
    }
  }

  $chain = New-Object System.Collections.Generic.List[string]
  $id = [string]$json.current_node
  $guard = 0
  while ($id -and $json.mapping.PSObject.Properties[$id] -and $guard -lt 10000) {
    $chain.Add($id)
    $node = $json.mapping.PSObject.Properties[$id].Value
    $id = if ($node.parent) { [string]$node.parent } else { $null }
    $guard += 1
  }

  [array]::Reverse($chain.ToArray())
  $ordered = @($chain.ToArray())
  $messageIds = @($ordered | Where-Object { $json.mapping.PSObject.Properties[$_].Value.message })
  $keptMessageIds = @($messageIds | Select-Object -Last $KeepMessages)

  $keep = [ordered]@{}
  $rootId = $null
  foreach ($candidate in $ordered) {
    $node = $json.mapping.PSObject.Properties[$candidate].Value
    if (-not $node.message) {
      $rootId = $candidate
      $keep[$candidate] = $true
      break
    }
  }
  foreach ($messageId in $keptMessageIds) {
    $keep[$messageId] = $true
  }

  $newMapping = [ordered]@{}
  foreach ($keepId in $keep.Keys) {
    $copy = $json.mapping.PSObject.Properties[$keepId].Value
    $children = @()
    foreach ($child in @($copy.children)) {
      if ($keep.Contains([string]$child)) { $children += [string]$child }
    }
    $copy.children = $children
    if ($copy.parent -and -not $keep.Contains([string]$copy.parent)) {
      $copy.parent = $rootId
    }
    $newMapping[$keepId] = $copy
  }

  if ($rootId -and $newMapping[$rootId]) {
    $firstMessage = if ($keptMessageIds.Count -gt 0) { [string]$keptMessageIds[0] } else { $null }
    $newMapping[$rootId].children = if ($firstMessage) { @($firstMessage) } else { @() }
  }

  $json.mapping = $newMapping
  $json | Add-Member -NotePropertyName "codex_trimmed_conversation" -NotePropertyValue ([pscustomobject]@{
    original_nodes = $originalNodes
    kept_nodes = $newMapping.Count
    original_messages = $originalMessages
    kept_messages = $keptMessageIds.Count
  }) -Force

  return @{
    changed = $true
    body = ($json | ConvertTo-Json -Depth 100 -Compress)
    originalNodes = $originalNodes
    keptNodes = $newMapping.Count
    originalMessages = $originalMessages
    keptMessages = $keptMessageIds.Count
  }
}

if ($KeepMessages -lt 10) {
  throw "KeepMessages must be at least 10."
}

$existing = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0 -and -not (Test-DebuggerPort -Port $Port)) {
  if ($Restart) {
    Write-Host "Stopping existing ChatGPT processes so the debugging port can be enabled..."
    $existing | Stop-Process -Force
    Start-Sleep -Seconds 2
  } else {
    throw "ChatGPT is already running, but DevTools port $Port is not active. Close ChatGPT first, or run this script with -Restart."
  }
}

if (-not (Test-DebuggerPort -Port $Port)) {
  $chatGptExe = Find-ChatGptExe -ExePath $ExePath
  Write-Host "Starting ChatGPT with local DevTools port $Port..."
  Start-Process -FilePath $chatGptExe -ArgumentList "--remote-debugging-port=$Port"
  $deadline = [DateTime]::UtcNow.AddSeconds(45)
  while (-not (Test-DebuggerPort -Port $Port)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw "ChatGPT did not expose DevTools port $Port in time." }
    Start-Sleep -Milliseconds 500
  }
}

$target = Get-PageTarget -Port $Port
$socket = [System.Net.WebSockets.ClientWebSocket]::new()
$nextId = 1
try {
  [void]$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Runtime.enable")
  [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Fetch.enable" -Params @{
    patterns = @(@{
      urlPattern = "*://chatgpt.com/backend-api/conversation/*"
      requestStage = "Response"
    })
  })
  [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Page.enable")

  if ($ConversationUrl) {
    Write-Host "Navigating to conversation with interception armed..."
    [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Page.navigate" -Params @{ url = $ConversationUrl })
  } else {
    $locationResult = Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Runtime.evaluate" -Params @{
      expression = "location.href"
      returnByValue = $true
    }
    $currentUrl = [string]$locationResult.result.result.value
    if ($currentUrl -match "https://chatgpt\.com/c/[0-9a-fA-F-]{20,}") {
      Write-Host "Reloading current conversation with interception armed..."
      [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Page.reload" -Params @{ ignoreCache = $true })
    } else {
      Write-Host "Interception is armed. Open a long chat in the ChatGPT app now; this tool will trim its load."
    }
  }

  Write-Host "Waiting for the next conversation load and keeping the latest $KeepMessages messages..."

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $trimmed = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    $raw = Receive-WebSocketMessage -Socket $socket -TimeoutSeconds $TimeoutSeconds
    $event = $raw | ConvertFrom-Json
    if ($event.method -ne "Fetch.requestPaused") { continue }

    $requestId = [string]$event.params.requestId
    $url = [string]$event.params.request.url
    if ($url -notmatch "/backend-api/conversation/[0-9a-fA-F-]{20,}(\?|$)") {
      [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Fetch.continueRequest" -Params @{ requestId = $requestId })
      continue
    }

    $bodyResult = Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Fetch.getResponseBody" -Params @{ requestId = $requestId }
    $body = [string]$bodyResult.result.body
    if ($bodyResult.result.base64Encoded) {
      $body = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($body))
    }

    $trim = Trim-ConversationJson -Body $body -KeepMessages $KeepMessages
    if (-not $trim.changed) {
      [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Fetch.continueRequest" -Params @{ requestId = $requestId })
      Write-Host "Conversation did not need trimming: $($trim.originalMessages) messages."
      $trimmed = $true
      break
    }

    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($trim.body)
    $responseBase64 = [System.Convert]::ToBase64String($responseBytes)
    [void](Invoke-CdpCommand -Socket $socket -NextId ([ref]$nextId) -Method "Fetch.fulfillRequest" -Params @{
      requestId = $requestId
      responseCode = 200
      responsePhrase = "OK"
      responseHeaders = @(
        @{ name = "content-type"; value = "application/json" },
        @{ name = "cache-control"; value = "no-store" }
      )
      body = $responseBase64
    })

    Write-Host "Trimmed conversation response: $($trim.originalMessages) messages -> $($trim.keptMessages), $($trim.originalNodes) nodes -> $($trim.keptNodes)."
    Write-Host "This affects only this loaded page response. Reload without this script to restore the full visible history."
    $trimmed = $true
    break
  }

  if (-not $trimmed) {
    throw "No matching conversation response was intercepted before timeout."
  }
} finally {
  $socket.Dispose()
}
