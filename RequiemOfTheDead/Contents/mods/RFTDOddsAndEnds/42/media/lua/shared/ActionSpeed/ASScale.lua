-- SPDX-License-Identifier: GPL-3.0-or-later
-- ASScale.lua - Action Speed: sandbox-tunable speed scaling for timed actions.
--
-- WHY THIS IS NOT IN DRAGONFLY (moved 2026-07-30, was DFActionSpeed.lua): this
-- is a world rule, not an admin tool. Everything else in Dragonfly is
-- something staff CLICK - the panel, the item editor, Longstrider, the debug
-- gate. Nobody ever "uses" action speed: it is decided once before anyone logs
-- in, and then every player lives inside the result. That is the same category
-- as XP multiplier or loot rarity, which vanilla puts in the sandbox and
-- nobody calls administration. It landed in Dragonfly because Dragonfly owned
-- a sandbox page, which is proximity, not kind. The tell was always that
-- ASHood and ASMechanics are split for BALANCE reasons (see below) - a
-- judgement about what the game should feel like, with nothing administrative
-- about it.
--
-- THE LEVER IS maxTime (the field). create() does `self.maxTime = self:adjustMaxTime(...)`
-- right before the engine captures the field, so we hook adjustMaxTime and scale its result.
--
-- PLAN A (server-authoritative): in multiplayer the action completes when the SERVER's
-- ActionManager signals done (the client setWaitForFinished + isDone), so scaling only on
-- the client just moves the local progress bar while the real action runs the server's
-- vanilla duration (anim trails the bar). This file is therefore in shared/ and installs the
-- hook on BOTH sides: client/SP via OnGameStart, dedicated server via OnServerStarted. If the
-- server runs the Lua adjustMaxTime for net actions, the server-authoritative duration is
-- scaled too and the action genuinely speeds up in MP.
--
-- Speed-up only, per-family enum, values 1..8 (shown 0..7 in the UI):
--   1 = vanilla, 2 = 2x, 3 = 5x, 4 = 10x, 5 = 20x, 6 = 30x, 7 = 40x, 8 = instant.
-- The 2x and 5x rungs were added 2026-07-30; before that the scale jumped straight from
-- vanilla to 10x, which left no sane setting for anything you want merely brisk rather
-- than trivialised. Adding them RENUMBERED every value above 1 - free at the time because
-- the sandbox rename out of Dragonfly meant no server had stored values yet. Renumbering
-- again later is not free: it silently redefines every dial a server has already saved.
--
-- Eight families: Reading / Foraging / Cleaning / Repair / Dismantle / Vehicle hood /
-- Vehicle mechanics / Thread picking. Anything outside these is never touched (no
-- general/global lever).
-- Hood and mechanics are separate dials on purpose - popping the hood instantly is a quality-
-- of-life ask, making every part swap instant is a balance decision. Do not merge them.
--
-- TWO KEYS, NOT ONE (added with thread picking, verified against the 42.20 decompile and
-- the shipped Lua). Seven of the families key on the action's Type. Thread picking cannot:
-- it is not a timed action at all but a CRAFT RECIPE - `craftRecipe PickThread` in
-- media/scripts/generated/recipes/recipes_tailoring.txt, time = 200, output Base.Thread -
-- and every hand-crafted recipe in B42 arrives as the same Type, ISHandcraftAction. Keying
-- on Type would scale forging, carpentry and cooking along with it. So a second key exists:
-- the recipe's own script name, read off the action's craftRecipe field. The chain, all
-- confirmed rather than assumed:
--   * ISHandcraftAction = ISBaseTimedAction:derive("ISHandcraftAction"), and ISBaseObject
--     :derive sets o.Type = type - so the Type IS shared across all handcraft recipes.
--   * ISHandcraftAction:new sets o.craftRecipe, and o.maxTime = o:getDuration(), which is
--     craftRecipe:getTime(character) * 5.
--   * CraftRecipe.getTime(IsoGameCharacter) (CraftRecipe.java:211) is skill-scaled:
--     time - (skillAboveRequirement * time/20). PickThread is 1000 maxTime at Tailoring 1,
--     800 at Tailoring 5.
--   * CraftRecipe.getName() (CraftRecipe.java:146) returns the script name, and CraftRecipe
--     is setExposed (LuaManager.java:2242), so Lua may call it.
--   * ISBaseTimedAction:create() line 79 does self.maxTime = self:adjustMaxTime(self.maxTime)
--     - so the hook reaches actions that set maxTime in new(), which is all of these.
-- Adding another recipe to a family is one line in RECIPE_VAR; adding a whole recipe family
-- is that plus a sandbox option.
--
-- Honest guard: INVENTORY TRANSFERS ARE EXCLUDED (the server completes them on vanilla timing
-- regardless, so scaling only ever lies there). Three more things look like they belong in the
-- hood/mechanics families and do not:
--   * ISOpenVehicleDoor (the hood door itself) is ANIMATION-bound, not maxTime-bound - it
--     reports duration 0, re-sets its own time in start(), and force-completes when the sprite
--     anim ends. So the hood dial works through ISOpenMechanicsUIAction (the 200-tick mechanics
--     screen wait, which is the part you actually feel); the door swing stays vanilla length no
--     matter what the dial says.
--   * ISWashVehicle reports duration -1, so this lever cannot reach it at all.
--   * Fuel and tire actions (ISAddGasolineToVehicle, ISTakeGasolineFromVehicle,
--     ISRefuelFromGasPump, ISInflateTire, ISDeflateTire) ARE the fluid/PSI transfer - their
--     duration is derived from the amount moved and they stream amountSent while running.
--     Same lying-progress-bar risk as inventory transfers, so they are left alone.
-- Sibling RFTD mods tune their OWN actions directly (e.g. Reclamation's RCDismantleAction via
-- RFTDReclamation.DismantleTimePercent) - never list a sibling's action Type here, or the two
-- levers stack.

