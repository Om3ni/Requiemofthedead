-- DFActionSpeed.lua - sandbox-tunable speed scaling for timed actions.
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
-- Speed-up only, per-family enum, values 1..6 (shown 0..5 in the UI):
--   1 = vanilla, 2 = 10x, 3 = 20x, 4 = 30x, 5 = 40x, 6 = instant.
-- Five families: Reading / Foraging / Cleaning / Repair / Dismantle. Anything outside these
-- is never touched (no general/global lever).
--
-- Honest guard: INVENTORY TRANSFERS ARE EXCLUDED (the server completes them on vanilla timing
-- regardless, so scaling only ever lies there).

require "TimedActions/ISBaseTimedAction"

local NEVER_SCALE = { ISInventoryTransferAction = true }

-- The "budget": enum value (1-indexed) -> maxTime divisor. 1 = vanilla.
local INSTANT = "instant"
local VALUE_DIV = {
    [1] = 1.0,      -- Vanilla
    [2] = 10.0,     -- 10x faster
    [3] = 20.0,     -- 20x faster
    [4] = 30.0,     -- 30x faster
    [5] = 40.0,     -- 40x faster
    [6] = INSTANT,  -- Instant (maxTime -> 1)
}

-- Per-family categories: one sandbox field drives a family of action Types.
local CATEGORIES = {
    { var = "ASReading",   types = { "ISReadABook", "ISReadWorldMap" } },
    { var = "ASForaging",  types = { "ISForageAction" } },
    { var = "ASCleaning",  types = { "ISCleanBlood", "ISCleanBurn", "ISCleanGraffiti", "ISWashYourself", "ISWashClothing" } },
    { var = "ASRepair",    types = { "ISRepairClothing", "ISRepairEngine", "ISRepairLightbar" } },
    { var = "ASDismantle", types = { "ISDismantleAction" } },
}
local TYPE_VAR = {}
for _, c in ipairs(CATEGORIES) do
    for _, t in ipairs(c.types) do TYPE_VAR[t] = c.var end
end

local function cfg() return SandboxVars.RFTDDragonfly or {} end

local function enabled()
    local s = cfg()
    if s.Enabled == false then return false end
    return s.ActionSpeedEnabled ~= false -- default ON
end

-- Enum value (1..6) for an action Type. Only the five named families scale; everything else
-- stays vanilla (returns 1).
local function valueFor(atype)
    local var = atype and TYPE_VAR[atype]
    if not var then return 1 end
    local v = tonumber(cfg()[var]) or 1
    if v < 1 then v = 1 elseif v > 6 then v = 6 end
    return v
end

local function install()
    if ISBaseTimedAction._DFAS_Patched then return end
    ISBaseTimedAction._DFAS_Patched = true

    local origAdjust = ISBaseTimedAction.adjustMaxTime
    ISBaseTimedAction.adjustMaxTime = function(self, maxTime)
        local r = origAdjust(self, maxTime)
        if not enabled() then return r end
        if type(r) ~= "number" or r <= 0 then return r end -- skip -1/uninitialised
        local atype = self and self.Type
        if atype and NEVER_SCALE[atype] then return r end
        local div = VALUE_DIV[valueFor(atype)]
        if not div or div == 1.0 then return r end
        if div == INSTANT then return 1 end
        return math.max(1, r / div)
    end

    print("[Dragonfly] DFActionSpeed installed (" .. (isServer() and "server" or "client/SP") .. "; enum maxTime scaling; transfers excluded).")
end

-- Client/SP: OnGameStart. Dedicated server: OnServerStarted. The _DFAS_Patched guard makes
-- a second install a no-op, so SP (where only OnGameStart fires) is fine.
Events.OnGameStart.Add(function() if enabled() then install() end end)
if isServer() then
    Events.OnServerStarted.Add(function() if enabled() then install() end end)
end
