-- DFEngineLock - stop non-admin players from dismantling vehicle engines.
--
-- Problem on the server: players strip the Engine out of otherwise-pristine
-- vehicles purely to salvage motor parts (which are craftable here), wrecking
-- good vehicles for the rest of the playerbase.
--
-- The two vanilla entry points that take/remove the engine, both in
-- media/lua/client/Vehicles/ISUI/, are pure Lua so we wrap them client-side:
--   * ISVehicleMechanics.onTakeEngineParts  -> "Take Engine Parts" (the salvage path)
--   * ISVehiclePartMenu.onUninstallPart     -> "Uninstall" (only blocked for part id "Engine")
-- Blocked for regular players; admins are always allowed through.
--
-- Scope note: this is client-side gating. It fully stops normal players, but is
-- not cheat-proof (PZ exposes no server-side canUninstallPart veto in Lua). A
-- determined modified-client user could bypass it; true enforcement needs Java.
--
-- Gated by SandboxVars.RFTDDragonfly.EngineLockEnabled (default ON).
--
-- Tamper telemetry: separately from the block, we wrap ISTakeEngineParts:complete
-- (the moment parts are actually obtained, downstream of the menu gate) and mirror
-- every completed pull to the server log via a dedicated client command. The block
-- should mean no non-admin ever reaches this; a non-admin line in the server log is
-- therefore a direct signal that someone bypassed the restriction. (A client running
-- with Dragonfly fully removed evades this - no pure-Lua mod can see it server-side.)

local DEBUG = false -- flip true for verbose [DF-EngineLock] tracing

local LOG_MODULE = "DFEngineLock" -- client->server log mirror channel

local function dbg(fmt, ...)
    if not DEBUG then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[DF-EngineLock] " .. (ok and msg or fmt))
end

local BLOCKED_MSG = "Engine dismantling is disabled on this server."

local function cfg() return SandboxVars.RFTDDragonfly or {} end

-- Block when the rule is enabled and the actor is a non-admin client.
local function ruleActive()
    if cfg().EngineLockEnabled == false then return false end
    return not isAdmin()
end

local function notify(playerObj)
    if HaloTextHelper and HaloTextHelper.addBadText and playerObj then
        HaloTextHelper.addBadText(playerObj, BLOCKED_MSG)
    end
end

local function isEnginePart(part)
    return part and part.getId and part:getId() == "Engine"
end

-- Mirror a completed engine-parts pull to the server log. Fires for everyone
-- (admins included) so the log is complete; the server side flags non-admins.
local function reportPull(playerObj, part)
    if not playerObj or not sendClientCommand then return end
    local vehicle = part and part.getVehicle and part:getVehicle()
    local script = vehicle and vehicle:getScript()
    local args = {
        admin   = isAdmin() and true or false,
        vehicle = script and script:getName() or "?",
        vid     = vehicle and vehicle:getId() or -1,
        x       = vehicle and math.floor(vehicle:getX()) or -1,
        y       = vehicle and math.floor(vehicle:getY()) or -1,
        z       = vehicle and math.floor(vehicle:getZ()) or 0,
    }
    pcall(sendClientCommand, playerObj, LOG_MODULE, "pull", args)
    dbg("reported pull vehicle=%s id=%s", args.vehicle, tostring(args.vid))
end

local hooksInstalled = false

local function installHooks()
    if hooksInstalled then return end
    if not ISVehicleMechanics or not ISVehiclePartMenu then
        dbg("installHooks: vehicle UI globals still nil - aborting")
        return
    end
    hooksInstalled = true

    -- Telemetry wrap: log the actual pull regardless of the block / admin status,
    -- so a bypassed block still surfaces in the server log.
    if ISTakeEngineParts then
        local origComplete = ISTakeEngineParts.complete
        function ISTakeEngineParts:complete()
            reportPull(self.character, self.part)
            return origComplete(self)
        end
    else
        dbg("installHooks: ISTakeEngineParts nil - pull telemetry not installed")
    end

    -- "Take Engine Parts" is only ever offered for the Engine part, so any call
    -- here is an engine salvage attempt.
    local origTake = ISVehicleMechanics.onTakeEngineParts
    function ISVehicleMechanics.onTakeEngineParts(playerObj, part)
        if ruleActive() then
            dbg("blocked onTakeEngineParts by %s", tostring(playerObj and playerObj:getUsername()))
            notify(playerObj)
            return
        end
        return origTake(playerObj, part)
    end

    -- "Uninstall" applies to every part; only veto it for the Engine itself.
    local origUninstall = ISVehiclePartMenu.onUninstallPart
    function ISVehiclePartMenu.onUninstallPart(playerObj, part)
        if ruleActive() and isEnginePart(part) then
            dbg("blocked onUninstallPart(Engine) by %s", tostring(playerObj and playerObj:getUsername()))
            notify(playerObj)
            return
        end
        return origUninstall(playerObj, part)
    end
end

if ISVehicleMechanics and ISVehiclePartMenu then
    installHooks()
else
    Events.OnGameStart.Add(installHooks)
end

-- Admin-panel status badge.
Events.OnGameStart.Add(function()
    if cfg().EngineLockEnabled == false then return end
    if DFRegistry and DFRegistry.registerStatusBadge then
        DFRegistry.registerStatusBadge{
            id   = "engineLock",
            text = "Engine-dismantle lock active",
        }
    end
end)