require "TimedActions/ISBaseTimedAction"
require "OEShared"

local NEVER_SCALE = { ISInventoryTransferAction = true }

-- The "budget": enum value (1-indexed) -> maxTime divisor. 1 = vanilla.
-- Keep in lockstep with numValues and the OE_ASpeed_option* labels in
-- sandbox-options.txt / Translate; a mismatch shows the player one speed and
-- gives them another.
local INSTANT = "instant"
local VALUE_DIV = {
    [1] = 1.0,      -- Vanilla
    [2] = 2.0,      -- 2x faster
    [3] = 5.0,      -- 5x faster
    [4] = 10.0,     -- 10x faster
    [5] = 20.0,     -- 20x faster
    [6] = 30.0,     -- 30x faster
    [7] = 40.0,     -- 40x faster
    [8] = INSTANT,  -- Instant (maxTime -> 1)
}
local MAX_VALUE = 8

-- Per-family categories: one sandbox field drives a family of action Types.
local CATEGORIES = {
    { var = "ASReading",   types = { "ISReadABook", "ISReadWorldMap" } },
    { var = "ASForaging",  types = { "ISForageAction" } },
    { var = "ASCleaning",  types = { "ISCleanBlood", "ISCleanBurn", "ISCleanGraffiti", "ISWashYourself", "ISWashClothing" } },
    { var = "ASRepair",    types = { "ISRepairClothing", "ISRepairEngine", "ISRepairLightbar" } },
    { var = "ASDismantle", types = { "ISDismantleAction" } },
    -- Hood is its OWN dial, deliberately split from the mechanics family: the common ask is a
    -- fast hood WITHOUT trivialising bench work, so these two must never share a var.
    { var = "ASHood",      types = { "ISOpenMechanicsUIAction" } },
    { var = "ASMechanics", types = { "ISInstallVehiclePart", "ISUninstallVehiclePart",
                                     "ISFixVehiclePartAction", "ISTakeEngineParts" } },
}
local TYPE_VAR = {}
for _, c in ipairs(CATEGORIES) do
    for _, t in ipairs(c.types) do TYPE_VAR[t] = c.var end
end

