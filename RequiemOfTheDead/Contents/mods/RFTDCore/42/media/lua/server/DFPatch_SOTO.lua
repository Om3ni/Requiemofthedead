-- DFPatch_SOTO.lua - Dragonfly removable third-party patch
--
-- Fixes a DEDICATED-SERVER crash in "Simple Overhaul: Traits and Occupations"
-- (SOTO) that silently kills exercise for any player with the HIGH_SWEATY trait.
--
-- Root cause (SOTO's own file layout, NOT ours):
--   * The exercise override lives in media/lua/SHARED/TimedActions/SOTOISFitnessAction.lua
--     and therefore runs on the dedicated SERVER (via NetTimedAction.animEvent).
--   * Its helpers SOAddThirst()/SOAddWetness() are defined only in
--     media/lua/CLIENT/SOTOMainFile.lua - and client Lua never loads on a dedicated
--     server. So server-side those globals are nil.
--   * When a HIGH_SWEATY player exercises, the shared action calls SOAddThirst() ->
--     "Object tried to call nil in exeLooped" (SOTOISFitnessAction.lua:29). The throw
--     aborts exeLooped BEFORE its final oldISFitnessAction_exeLooped(self) call, so the
--     vanilla reward (endurance drain + muscle strain + Fitness/Strength XP) never runs.
--     The animation still plays and body heat still rises (engine-side), which is exactly
--     the reported symptom: "I perform the actions and get warmer but gain nothing."
--   In SP / listen-server it works because client Lua is present; only the dedi breaks.
--
-- Fix: define the missing globals SERVER-SIDE so SOTO's shared action stops throwing and
-- reaches its vanilla tail call. Behaviour mirrors SOTOMainFile.lua (42.15) lines 99-164.
-- Trait lookups are nil-guarded (hasTraitSafe) so a missing SOTO-custom trait constant can
-- never re-introduce the same nil-call crash on the server.
--
-- REMOVABLE: delete this file to drop the patch - SOTO is untouched; nothing else in
-- Dragonfly depends on it. The `== nil` guards mean we NEVER clobber SOTO's real client-side
-- definitions (e.g. on a co-op host where both this and SOTO's client Lua load).

if not isServer() then return end

-- player:hasTrait throws on a nil trait (the exact bug we're fixing), so guard the lookup.
-- CharacterTrait.OVERWEIGHT/OBESE are engine constants present server-side; SOTO's custom
-- HIGH_THIRST/LOW_THIRST may not resolve here - if so the multiplier just stays neutral.
local function hasTraitSafe(player, trait)
    return trait ~= nil and player:hasTrait(trait) == true
end

local defined = {}

if SOAddThirst == nil then
    defined[#defined + 1] = "SOAddThirst"
    function SOAddThirst(player, chance, thirst)
        if ZombRand(100) > chance then return end
        local stats = player:getStats()
        local highMult = hasTraitSafe(player, CharacterTrait.HIGH_THIRST) and 2.0 or 1.0
        local lowMult  = hasTraitSafe(player, CharacterTrait.LOW_THIRST) and 0.50 or 1.0
        local v = stats:get(CharacterStat.THIRST) + (thirst * highMult * lowMult)
        stats:set(CharacterStat.THIRST, v > 1 and 1 or v)
    end
end

if SODecThirst == nil then
    defined[#defined + 1] = "SODecThirst"
    function SODecThirst(player, chance, thirst)
        if ZombRand(100) > chance then return end
        local stats = player:getStats()
        local v = stats:get(CharacterStat.THIRST) - thirst
        stats:set(CharacterStat.THIRST, v < 0 and 0 or v)
    end
end

if SOAddWetness == nil then
    defined[#defined + 1] = "SOAddWetness"
    function SOAddWetness(player, chance, wetness)
        if ZombRand(100) > chance then return end
        local stats = player:getStats()
        local overMult = hasTraitSafe(player, CharacterTrait.OVERWEIGHT) and 1.2 or 1.0
        local obeseMult = hasTraitSafe(player, CharacterTrait.OBESE) and 1.4 or 1.0
        local v = stats:get(CharacterStat.WETNESS) + (wetness * overMult * obeseMult)
        stats:set(CharacterStat.WETNESS, v > 100 and 100 or v)
    end
end

if SODecWetness == nil then
    defined[#defined + 1] = "SODecWetness"
    function SODecWetness(player, chance, wetness)
        if ZombRand(100) > chance then return end
        local stats = player:getStats()
        local overMult = hasTraitSafe(player, CharacterTrait.OVERWEIGHT) and 0.8 or 1.0
        local obeseMult = hasTraitSafe(player, CharacterTrait.OBESE) and 0.6 or 1.0
        local v = stats:get(CharacterStat.WETNESS) - (wetness * overMult * obeseMult)
        stats:set(CharacterStat.WETNESS, v < 0 and 0 or v)
    end
end

if #defined > 0 then
    print("[Dragonfly] DFPatch_SOTO: defined missing server-side SOTO helper(s): "
        .. table.concat(defined, ", ") .. " (exercise crash fix for HIGH_SWEATY players).")
else
    print("[Dragonfly] DFPatch_SOTO: SOTO helpers already present - no patch needed.")
end
