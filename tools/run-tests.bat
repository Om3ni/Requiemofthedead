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
set "ROOT=%~dp0.."
set "OUT=%TEMP%\rftd-tests"
set FAIL=0

if not exist "%LUA%" (
    echo lua5.1.exe not found next to this script. See the header for the download URL.
    exit /b 3
)

if not exist "%OUT%" mkdir "%OUT%"
del /q "%OUT%\*.jsonl" 2>nul

for %%T in ("%~dp0tests\test_*.lua") do (
    "%LUA%" "%%T" "%ROOT%" "%OUT%"
    if !errorlevel! gtr 0 set FAIL=1
)

rem Independent confirmation: Lua asserting on its own output only proves the
rem string matched what the test expected. This proves a real JSON reader
rem accepts every record the encoder produced. Skipped without Python rather
rem than failing - it is corroboration, not the gate.
where python >nul 2>nul
if !errorlevel!==0 (
    python "%~dp0validate_jsonl.py" "%OUT%"
    if !errorlevel! gtr 0 set FAIL=1
) else (
    echo [skip] python not on PATH - JSON re-validation not run.
)

if !FAIL!==0 echo All behavioural tests passed.
exit /b !FAIL!