-- The second key: craft recipes by script name. See the header - every B42
-- handcraft recipe shares one Type, so the recipe name is the only thing that
-- tells thread picking apart from forging a machete.
--
-- The RIPIT entries overlap RIClient's own RIP_RECIPES. House rule: no module
-- may depend on a sibling, so each carries its own copy and either can be
-- deleted outright. Add a recipe in one place and it silently runs at vanilla
-- speed; add it in both.
--
-- This list is INTENTIONALLY WIDER than RIClient's. The four cut recipes below
-- have no bulk button any more - RIClient dropped that set on purpose, and its
-- RIP_RECIPES note says why - but the recipes themselves are alive and you
-- still craft them by hand from the panel, so they still deserve the tuned
-- speed. This is not drift; do not "resync" by deleting them.
local RECIPE_VAR = {
    PickThread          = "ASThread",
    PickAramidThread    = "ASThread",

    RipClothing         = "ASRipIt",
    RipDenimClothing    = "ASRipIt",
    RipSheets           = "ASRipIt",
    CutUpBelt           = "ASRipIt",
    CutUpLeather_Large  = "ASRipIt",
    CutUpLeather_Medium = "ASRipIt",
    CutUpLeather_Small  = "ASRipIt",
}

-- Recipe name off a handcraft action, or nil. pcall because craftRecipe is a
-- Java object reached through a field a future build may rename - and any
-- action (foreign mods included) can carry a craftRecipe field of some other
-- shape whose getName is not CraftRecipe's - and a throw here would take out
-- adjustMaxTime for EVERY action in the game. Allocation-free direct form:
-- this runs once per action create.
local function recipeVarFor(action)
    local r = action and action.craftRecipe
    if not r or not r.getName then return nil end
    local ok, name = pcall(r.getName, r)
    if not ok or type(name) ~= "string" then return nil end
    return RECIPE_VAR[name]
end

local function cfg() return SandboxVars.RFTDOddsAndEnds or {} end

-- Only this module's own switch. The old build also returned false on
-- Dragonfly's master RFTDDragonfly.Enabled, which was defensible while the
-- file lived there and would be a foreign kill switch now: turning off the
-- admin panel must not change how long it takes anyone to read a book.
local function enabled()
    return OEShared.enabled("ActionSpeedEnable")
end

-- Enum value (1..8) for an action. Type first, then - only if the Type is not
-- itself a family - the craft recipe name. Order matters: a Type match must
-- win, so listing a Type never gets quietly overridden by a recipe lookup.
-- Everything unmatched stays vanilla (returns 1).
local function valueFor(action, atype)
    local var = atype and TYPE_VAR[atype]
    if not var then var = recipeVarFor(action) end
    if not var then return 1 end
    local v = tonumber(cfg()[var]) or 1
    if v < 1 then v = 1 elseif v > MAX_VALUE then v = MAX_VALUE end
    return v
end

local function install()
    if ISBaseTimedAction._RFTD_ASPatched then return end
    ISBaseTimedAction._RFTD_ASPatched = true

    local origAdjust = ISBaseTimedAction.adjustMaxTime
    ISBaseTimedAction.adjustMaxTime = function(self, maxTime)
        local r = origAdjust(self, maxTime)
        if not enabled() then return r end
        if type(r) ~= "number" or r <= 0 then return r end -- skip -1/uninitialised
        local atype = self and self.Type
        if atype and NEVER_SCALE[atype] then return r end
        local div = VALUE_DIV[valueFor(self, atype)]
        if not div or div == 1.0 then return r end
        if div == INSTANT then return 1 end
        return math.max(1, r / div)
    end

    print("[RFTDOddsAndEnds] ActionSpeed installed (" .. (isServer() and "server" or "client/SP") .. "; enum maxTime scaling; transfers excluded).")
end

-- Client/SP: OnGameStart. Dedicated server: OnServerStarted. The patched guard
-- makes a second install a no-op, so SP (where only OnGameStart fires) is fine.
Events.OnGameStart.Add(function() if enabled() then install() end end)
if isServer() then
    Events.OnServerStarted.Add(function() if enabled() then install() end end)
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
