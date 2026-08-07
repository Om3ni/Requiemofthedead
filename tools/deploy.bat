@echo off
rem deploy - press this when a session starts.
rem
rem Puts the repo where the server and client actually read from, and parks
rem anything that would outrank it. Real copies only, never junctions - a linked
rem mod tree makes the engine misattribute items to the wrong mod and the client
rem crashes to desktop on join. See session.ps1's header for the mechanism.
rem
rem   deploy                 push to both trees, park shadows, verify
rem   deploy -DryRun         show the plan, write nothing
rem   deploy -NoServer       client only
rem
rem When you are done:  cleanup.bat

rem PowerShell 7 when it is installed, Windows PowerShell otherwise. Not a
rem preference: this box's powershell.exe fails to resolve Utility cmdlets
rem (Get-FileHash threw CommandNotFoundException mid-verify on 2026-08-06),
rem and 7 is the healthier host. The script itself avoids those cmdlets, so
rem either host works - this just picks the better one when it is there.
title RotD deploy
where /q pwsh.exe && (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0session.ps1" %*
) || (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0session.ps1" %*
)
set RC=%errorlevel%
echo.
if %RC% NEQ 0 echo    ^>^> FAILED (exit %RC%) - read the red lines above.
pause
exit /b %RC%
