@echo off
setlocal EnableExtensions
chcp 65001 >nul
title LazyVPS Mihomo Setup

set "SCRIPT_DIR=%~dp0"

if /I "%~1"=="--self-test" goto SELF_TEST

pushd "%SCRIPT_DIR%"
if errorlevel 1 goto PATH_ERROR
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_mihomo.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
popd
goto SHOW_RESULT

:SELF_TEST
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_mihomo.ps1" -SelfTest
exit /b %ERRORLEVEL%

:PATH_ERROR
echo [ERROR] Cannot open the script directory.
set "EXIT_CODE=3"

:SHOW_RESULT
echo.
if "%EXIT_CODE%"=="0" goto SUCCESS
echo [ERROR] Mihomo setup failed with exit code %EXIT_CODE%.
echo Keep this window open and check the message above.
goto WAIT_TO_CLOSE

:SUCCESS
echo [OK] Mihomo is installed. You can now run run_airport_tester.cmd.

:WAIT_TO_CLOSE
echo Press any key to close this window...
pause >nul
exit /b %EXIT_CODE%
