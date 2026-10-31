@echo off
rem vigil.cmd - the vigil command on Windows, for cmd.exe and PowerShell alike:
rem runs vigil.ps1 beside it on Windows PowerShell 5.1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vigil.ps1" %*
exit /b %ERRORLEVEL%
