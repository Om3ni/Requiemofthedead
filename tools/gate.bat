@echo off
rem gate - every gate, in cost order, one command.
rem
rem WHY THIS EXISTS (2026-08-20). There were five gates and no way to run them.
rem CLAUDE.md sect. 7 listed them as a block you had to trust yourself to work
rem through, and check-citations was not even in the list because it was the one
rem without a .bat. A checklist you execute by hand is a checklist you execute
rem incompletely, and the failure is silent: the gate you forgot is exactly the
rem one that would have spoken.
rem
rem   tools\gate            run everything; non-zero exit if any gate failed
rem
rem COST ORDER, fast first, so a syntax error costs you a second rather than the
rem two minutes run-tests takes to spawn its hundred-odd fixtures. Every gate
rem still runs even after one fails - you want the whole picture in one pass,
rem not a bisect. The exit code is the OR of the real gates.
rem
rem NOT INCLUDED, deliberately: check-citations reports and always exits 0, so
rem it runs last and its output is advisory - a resolved citation is not a
rem verified one, and only a person reading the body can close that gap. Nothing
rem here changes the environment; deploy, cleanup and the upload links are
rem separate commands on purpose and always need explicit approval.
rem
rem NONE OF THIS IS A RUNTIME TEST. Green here means the code parses, the guards
rem are honest, no helper was pasted, no token grew a second intake, and the
rem engine-free logic behaves. It does not mean a hot path works. Boot Mosaic.

setlocal enabledelayedexpansion
set "G=%~dp0Gates"
set FAIL=0
set FAILED=

call :run "lua      " "%G%\check-lua.bat"
call :run "pcall    " "%G%\check-pcall.bat"
call :run "helpers  " "%G%\check-helpers.bat"
call :run "network  " "%G%\check-network.bat"
call :run "tests    " "%G%\run-tests.bat"

echo.
echo ---- citations (advisory, never fails the run) ----
call "%G%\check-citations.bat"

echo.
if !FAIL!==0 (
    echo GATE PASS - all five gates clean.
    echo Not a runtime test. Boot Mosaic for anything on an event hook or a per-tick path.
) else (
    echo GATE FAIL -!FAILED!
)
exit /b !FAIL!

:run
echo.
echo ---- %~1 ----
call %2
if errorlevel 1 (
    set FAIL=1
    set "FAILED=!FAILED! %~1"
)
goto :eof
