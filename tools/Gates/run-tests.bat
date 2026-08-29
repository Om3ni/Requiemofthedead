@echo off
rem run-tests - behavioural tests for the engine-free parts of the family.
rem
rem WHY, alongside check-lua: the syntax gate proves a file PARSES. It cannot
rem tell you the encoder silently truncated a record, or that a bound meant to
rem stop a hostile payload also eats a legitimate one. Anything that depends on
rem nothing but stock Lua gets tested here instead of on a live server with
rem players finding the defects.
rem
rem Scope, honestly: this runs modules that need NO engine stubs. RDJson today.
rem Anything reaching IsoPlayer, SandboxVars, getFileWriter or the Events table
rem needs the load-order harness and a stub layer, which is separate work - do
rem not read a green run here as "the bundle is tested".
rem
rem Version: PZ B42 runs Kahlua, which is Lua 5.1. Lua 5.3+ added an integer
rem subtype that changes math.floor and %%.0f, so a 5.4 interpreter would give
rem confident but wrong answers about RDJson.fmtNum. Use 5.1 only.
rem
rem lua5.1.exe + lua5.1.dll (~330KB total) sit next to this script and are
rem gitignored, same arrangement as luacheck.exe. Re-download if missing:
rem   https://sourceforge.net/projects/luabinaries/files/5.1.5/Tools%%20Executables/lua-5.1.5_Win64_bin.zip/download
rem Extract just lua5.1.exe and lua5.1.dll into this folder; the manifests and
rem the bundled VC80 CRT in that zip are not needed.
rem
rem Usage:
rem   tools\run-tests            run every suite
rem
rem Exit 0 = all green. Anything else, read the FAIL lines.

setlocal enabledelayedexpansion
set "LUA=%~dp0lua5.1.exe"
set "ROOT=%~dp0..\.."
set "OUT=%TEMP%\rftd-tests"
set FAIL=0

if not exist "%LUA%" (
    echo lua5.1.exe not found next to this script. See the header for the download URL.
    exit /b 3
)

if not exist "%OUT%" mkdir "%OUT%"
del /q "%OUT%\*.jsonl" 2>nul

rem THE ROLL CALL. A fixture that dies at LOAD - syntax fault, missing global
rem at file scope, dofile of a moved path - never reaches its own "N passed"
rem tally, so among 100+ fixtures the one interpreter error scrolls past
rem mid-run and nothing at the end says which file produced no tally. The
rem exit code was always right; ATTRIBUTION was the gap (2026-08-22, two
rem fixtures found only by running each one by hand). So: collect every
rem failing fixture's name and print the list after the loop.
set "DEAD="
for %%T in ("%~dp0tests\test_*.lua") do (
    "%LUA%" "%%T" "%ROOT%" "%OUT%"
    if !errorlevel! gtr 0 (
        set FAIL=1
        set "DEAD=!DEAD! %%~nT"
    )
)
if defined DEAD (
    echo.
    echo FAILED fixture^(s^):!DEAD!
    echo A name with no "N passed, M failed" tally above died at LOAD - run it
    echo alone to see the interpreter error:  Gates\lua5.1.exe Gates\tests\^<name^>.lua .
    echo.
)

rem Independent confirmation: Lua asserting on its own output only proves the
rem string matched what the test expected. This proves a real JSON reader
rem accepts every record the encoder produced. Skipped without Python rather
rem than failing - it is corroboration, not the gate.
where python >nul 2>nul
if !errorlevel!==0 (
    python "%~dp0tests\test_deploy_workshop.py" "%ROOT%"
    if !errorlevel! gtr 0 set FAIL=1
    python "%~dp0tests\test_deploy_workshop_testing.py" "%ROOT%"
    if !errorlevel! gtr 0 set FAIL=1
    python "%~dp0tests\test_forensic_report.py" "%ROOT%"
    if !errorlevel! gtr 0 set FAIL=1
    python "%~dp0validate_jsonl.py" "%OUT%"
    if !errorlevel! gtr 0 set FAIL=1
) else (
    echo [skip] python not on PATH - deploy regression and JSON re-validation not run.
)

if !FAIL!==0 echo All behavioural tests passed.
exit /b !FAIL!
