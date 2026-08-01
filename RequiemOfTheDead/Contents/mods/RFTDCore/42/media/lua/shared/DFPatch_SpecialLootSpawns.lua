-- DFPatch_SpecialLootSpawns.lua - Dragonfly removable log-noise patch
--
-- No-op stubs for a MISSING DEPENDENCY, not a fix. Installed mods ship item
-- scripts whose OnCreate references a `SpecialLootSpawns` Lua global that no
-- installed mod (and no vanilla file) defines - a helper from another of the
-- authors' mods that was never installed here. Every loot spawn of those items
-- logs `ERROR: no such function "SpecialLootSpawns.<name>"`.
--
-- The intended behaviour (a randomized magazine recipe) has NEVER worked on this
-- server and cannot be reconstructed without the defining mod, so the honest
-- patch is an empty function per referenced name: identical gameplay, zero spam.
--
-- THE REFERENCED NAMES DRIFT WITH THE COLLECTION - re-audit this list each
-- season. Verified against the live workshop tree 2026-07-31:
--
--   OnCreateRecipeMagazine   B42 Rain's Firearms & Gun Parts (+ Expanded)
--                            [3773858287] - ammomagrecipes.txt x4, explosives.txt
--   OnCreateHobbyMagazine    ShelterHold_Beehive [3596827035] -
--                            HoldItems_Beehive.txt
--
-- Both names above are current. Two earlier entries are gone and were removed
-- with them: OnCreateRecipeMagazine was originally here for TrueActionsDancing's
-- dance mags (TAD is still installed but no longer references it at all), and
-- OnCreateRandomColor for MeleeWeaponUpgrades' umbrellas/spears (uninstalled).
-- OnCreateHobbyMagazine was added 2026-07-31 - it had never been stubbed, so the
-- beehive magazines were still erroring on every spawn while the two names this
-- file was actually written for had both stopped being used. That is the failure
-- mode to watch for: the file looks maintained because it exists.
--
-- Stub only what is REFERENCED. An unreferenced stub is dead code that names a
-- mod nobody runs, which is exactly how the drift above went unnoticed.
--
-- The `or {}` / per-key guards mean that if the real defining mod is ever
-- installed, its implementation wins and this stub does nothing.
--
-- In shared/ so it covers server loot fills (dedi) and local spawns
-- (SP / co-op host) alike.
--
-- REMOVABLE: delete this file to restore the (harmless) engine errors.

SpecialLootSpawns = SpecialLootSpawns or {}

if SpecialLootSpawns.OnCreateRecipeMagazine == nil then
    SpecialLootSpawns.OnCreateRecipeMagazine = function() end
end

if SpecialLootSpawns.OnCreateHobbyMagazine == nil then
    SpecialLootSpawns.OnCreateHobbyMagazine = function() end
end

print("[Dragonfly] DFPatch_SpecialLootSpawns: stubbed missing OnCreate callbacks (Rain's Firearms mags / ShelterHold beehive mags)")
