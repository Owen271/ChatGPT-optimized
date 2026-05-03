$ErrorActionPreference = "Stop"

$paths = @(
  (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\ChatGPT Optimized.lnk"),
  (Join-Path ([Environment]::GetFolderPath("Desktop")) "ChatGPT Optimized.lnk")
)

foreach ($path in $paths) {
  if (Test-Path $path) {
    Remove-Item -LiteralPath $path -Force
    Write-Host "Removed $path"
  }
}

Write-Host "Uninstall complete. The project folder was not deleted."
