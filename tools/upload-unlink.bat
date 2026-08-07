@echo off
rem upload-unlink - remove the Workshop staging link. Run straight after uploading.
rem
rem Removes the junction with `rmdir`, NEVER Remove-Item -Recurse: that follows a
rem junction and deletes what it points at, which here is the payload itself.
rem The script re-counts the repo afterwards and shouts if the number moved.
rem
rem Once this has run, staging holds no Contents\mods, so the game stops
rem registering it and your deployed trees are authoritative again.
rem
rem It only removes links it made. A real Contents\mods folder is a stage-upload
rem snapshot or hand-made, and it will refuse rather than delete it - use
rem deploy.bat, which parks such a folder as mods.parked.
rem
rem   upload-unlink            remove the link

title RotD upload unlink
where /q pwsh.exe && (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload-link.ps1" -Down %*
) || (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload-link.ps1" -Down %*
)
set RC=%errorlevel%
echo.
if %RC% NEQ 0 echo    ^>^> FAILED (exit %RC%) - read the red lines above.
pause
exit /b %RC%
