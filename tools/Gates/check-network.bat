@echo off
rem check-network - one wire token, one executable intake. See check-network.py's
rem header for the two live failures that motivated it, and network-config.json
rem for what "observe only" is allowed to mean (it is a reading job, not a guess).
rem
rem   tools\check-network              check; non-zero exit on any violation
rem   tools\check-network --list       every intake, observer and registration
rem   tools\check-network --update     accept the current legacy count as baseline
rem
rem EXPECTED RED, with ONE violation left as of 2026-08-19: RFTDHusbandry's
rem split intake (HBCommands.lua + HBSexCheck_Server.lua). It is named work in
rem refactor-networking.md - Track A item A1 - and this gate goes green when it
rem lands. Do not baseline it away to quiet it.
rem
rem RFTDCore's second intake, the other violation this gate was written to
rem catch, was cleared 2026-08-19: RDTripwire's listener became two RDNet
rem registrations.

python "%~dp0check-network.py" %*
exit /b %errorlevel%
