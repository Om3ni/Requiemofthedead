@echo off
rem check-kahlua - the Lua 5.1 features B42's Kahlua does not have.
rem
rem   tools\Gates\check-kahlua            violations only
rem   tools\Gates\check-kahlua --audit    also show every near-miss and why it
rem                                       was allowed
rem
rem WHY IT CANNOT BE FOLDED INTO AN EXISTING GATE: check-lua is luacheck, so
rem `next(t)` is valid syntax to it, and run-tests runs REAL Lua 5.1 on purpose,
rem where the global exists and every assertion over it passes. A violation is
rem green everywhere and throws in game. See check-kahlua.py's header.
rem
rem NO BASELINE, unlike pcall and helpers. Those ratchet because their subject
rem is a judgement call with a legitimate residue; there is no correct use of a
rem global that does not exist. Zero, always.

python "%~dp0check-kahlua.py" %*
exit /b %errorlevel%
