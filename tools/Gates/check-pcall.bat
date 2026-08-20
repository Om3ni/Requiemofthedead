@echo off
rem check-pcall - fails when a pcall guards a call that cannot throw, or when a
rem mod's guard count creeps above its baseline. See check-pcall.py's header for
rem the whole story (and pcall-safe.json for what "cannot throw" is allowed to
rem mean - it is a decompile job, not a guess).
rem
rem   tools\check-pcall              check; non-zero exit on any violation
rem   tools\check-pcall --list       every pcall site with the calls it guards
rem   tools\check-pcall --update     accept current counts as the new baseline
rem
rem Run it beside check-lua before an upload: check-lua says the code parses,
rem this says the code is not lying about what can fail.

python "%~dp0check-pcall.py" %*
exit /b %errorlevel%
