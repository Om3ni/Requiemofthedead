@echo off
setlocal
title 1 - Mosaic with metrics

REM ===========================================================================
REM  Starts Mosaic with the engine's Prometheus exporter enabled.
REM
REM  WHY A BAT: the only fragile part of this is that _JAVA_OPTIONS must exist
REM  in the environment BEFORE the server JVM launches. Mosaic builds its own
REM  java command line, so there is nowhere to type the flag - but the JVM reads
REM  _JAVA_OPTIONS from the environment no matter who built the line. Setting it
REM  here, in the same process that launches Mosaic, is what makes it stick.
REM
REM  setlocal keeps the variable inside this window, so it can never leak into a
REM  game client and fight the server for port 9091 (a collision throws an
REM  unchecked RuntimeException out of StatisticManager.init and kills the
REM  client at startup).
REM ===========================================================================

set _JAVA_OPTIONS=-DprometheusPort=9091

echo.
echo  Starting Mosaic with metrics on port 9091
echo  (client NOT launched - the bots are the players)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\launch-mosaic.ps1" -Restart -NoClient
if errorlevel 1 goto :failed

echo.
echo  ---------------------------------------------------------------
echo   Verifying the metrics endpoint
echo  ---------------------------------------------------------------

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-metrics.ps1"
if errorlevel 1 goto :nometrics

echo.
echo  ===============================================================
echo   READY. Leave this window open.
echo   Next: 2-START-CAPTURE.bat in a NEW window.
echo  ===============================================================
echo.
pause
exit /b 0

:nometrics
echo.
echo   Server started, but no metrics. See the guidance above.
echo.
pause
exit /b 1

:failed
echo.
echo   Mosaic failed to start. Read the output above.
echo.
pause
exit /b 1
