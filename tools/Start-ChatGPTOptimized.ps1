param(
  [int]$Port = 9222,
  [int]$RecentLimit = 40,
  [int]$IntrinsicSize = 520,
  [ValidateSet("Auto", "Hidden")]
  [string]$Mode = "Auto",
  [switch]$Aggressive,
  [int]$AggressiveKeep = 120,
  [switch]$DebugOptimizer,
  [switch]$Restart,
  [string]$ExePath
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

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$injector = Join-Path $scriptDir "Inject-ChatGptDomOptimizer.ps1"
if (-not (Test-Path $injector)) {
  throw "Injector script not found: $injector"
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
  $chatGptExe = Find-ChatGptExe
  Write-Host "Starting ChatGPT with local DevTools port $Port..."
  Start-Process -FilePath $chatGptExe -ArgumentList "--remote-debugging-port=$Port"
}

$injectArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $injector,
  "-Port", $Port,
  "-RecentLimit", $RecentLimit,
  "-IntrinsicSize", $IntrinsicSize,
  "-Mode", $Mode,
  "-AggressiveKeep", $AggressiveKeep,
  "-Wait",
  "-WaitSeconds", "45"
)

if ($Aggressive) { $injectArgs += "-Aggressive" }
if ($DebugOptimizer) { $injectArgs += "-DebugOptimizer" }

Write-Host "Injecting optimizer..."
& powershell.exe @injectArgs
