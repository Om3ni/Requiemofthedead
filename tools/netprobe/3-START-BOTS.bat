@echo off
setlocal
title 3 - Bots

REM ===========================================================================
REM  Launches the synthetic clients. Run in its OWN window, alongside capture.
REM
REM    3-START-BOTS.bat 0     -> ONE bot (id 0). ALWAYS DO THIS FIRST.
REM    3-START-BOTS.bat       -> all 14
REM
REM  Why the smoke test matters: whether Mosaic's Steam mode accepts a non-Steam
REM  RakNet client is the one part of this setup verified only by reading engine
REM  code, not by observing it. One bot answers it in 15 seconds.
REM
REM  This shells out to run-bots.ps1 rather than calling java directly, because
REM  PowerShell splits unquoted -D properties on the dot and java then reports
REM  "Could not find or load main class .awt.headless=true". run-bots.ps1 also
REM  clears orphaned bot JVMs that would otherwise hold UDP port 17500.
REM ===========================================================================

if "%~1"=="" goto :all

echo.
echo  SMOKE TEST - one bot (id %~1)
echo  Want: "Player N connect in X.XXXs"   Ctrl-C once you see it.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\fakeclient\run-bots.ps1" -Id %~1
goto :done

:all
echo.
echo  ALL 14 BOTS - they join ~1.5s apart, so all in after ~21s.
echo  Let this run about 10 minutes, then Ctrl-C.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\fakeclient\run-bots.ps1"

:done
echo.
echo  ---------------------------------------------------------------
echo   Bots stopped.
echo.
echo   Connection failed: 17   = nothing answered; server is down
echo   Network start failed: 5 = port 17500 still held by an orphan
echo   Client kicked           = server rejected it, reason is printed
echo  ---------------------------------------------------------------
echo.
pause
