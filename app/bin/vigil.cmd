@echo off
rem Copyright (c) Bankole Ogundero and the Vigil contributors
rem SPDX-License-Identifier: Apache-2.0
rem
rem Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
rem implied. Run it at your own risk: review it first, and test it before you
rem rely on it. In no event shall the authors or copyright holders be liable
rem for any claim, damages or other liability arising from its use. See the
rem LICENSE file for the full terms.
rem
rem vigil.cmd - the vigil command on Windows, for cmd.exe and PowerShell alike:
rem runs app\vigil.ps1 on Windows PowerShell 5.1. In a folder of its own on
rem the PATH: beside vigil.ps1, PowerShell would run that instead, which an
rem execution policy that refuses scripts (the default on Windows 10 and 11)
rem stops. Bypass holds for this one process; the policy is not changed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\vigil.ps1" %*
exit /b %ERRORLEVEL%
