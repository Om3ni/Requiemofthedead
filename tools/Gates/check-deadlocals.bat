@echo off
rem check-deadlocals - declarations nothing reads.
rem
rem   tools\Gates\check-deadlocals            findings + ratchet verdict
rem   tools\Gates\check-deadlocals --list     every finding, always exit 0
rem   tools\Gates\check-deadlocals --update   rewrite the per-mod baseline
rem
rem WHY IT IS NOT PART OF check-lua, which is the same binary: check-lua asks
rem whether the tree parses, and dead code parses. This asks whether every
rem declaration is read, which is a different question with a different verdict
rem and its own ceiling. Folding them would mean one exit code for "the file is
rem broken" and "the file carries debt", and those need different urgency.
rem
rem RATCHETED, unlike check-kahlua. The residue here is legitimate - a named
rem enum member, a function staged for an unbuilt feature - and each item is a
rem decision, not a lint fix. See check-deadlocals.py's header.

python "%~dp0check-deadlocals.py" %*
exit /b %errorlevel%
