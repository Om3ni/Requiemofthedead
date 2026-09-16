-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBTemperament - suite policy on animal-definition temperament flags:
-- animals never thump (batter fences/doors) and males never fight each other.
--
-- WHY: a penned bull or ram at high stress/hunger batters its own enclosure
-- down, and two mating-season males in one designation zone fight until one
-- dies. On a persistent server both read as griefing-by-physics: a player logs
-- off with a full pen and logs back in to splinters. Vanilla exposes both
-- behaviors as per-animal definition booleans, so this is pure data policy -
-- no engine surface is patched, no behavior code is hooked.
--
-- WHAT EACH FLAG CLOSES (read 2026-08-30):
--  * canThump=false closes both thump lanes: pathfinding stops routing
--    through thumpable obstacles (IsoAnimal.java:2485-2490
--    shouldBreakObstaclesDuringPathfinding → PathFindRequest.java:49-58) and
--    the act itself is refused (IsoAnimal.java:2497-2500 animalShouldThump),
--    including its attackedBy branch. Vanilla uses this exact flag the same
--    way per-animal (e.g. TurkeyDefinitions.lua:103).
--  * dontAttackOtherMale=true closes male-vs-male fight initiation
--    (BaseAnimalBehavior.java:543-549 checkAttackBehavior). The stress-attack
--    lane (BaseAnimalBehavior.java:1332-1349) targets PLAYERS only and is
--    deliberately untouched: a stressed low-acceptance bull still charges a
--    careless player. The animal info panel reads the same field
--    (ISAnimalUI.lua:189 → IsoAnimal.java:3035-3036 attackOtherMales), so the
--    UI stops advertising fights instead of lying about them.
--
-- TIMING: Java builds its def objects lazily from this Lua table on first
-- access (AnimalDefinitions.java:153-181 getAnimalDefs; canThump parsed at
-- :464, dontAttackOtherMale at :470), long after Lua load finishes. Mod files
-- always run after every vanilla file of the tier - LoadDirBase sorts the
-- game list, then APPENDS mod files (LuaManager.java:1196-1199) - so at file
-- scope here the vanilla *Definitions.lua table is complete, on client and
-- dedicated server alike. Limit: animals registered by a third-party mod
-- loading AFTER RFTDHusbandry are not swept.
--
-- MP: shared tier on purpose. Server and every client each parse defs from
-- their own Lua env, so whichever machine runs a given animal's AI sees the
-- same flags, and the Lua checksum (LuaManager.java:1211-1212) guarantees no
-- client is running without this file.

for _, def in pairs(AnimalDefinitions.animals) do
    def.canThump = false
    def.dontAttackOtherMale = true
end
