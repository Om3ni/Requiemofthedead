@echo off
rem check-helpers - fails when the same helper body exists in two places, or when
rem a mod's copied-helper count creeps above its baseline. See check-helpers.py's
rem header for the whole story.
rem
rem   tools\check-helpers           check; non-zero exit on creep
rem   tools\check-helpers --list    every local function and where it lives
rem   tools\check-helpers --update  accept current counts as the new baseline
rem
rem The name is ignored when comparing, so a renamed copy is still a copy. The
rem report says where each group belongs: two or more consumer MODS go to
rem RFTDCore/shared, copies inside one mod go to that mod's own shared/.

python "%~dp0check-helpers.py" %*
exit /b %errorlevel%
