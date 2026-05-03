param(
  [switch]$Desktop,
  [switch]$StartMenu = $true,
  [int]$KeepMessages = 40
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hiddenLauncher = Join-Path $repoRoot "Launch ChatGPT Optimized Hidden.vbs"
$cmdLauncher = Join-Path $repoRoot "Launch ChatGPT Optimized.cmd"

if (-not (Test-Path $hiddenLauncher)) {
  throw "Missing launcher: $hiddenLauncher"
}
if (-not (Test-Path $cmdLauncher)) {
  throw "Missing launcher: $cmdLauncher"
}

function Get-ChatGptIcon {
  $package = Get-AppxPackage -Name "OpenAI.ChatGPT-Desktop" -ErrorAction SilentlyContinue
  if ($package -and $package.InstallLocation) {
    $exe = Join-Path $package.InstallLocation "app\ChatGPT.exe"
    if (Test-Path $exe) {
      return "$exe,0"
    }
  }
  return "wscript.exe,0"
}

function New-OptimizedShortcut {
  param(
    [string]$Path,
    [string]$IconLocation
  )

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = "wscript.exe"
  $shortcut.Arguments = '"' + $hiddenLauncher + '"'
  $shortcut.WorkingDirectory = $repoRoot
  $shortcut.IconLocation = $IconLocation
  $shortcut.Description = "Launch ChatGPT with local long-conversation trimming enabled"
  $shortcut.Save()
}

$icon = Get-ChatGptIcon
$installed = @()

if ($StartMenu) {
  $path = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\ChatGPT Optimized.lnk"
  New-OptimizedShortcut -Path $path -IconLocation $icon
  $installed += $path
}

if ($Desktop) {
  $path = Join-Path ([Environment]::GetFolderPath("Desktop")) "ChatGPT Optimized.lnk"
  New-OptimizedShortcut -Path $path -IconLocation $icon
  $installed += $path
}

Write-Host "Installed ChatGPT Optimized shortcut(s):"
$installed | ForEach-Object { Write-Host "  $_" }
Write-Host "Default trim: latest $KeepMessages messages."
