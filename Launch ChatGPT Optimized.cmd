@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "LOG=%~dp0optimizer\launcher.log"
echo [%date% %time%] Launch ChatGPT Optimized %*>> "%LOG%"
if "%~1"=="" (
  call "%~dp0optimizer\Start-ChatGPTFetchTrimmed.cmd" -KeepMessages 40 -Restart -StayResident -Quiet >> "%LOG%" 2>&1
) else (
  call "%~dp0optimizer\Start-ChatGPTFetchTrimmed.cmd" -StayResident %* >> "%LOG%" 2>&1
)
set "EXITCODE=!errorlevel!"
echo [%date% %time%] Exit code !EXITCODE!>> "%LOG%"
exit /b !EXITCODE!
