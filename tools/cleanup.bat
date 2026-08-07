@echo off
rem cleanup - press this when the session is over.
rem
rem Removes everything deploy.bat put out there, from both trees, leaving the
rem repo as the only copy. It only touches what it deployed - the manifest at
rem each tree root records that - so anything else in those folders is reported
rem and left alone.
rem
rem Shadows stay parked on purpose. Unparking restores the folder that outranks
rem your deploy, so that is a deliberate step before an upload, not cleanup:
rem     session.ps1 -RestoreShadows
rem
rem   cleanup                tear both trees down to nothing
rem   cleanup -DryRun        show what would be removed
rem   cleanup -NoServer      client only

rem PowerShell 7 when present, Windows PowerShell otherwise - see deploy.bat.
title RotD cleanup
where /q pwsh.exe && (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0session.ps1" -Down %*
) || (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0session.ps1" -Down %*
)
set RC=%errorlevel%
echo.
if %RC% NEQ 0 echo    ^>^> FAILED (exit %RC%) - read the red lines above.
pause
exit /b %RC%
