@echo off
setlocal
title 4 - Analyze

REM ===========================================================================
REM  Turns the newest capture into a per-client traffic report.
REM
REM    4-ANALYZE.bat            -> newest capture folder
REM    4-ANALYZE.bat <folder>   -> a specific one
REM
REM  Finding "the newest folder" is done by the Python script (--latest), not
REM  here: doing it in cmd needs either an inline PowerShell block or a for/f
REM  loop, and both are quoting minefields that fail by hanging.
REM ===========================================================================

if not "%~1"=="" goto :specific

python "%~dp0analyze-capture.py" --latest "%~dp0captures"
if errorlevel 1 goto :fail
goto :ok

:specific
python "%~dp0analyze-capture.py" "%~1"
if errorlevel 1 goto :fail

:ok
echo.
echo  ===============================================================
echo   Done. report.html is in the capture folder.
echo.
echo   Read it looking for:
echo     - one client far above the rest
echo     - one packet type dominating the total
echo     - Client13 (the chatter bot) heavier than the others
echo.
echo   Then change ONE thing and capture again. Two captures are what
echo   turn a number into a cause.
echo  ===============================================================
echo.
pause
exit /b 0

:fail
echo.
echo   Analysis failed - read the message above.
echo   "python is not recognized" means Python is not on PATH.
echo.
pause
exit /b 1
