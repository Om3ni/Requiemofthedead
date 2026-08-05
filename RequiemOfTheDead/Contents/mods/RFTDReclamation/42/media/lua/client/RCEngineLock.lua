-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCEngineLock - blocks non-staff players from salvaging the Engine (§2).
--
-- Why: players strip the Engine out of otherwise-good vehicles for motor
-- parts, wrecking the shared fleet. With the lock on, an engine leaves a car
-- only via wear/crashes - which is also what makes the dismantle engine-gate
-- meaningful (you can't strip an engine below the threshold on purpose).
--
-- Migrated from Dragonfly's DFEngineLock (remove there once this verifies).
-- Client-side gate + server ledger, the house model: PZ vehicle mechanics
-- are client-authoritative with no server-side Lua veto, so we gate the two
-- menu entry points and AUDIT actual pulls. The server writes the bypass
-- flag from ITS OWN access-level check on the sender - a non-staff ledger
-- line while the lock is on = a defeated/modified client.
--
-- Wrap points (pure Lua, media/lua/client/Vehicles/ISUI/):
--   ISVehicleMechanics.onTakeEngineParts - "Take Engine Parts" (salvage path)
--   ISVehiclePartMenu.onUninstallPart    - "Uninstall", vetoed for id "Engine"
-- Telemetry: ISTakeEngineParts:complete - the moment parts actually land.

if isServer() and not isClient() then return end

RCEngineLock = RCEngineLock or {}

local function lockActive(playerObj)
    local c = RCShared.cfg()
    if not c.enabled or not c.engineLockEnabled then return false end
    return not RCShared.isAdmin(playerObj)
end

local function deny(playerObj)
    RCShared.halo(playerObj, getText("IGUI_RC_EngineLocked"), true)
end

-- One small packet at the moment engine parts are actually obtained (rare).
-- Fires for EVERYONE incl. staff so the ledger is complete; the server
-- decides the bypass flag itself (see RCServer.hEnginePull).
local function reportPull(character, part)
    if not (character and sendClientCommand) then return end
    local args = {}
    pcall(function()
        local vehicle = part and part.getVehicle and part:getVehicle()
        if vehicle then
            args.vehicle = vehicle:getScriptName()
            args.vid = vehicle:getId()
            args.x = math.floor(vehicle:getX())
            args.y = math.floor(vehicle:getY())
            args.z = math.floor(vehicle:getZ())
        end
    end)
    pcall(sendClientCommand, character, RCShared.MODULE, "enginePull", args)
end

-- Wrapped at OnGameStart, never file-load: a wrap on a class that isn't
-- defined yet silently no-ops (the RCClaimItemLock dead-gate bug, 2026-06-30).
local function applyWraps()
    if not (ISVehicleMechanics and ISVehiclePartMenu) then return end
    if ISVehicleMechanics.RC_engineLockWrapped then return end
    ISVehicleMechanics.RC_engineLockWrapped = true

    -- "Take Engine Parts" is only ever offered for the Engine part, so any
    -- call here is an engine salvage attempt.
    local origTake = ISVehicleMechanics.onTakeEngineParts
    ISVehicleMechanics.onTakeEngineParts = function(playerObj, part)
        if lockActive(playerObj) then deny(playerObj); return end
        return origTake(playerObj, part)
    end

    -- "Uninstall" covers every part; veto only the Engine itself.
    local origUninstall = ISVehiclePartMenu.onUninstallPart
    ISVehiclePartMenu.onUninstallPart = function(playerObj, part)
        if lockActive(playerObj) and part and part.getId and part:getId() == "Engine" then
            deny(playerObj)
            return
        end
        return origUninstall(playerObj, part)
    end

    -- Telemetry wrap, downstream of the block (see header).
    if ISTakeEngineParts and not ISTakeEngineParts.RC_pullWrapped then
        ISTakeEngineParts.RC_pullWrapped = true
        local origComplete = ISTakeEngineParts.complete
        ISTakeEngineParts.complete = function(self, ...)
            pcall(reportPull, self.character, self.part)
            return origComplete(self, ...)
        end
    end
    RCShared.dbg("engine-lock wraps applied")
end

Events.OnGameStart.Add(applyWraps)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
