@echo off
taskkill /IM DJOneHub.exe /T /F >nul 2>&1
if errorlevel 1 (
  echo DJOneHub is not running.
) else (
  echo DJOneHub stopped.
)
timeout /t 2 >nul
