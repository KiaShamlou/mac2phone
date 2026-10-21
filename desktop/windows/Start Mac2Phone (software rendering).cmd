@echo off
setlocal EnableExtensions DisableDelayedExpansion
call "%~dp0Diagnose Mac2Phone.cmd" --software
exit /b %ERRORLEVEL%
