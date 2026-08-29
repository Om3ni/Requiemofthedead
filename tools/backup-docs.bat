@echo off
rem backup-docs - copy the gitignored root reasoning docs somewhere git cannot
rem lose them.
rem
rem WHY (2026-08-25). Commit 88c4ad4 untracked every root .md behind a `*.md`
rem rule so the engine readings would stop being public. That was the right
rem call for secrecy and it has now cost TWO files: README.md (lost 2026-08-20,
rem recovered from the delete commit itself) and REFACTOR.md (found missing
rem 2026-08-25, recovered the same way). Everything authored SINCE the purge -
rem TODO.md, the Bulwark ledgers, the design docs - has no such recovery path:
rem it exists in exactly one working copy on one disk. This script is the net.
rem
rem   tools\backup-docs        copy every root *.md to a timestamped folder
rem                            under %USERPROFILE%\Documents\RFTD-doc-backups\
rem
rem NON-DESTRUCTIVE: it only ever creates a new folder and copies into it.
rem Old backups are never touched; prune by hand when the folder annoys you.
rem Run it whenever a doc slice closes - it is cheap enough to run on habit.
rem A same-disk copy defends against the failure that has actually happened
rem twice (accidental deletion in the working tree); if the DISK is the worry,
rem point DEST somewhere that is not this drive, or add a private remote -
rem that half stays the owner's call.

setlocal enabledelayedexpansion
set "ROOT=%~dp0.."
rem Locale-proof stamp: %DATE% carries the day NAME in some locales, which
rem produced an unsortable folder on the very first run.
rem
rem SECONDS, not minutes (corrected 2026-08-25 in review). At minute precision
rem two runs inside the same minute resolved to the SAME folder and copy /y
rem overwrote it - a backup tool quietly destroying the backup it had just
rem promised never to touch. The refusal below is the belt to that braces: if
rem the folder somehow already exists we stop rather than write into it.
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmmss"') do set "STAMP=%%i"
set "DEST=%USERPROFILE%\Documents\RFTD-doc-backups\%STAMP%"

if exist "%DEST%" (
    echo backup-docs: "%DEST%" already exists - refusing to write into an
    echo               existing backup. Wait a second and run again.
    exit /b 1
)

mkdir "%DEST%" 2>nul
if not exist "%DEST%" (
    echo backup-docs: could not create "%DEST%"
    exit /b 1
)

rem EVERY COPY IS CHECKED. `copy` sets errorlevel on failure and the old loop
rem ignored it, incrementing COUNT regardless - so a permissions fault, a full
rem disk or one locked file produced a reassuring "N docs copied" and an
rem incomplete backup. For a recovery tool that is the worst failure there is:
rem you find out when you need it. A partial run now exits non-zero and names
rem what did not make it.
set COUNT=0
set FAILED=0
set "LOST="
for %%F in ("%ROOT%\*.md") do (
    copy /y "%%F" "%DEST%\" >nul
    if errorlevel 1 (
        set /a FAILED+=1
        set "LOST=!LOST! %%~nxF"
    ) else (
        set /a COUNT+=1
    )
)

if !FAILED! GTR 0 (
    echo backup-docs: INCOMPLETE - %COUNT% copied, !FAILED! FAILED to %DEST%
    echo               not backed up:!LOST!
    exit /b 1
)

echo backup-docs: %COUNT% doc(s) copied to %DEST%
exit /b 0
