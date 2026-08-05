@echo off
setlocal EnableExtensions
chcp 65001 >nul
title LazyVPS Airport Full Tester

set "SCRIPT_DIR=%~dp0"
set "EXIT_CODE=1"

if /I "%~1"=="--self-test" goto SELF_TEST

pushd "%SCRIPT_DIR%"
if errorlevel 1 goto PATH_ERROR
set "PUSHD_OK=1"

if "%~1"=="" goto AUTO_MODE
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%airport_full_tester.ps1" -ConfigPath "%~f1"
goto CAPTURE_EXIT

:AUTO_MODE
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%airport_full_tester.ps1"
goto CAPTURE_EXIT

:SELF_TEST
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%airport_full_tester.ps1" -SelfTest -NoColor -OutDir "%TEMP%\lazyvps-airport-cmd-selftest"
exit /b %ERRORLEVEL%

:CAPTURE_EXIT
set "EXIT_CODE=%ERRORLEVEL%"
goto FINISH

:PATH_ERROR
echo [ERROR] Cannot open the script directory.
set "EXIT_CODE=3"
goto FINISH

:FINISH
if defined PUSHD_OK popd
echo.
if "%EXIT_CODE%"=="0" goto SUCCESS
echo [ERROR] Airport tester returned exit code %EXIT_CODE%.
echo Keep this window open and check the message above.
goto WAIT_TO_CLOSE

:SUCCESS
echo [OK] Airport tester finished.

:WAIT_TO_CLOSE
echo Press any key to close this window...
pause >nul
exit /b %EXIT_CODE%
