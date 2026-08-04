@echo off
setlocal
title 1B - Mosaic NO-STEAM (bots + metrics)

REM ===========================================================================
REM  Starts the dedicated server directly, with Steam OFF, so FakeClientManager
REM  bots can actually connect.
REM
REM  WHY NOT 1-START-SERVER.bat: bots hardcode ZNetNoSteam64
REM  (FakeClientManager.java:348) and the server chooses its transport at
REM  SteamUtils.java:64-72 - ZNetJNI64 when steam=1, ZNetNoSteam64 when steam=0.
REM  They are different transports. A bot aimed at a Steam-mode server has its
REM  packets dropped below the login layer: no kick, no denial, no log line,
REM  just silence and players=0.
REM
REM  WHY NOT _JAVA_OPTIONS: Mosaic puts -Dzomboid.steam=1 on the command line
REM  itself, and for duplicate -D properties the command line wins over
REM  _JAVA_OPTIONS. So Steam cannot be switched off from the environment - this
REM  has to bypass Mosaic and build the line directly.
REM
REM  PREREQUISITE: run stage-mods.ps1 first. With Steam off, BOTH workshop mod
REM  sources are skipped (ZomboidFileSystem.java:429 and :439), so without a
REM  staged copy in C:\Mosaic\pzdata\mods this boots VANILLA and every number
REM  you capture describes the wrong game.
REM ===========================================================================

set SERVER_ROOT=C:\Mosaic\ProjectZomboidDedicatedServer
set CACHE_DIR=C:\Mosaic\pzdata
set METRICS_PORT=9091

if not exist "%SERVER_ROOT%\jre64\bin\java.exe" (
  echo   XX  server not found at %SERVER_ROOT%
  pause
  exit /b 1
)

REM Refuse to boot vanilla by accident.
if not exist "%CACHE_DIR%\mods\*" (
  echo.
  echo   XX  %CACHE_DIR%\mods is empty.
  echo.
  echo   With Steam off the server cannot see the workshop tree, so it would
  echo   boot with NO MODS and the capture would be meaningless.
  echo.
  echo   Run this first:
  echo       powershell -ExecutionPolicy Bypass -File "%~dp0stage-mods.ps1"
  echo.
  pause
  exit /b 1
)

echo.
echo  Starting server: Steam OFF, metrics on %METRICS_PORT%
echo  Mods from %CACHE_DIR%\mods (staged copy, not the workshop tree)
echo.

cd /d "%SERVER_ROOT%"
start "PZ dedi (no-steam)" ".\jre64\bin\java.exe" ^
  -Djava.awt.headless=true ^
  -Dzomboid.steam=0 ^
  -Dzomboid.znetlog=1 ^
  -DprometheusPort=%METRICS_PORT% ^
  -XX:+UseZGC ^
  -XX:-CreateCoredumpOnCrash ^
  -XX:-OmitStackTraceInFastThrow ^
  -Xms8g -Xmx8g ^
  -Djava.library.path=natives/ ^
  -cp "java/;java/projectzomboid.jar" ^
  zombie.network.GameServer ^
  -statistic 0 -servername MDS -cachedir=%CACHE_DIR%

echo  Server launching in its own window. Waiting for the metrics endpoint...
echo  (mod scan on 100+ mods takes a while - be patient)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-metrics.ps1" -Port %METRICS_PORT% -TimeoutSec 600
if errorlevel 1 goto :nometrics

echo.
echo  ===============================================================
echo   READY.
echo   Next: 2-START-CAPTURE.bat, then 3-START-BOTS.bat 0
echo.
echo   Sanity-check the mods actually loaded before you trust a run:
echo     findstr /C:"Mods loaded" "%CACHE_DIR%\Logs\*_DebugLog-server.txt"
echo  ===============================================================
echo.
pause
exit /b 0

:nometrics
echo.
echo   No metrics endpoint. Check the server window for a startup error.
echo.
pause
exit /b 1
