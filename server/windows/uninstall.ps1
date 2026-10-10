$ErrorActionPreference = "Stop"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\DJOneHub"
$StartMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"

Get-Process -Name "DJOneHub" -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $StartMenu "DJOneHub.lnk")
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $StartMenu "Uninstall DJOneHub.lnk")

if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
}

Write-Host "DJOneHub has been uninstalled."
