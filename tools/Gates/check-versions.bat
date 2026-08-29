@echo off
rem check-versions - the version a mod reports must be the version it ships.
rem
rem   tools\Gates\check-versions        three checks, one exit code
rem
rem 1. Both mod.info copies byte-identical + one lockstep modversion (fails).
rem 2. registerMod version == mod.info modversion, literals and X.VERSION
rem    constants alike (fails).
rem 3. Mods that never register are named, advisory only - adding the call is
rem    an owner decision. See check-versions.py's header for the recurrence
rem    that bought this gate.

python "%~dp0check-versions.py" %*
exit /b %errorlevel%
