@echo off
rem check-translations - every referenced translation key exists in every
rem shipped language; orphaned keys reported as advisory. See the .py header
rem for the O&E Workshop gap that bought it (a whole section with no Spanish,
rem invisible to every other gate).

python "%~dp0check-translations.py" %*
exit /b %errorlevel%
