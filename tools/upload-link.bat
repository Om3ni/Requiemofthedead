@echo off
rem upload-link - point the Workshop staging folder at the repo, ready to upload.
rem
rem Creates a junction:
rem   %USERPROFILE%\Zomboid\Workshop\RequiemOfTheDead\Contents\mods
rem     -> <repo>\RequiemOfTheDead\Contents\mods
rem
rem WHILE THIS LINK IS UP THE STAGED ITEM OUTRANKS YOUR DEPLOYED TREES. The game
rem searches staged workshop items BEFORE %USERPROFILE%\Zomboid\mods, so every
rem mod id is registered twice and the staged copy wins - the exact shadow that
rem cost a session on 2026-08-05. It is also not safe to play on: Echoes' AnimSets
rem do not survive being read through a link.
rem
rem So: link, upload, unlink. Nothing in between.
rem
rem   upload-link              create the link
rem   upload-link -Status      report what staging currently is
rem
rem Afterwards:  upload-unlink.bat

title RotD upload link
where /q pwsh.exe && (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload-link.ps1" %*
) || (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload-link.ps1" %*
)
set RC=%errorlevel%
echo.
if %RC% NEQ 0 echo    ^>^> FAILED (exit %RC%) - read the red lines above.
pause
exit /b %RC%
