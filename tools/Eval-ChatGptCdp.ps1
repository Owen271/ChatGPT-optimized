param(
  [int]$Port = 9222,
  [Parameter(Mandatory = $true)]
  [string]$Expression
)

$ErrorActionPreference = "Stop"

function Get-Json {
  param([string]$Url)
  return Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 3
}

function Receive-WebSocketMessage {
  param([System.Net.WebSockets.ClientWebSocket]$Socket)

  $buffer = [byte[]]::new(1048576)
  $segment = [ArraySegment[byte]]::new($buffer)
  $builder = [System.Text.StringBuilder]::new()

  do {
    $task = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
    while (-not $task.IsCompleted) {
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

$targets = @(Get-Json "http://127.0.0.1:$Port/json/list")
$target = @($targets | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1)[0]
if (-not $target) {
  throw "No page target found on port $Port."
}

$socket = [System.Net.WebSockets.ClientWebSocket]::new()
try {
  [void]$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  [void](Send-CdpCommand -Socket $socket -Id 1 -Method "Runtime.enable")
  $result = Send-CdpCommand -Socket $socket -Id 2 -Method "Runtime.evaluate" -Params @{
    expression = $Expression
    awaitPromise = $true
    returnByValue = $true
  }
  $result.result.result.value | ConvertTo-Json -Depth 20
} finally {
  $socket.Dispose()
}
