@echo off
setlocal
title 2 - Capture

REM ===========================================================================
REM  Snapshots the /metrics endpoint on a timer.
REM
REM  Run this in its OWN window, and leave it alone. It writes one .prom file
REM  per tick into captures\<timestamp>_<label>\.
REM
REM  Optional first argument is the label. Use it - after two runs you will not
REM  remember which folder was which, and a comparison you cannot identify is a
REM  comparison you have to redo.
REM
REM    2-START-CAPTURE.bat                 -> label "bots-14"
REM    2-START-CAPTURE.bat baseline        -> label "baseline"
REM    2-START-CAPTURE.bat no-phunzones    -> label "no-phunzones"
REM ===========================================================================

set LABEL=%~1
if "%LABEL%"=="" set LABEL=bots-14

echo.
echo  Capturing to captures\...._%LABEL%
echo  15 minutes, one snapshot every 10s. Ctrl-C stops early (partial is fine).
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scrape-metrics.ps1" -DurationMin 15 -Label "%LABEL%"

if errorlevel 1 (
  echo.
  echo   Capture did not start. Is 1-START-SERVER.bat running and did it say
  echo   "OK  /metrics is live"?
  echo.
  pause
  exit /b 1
)

echo.
echo  ===============================================================
echo   Capture done. Next: 4-ANALYZE.bat
echo  ===============================================================
echo.
pause
