@echo off
rem sync-client-workshop - mirror the real payload tree to the dev client.
rem
rem WHY: the PZ animator (AdvancedAnimator.buildChecksum) cannot checksum a
rem mod that ships AnimSets when the mod is reached through a junction - it
rem canonicalizes the folder (resolving the junction) but looks files up by
rem the junction path. Fatal on the dedi at boot, fatal on the CLIENT at
rem server-join (Core.ResetLua), verified 2026-08-01 with RFTDEchoes. So the
rem REAL tree lives at C:\Mosaic\pzdata\Workshop\RequiemOfTheDead (the dedi
rem reads it directly; the repo's RequiemOfTheDead\ folder is a junction to
rem it), and the dev client gets this MIRROR instead of a junction.
rem
rem Run after edits, before joining Mosaic with the dev client. If you forget,
rem PZ's join-time mod checksum kicks the stale client loudly - the skew
rem announces itself, nothing corrupts.
rem
rem Exit codes: robocopy 0-7 = success (1 means "files copied"). 8+ = failure.

robocopy "C:\Mosaic\pzdata\Workshop\RequiemOfTheDead" "C:\Users\micha\Zomboid\Workshop\RequiemOfTheDead" /MIR /R:1 /W:1 /NFL /NDL /NJH
if %errorlevel% geq 8 (
    echo SYNC FAILED - read robocopy output above.
    exit /b 1
)
echo Client workshop mirror is current.
exit /b 0
