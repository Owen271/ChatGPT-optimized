param(
  [int]$Port = 9222,
  [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"

function Get-Json {
  param([string]$Url)
  return Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 3
}

function Receive-WebSocketMessage {
  param([System.Net.WebSockets.ClientWebSocket]$Socket, [int]$TimeoutSeconds = 45)

  $buffer = [byte[]]::new(2097152)
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

  $message = @{ id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 20 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
  [void]$Socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Read-UntilCommand {
  param([System.Net.WebSockets.ClientWebSocket]$Socket, [int]$Id, [int]$TimeoutSeconds = 45)
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

$targets = @(Get-Json "http://127.0.0.1:$Port/json/list")
$target = @($targets | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1)[0]
if (-not $target) { throw "No page target found on port $Port." }

$socket = [System.Net.WebSockets.ClientWebSocket]::new()
$nextId = 1
try {
  [void]$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  Send-CdpCommand -Socket $socket -Id $nextId -Method "Network.enable"; Read-UntilCommand -Socket $socket -Id $nextId | Out-Null; $nextId += 1
  Send-CdpCommand -Socket $socket -Id $nextId -Method "Page.reload" -Params @{ ignoreCache = $true }; Read-UntilCommand -Socket $socket -Id $nextId | Out-Null; $nextId += 1

  $conversationRequestId = $null
  $conversationUrl = $null
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $raw = Receive-WebSocketMessage -Socket $socket -TimeoutSeconds $TimeoutSeconds
    $event = $raw | ConvertFrom-Json
    if ($event.method -eq "Network.responseReceived") {
      $url = [string]$event.params.response.url
      if ($url -match "/backend-api/conversation/[0-9a-fA-F-]{20,}(\?|$)") {
        $conversationRequestId = [string]$event.params.requestId
        $conversationUrl = $url
      }
    }
    if ($conversationRequestId -and $event.method -eq "Network.loadingFinished" -and [string]$event.params.requestId -eq $conversationRequestId) {
      break
    }
  }

  if (-not $conversationRequestId) { throw "No conversation response was observed during reload." }

  Send-CdpCommand -Socket $socket -Id $nextId -Method "Network.getResponseBody" -Params @{ requestId = $conversationRequestId }
  $bodyResult = Read-UntilCommand -Socket $socket -Id $nextId
  $body = [string]$bodyResult.result.body
  if ($bodyResult.result.base64Encoded) {
    $body = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($body))
  }

  $json = $body | ConvertFrom-Json
  $mapping = @{}
  if ($json.mapping) {
    $mapping = $json.mapping.PSObject.Properties
  }
  $messageNodes = @()
  if ($json.mapping) {
    $messageNodes = @($json.mapping.PSObject.Properties | Where-Object { $_.Value.message } | ForEach-Object { $_.Value })
  }

  [pscustomobject]@{
    url = $conversationUrl
    bytes = $body.Length
    topLevelKeys = @($json.PSObject.Properties.Name | Sort-Object)
    mappingCount = @($mapping).Count
    messageNodeCount = @($messageNodes).Count
    currentNode = $json.current_node
    titleLength = if ($json.title) { ([string]$json.title).Length } else { 0 }
    nodeKeys = if (@($mapping).Count -gt 0) { @($mapping)[0].Value.PSObject.Properties.Name | Sort-Object } else { @() }
    messageKeys = if (@($messageNodes).Count -gt 0) { @($messageNodes)[0].message.PSObject.Properties.Name | Sort-Object } else { @() }
  } | ConvertTo-Json -Depth 10
} finally {
  $socket.Dispose()
}
