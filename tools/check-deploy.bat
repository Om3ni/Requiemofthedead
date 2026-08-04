@echo off
rem check-deploy - "am I actually running my own code?" Leave it in a corner.
rem
rem Double-click to watch. Green means the server and client trees match the
rem repo; red means stop debugging and re-deploy, because whatever you are
rem testing is not what you wrote.
rem
rem   check-deploy              watch, 10s refresh
rem   check-deploy -Once        one pass, exit 1 if anything is stale
rem   check-deploy -Interval 30 slower refresh
rem   check-deploy -NoServer    skip a tree you are not using

title RotD deploy check
mode con: cols=52 lines=26
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-deploy.ps1" %*
exit /b %errorlevel%
