@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title Mac2Phone startup diagnostics
echo Mac2Phone - Windows startup check
echo.
for %%F in ("Mac2Phone.exe" "resources\app.asar" "resources.pak" "icudtl.dat" "ffmpeg.dll" "chrome_100_percent.pak" "chrome_200_percent.pak" "v8_context_snapshot.bin" "locales\en-US.pak") do (
  if not exist "%%~F" (
    echo Missing required file: %%~F
    echo.
    echo Right-click the downloaded ZIP, choose Extract All, then open the extracted folder.
    echo Keep Mac2Phone.exe beside ALL its DLLs, folders and other files.
    echo Do not run from inside the ZIP or copy only the EXE.
    echo.
    pause
    exit /b 2
  )
)
set "ELECTRON_RUN_AS_NODE="
set "M2P_MODE="
if /I "%~1"=="--software" set "M2P_MODE=--m2p-software-rendering"
echo All required files are present.
echo Starting Mac2Phone. Close the app to finish this check.
echo Logs: "%LOCALAPPDATA%\Mac2Phone\logs\startup.log"
echo.
start "" /wait "%~dp0Mac2Phone.exe" %M2P_MODE%
set "M2P_EXIT=%ERRORLEVEL%"
echo.
echo Mac2Phone launcher exit code: %M2P_EXIT%
echo If no window appeared, send this exit code and startup.log with your bug report.
echo If startup.log is missing, Windows stopped the program before JavaScript started.
echo.
pause
exit /b %M2P_EXIT%
