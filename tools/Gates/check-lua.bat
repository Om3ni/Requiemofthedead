@echo off
rem check-lua - fast Lua syntax gate for PZ mod trees (real Lua 5.1 parse).
rem
rem WHY: a missing `end` or typo'd bracket makes the whole file silently fail
rem to load in-game (PZ prints one console line and moves on) - and the
rem Workshop upload -> server pull -> client restart cycle burns ~10 minutes
rem discovering it. This catches that class of bug in one second, pre-upload.
rem
rem Usage:
rem   tools\check-lua                 check every mod tree in the repo
rem   tools\check-lua <path> [...]    check specific folders or files
rem
rem Silence = clean (exit 0). Anything printed = fix it before uploading.
rem Only syntax errors are reported (--only 011); style/global warnings are
rem deliberately off - PZ mods legitimately use hundreds of engine globals.
rem
rem luacheck.exe (standalone, ~800KB) sits next to this script and is
rem gitignored; re-download if missing:
rem   https://github.com/lunarmodules/luacheck/releases/latest/download/luacheck.exe

setlocal enabledelayedexpansion
set "LUACHECK=%~dp0luacheck.exe"
set "ROOT=%~dp0..\.."
set FAIL=0

if not exist "%LUACHECK%" (
    echo luacheck.exe not found next to this script. Re-download:
    echo   https://github.com/lunarmodules/luacheck/releases/latest/download/luacheck.exe
    exit /b 3
)

if not "%~1"=="" (
    "%LUACHECK%" --only 011 --std lua51 --formatter plain %*
    exit /b !errorlevel!
)

rem No args: sweep every mod tree (any top-level dir with a Contents/contents folder).
for /d %%D in ("%ROOT%\*") do (
    if exist "%%D\Contents\" (
        "%LUACHECK%" --only 011 --std lua51 --formatter plain "%%D\Contents"
        if !errorlevel! gtr 0 set FAIL=1
    ) else if exist "%%D\contents\" (
        "%LUACHECK%" --only 011 --std lua51 --formatter plain "%%D\contents"
        if !errorlevel! gtr 0 set FAIL=1
    )
)

if !FAIL!==0 echo All mod lua trees parse clean.
exit /b !FAIL!
