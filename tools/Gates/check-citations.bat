@echo off
rem check-citations - resolve every Class.java:line / File.lua:line citation in
rem the suite to the line it actually names. See check-citations.py's header.
rem
rem   tools\Gates\check-citations              problems only
rem   tools\Gates\check-citations --all        every citation with its line
rem   tools\Gates\check-citations --file X     only citations naming X
rem
rem NOT A GATE, and the exit code says so: this always exits 0. It reports where
rem a citation points and you decide whether the body supports the claim beside
rem it - a machine cannot do that half. It had no wrapper at all until
rem 2026-08-20, which is exactly why it kept getting left out of the gate runs
rem and out of CLAUDE.md's list. A tool you have to remember to type by hand is
rem a tool that gets forgotten.

python "%~dp0check-citations.py" %*
exit /b %errorlevel%
