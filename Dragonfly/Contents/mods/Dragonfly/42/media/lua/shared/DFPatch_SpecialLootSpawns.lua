-- DFPatch_SpecialLootSpawns.lua — Dragonfly removable log-noise patch
--
-- No-op stub for a MISSING DEPENDENCY, not a fix. Two installed mods ship
-- item scripts whose OnCreate references a `SpecialLootSpawns` Lua global
-- that no installed mod (and no vanilla file) defines — presumably a
-- helper from another of the authors' mods that was never installed here:
--
--   TrueActionsDancing (TAD_ordinary.txt):
--       OnCreate = SpecialLootSpawns.OnCreateRecipeMagazine   (dance mags)
--   MeleeWeaponUpgrades* (CMUSpear.txt / CMUUmbrella.txt):
--       OnCreate = SpecialLootSpawns.OnCreateRandomColor      (umbrellas/spears)
--
-- Every loot spawn of those items logs
--   ERROR: no such function "SpecialLootSpawns.OnCreateRecipeMagazine"
-- (48x in one live morning). The intended behaviour (randomized magazine
-- recipe / random weapon color) has NEVER worked on this server and cannot
-- be reconstructed without the defining mod, so the honest patch is an
-- empty function per referenced name: identical gameplay, zero log spam.
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

if SpecialLootSpawns.OnCreateRandomColor == nil then
    SpecialLootSpawns.OnCreateRandomColor = function() end
end

print("[Dragonfly] DFPatch_SpecialLootSpawns: stubbed missing OnCreate callbacks (TAD dance mags / CMU weapon colors)")
