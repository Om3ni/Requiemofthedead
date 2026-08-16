-- SPDX-License-Identifier: GPL-3.0-or-later
-- NOClient.lua - local horn audio and multiplayer relay client for Noise Ordinance.
if isServer() then return end

require "OEShared"
require "Vehicles/ISUI/ISVehicleMenu"

NoiseOrdinance = NoiseOrdinance or {}

-- Read at use time, not at load: SandboxVars is not up when this file is
-- walked. Same idiom as the other modules.
function NoiseOrdinance.isEnabled()
    return OEShared.enabled("NoiseOrdinanceEnable")
end


local HORN_BY_PREFIX = {
    { prefix = "SportsCar", sound = "VehicleHornSportsCar" },
    { prefix = "OffRoad",   sound = "VehicleHornJeep" },
    { prefix = "Van",       sound = "VehicleHornVan" },
}
local DEFAULT_HORN = "VehicleHornStandard"

-- The server owns a ten-second lease. This slightly later client deadline is
-- the final backstop if the server stop command itself is lost.
local CLIENT_FAILSAFE_MS = 12000

local function hornSoundFor(vehicle)
    -- getScriptName (BaseVehicle:1593) answers with a field even when the
    -- script itself is null; the caller has already nil-checked the vehicle.
    local name = tostring(vehicle:getScriptName() or "")
    for _, entry in ipairs(HORN_BY_PREFIX) do
        if name:sub(1, #entry.prefix) == entry.prefix then return entry.sound end
    end
    return DEFAULT_HORN
end

-- vehicleId -> { instance, emitter, at }
--
-- THE EMITTER IS CAPTURED AT START AND THE STOP GOES THROUGH IT - never a
-- fresh getVehicleById lookup. The beta crew caught why (2026-08-08): a
-- vehicle that streams out mid-blast stops resolving (and one that streams
-- back in has a NEW emitter), so a lookup-based stop was a silent no-op.
-- The looped instance survived on the abandoned emitter, which the engine no
-- longer position-updates - a horn sounding forever, pinned to where the
-- vehicle was. The handle pair we hold stays valid for exactly as long as
-- the loop we started on it.
local playing = {}

local function stopFor(id)
    local rec = playing[id]
    if not rec then return end
    -- FMODSoundEmitter.stopSoundLocal:124-139 stops and releases this exact
    -- handle without emitting the StopSound packet used by stopSound:89-120.
    rec.emitter:stopSoundLocal(rec.instance)
    playing[id] = nil
end

local function startFor(id)
    -- Already sounding. Reached routinely, not defensively: the server echoes
    -- the broadcast back to the honking player, who started theirs locally the
    -- moment they pressed the key.
    if playing[id] then
        playing[id].at = getTimestampMs()
        return
    end
    local vehicle = getVehicleById(id)
    if not vehicle then return end
    -- VehicleSoundOwner.hasHorn:73-75 dereferences getScript(), so establish
    -- that precondition explicitly instead of hiding a scriptless vehicle.
    if not vehicle:getScript() then return end
    if not vehicle:hasHorn() then return end
    local emitter = vehicle:getEmitter()
    local sound = hornSoundFor(vehicle)
    -- FMODSoundEmitter.playSoundLooped:449-459 emits a PlaySound or
    -- PlayWorldSound packet on clients. The Impl method at :463-465 is the
    -- engine's local-only path and is also what HornSound.java:20-29 uses.
    local instance = emitter:playSoundLoopedImpl(sound)
    if instance and instance ~= 0 then
        playing[id] = { instance = instance, emitter = emitter, at = getTimestampMs() }
    end
end

-- pairs(), never next(): Kahlua registers no global `next`, and the offline
-- suite runs on real Lua 5.1 where it exists, so that trap passes tests and
-- throws on the dedi. Documented at length in InventoryCollapse/ICClient.lua.
--
-- The table is empty except while somebody within earshot is actually honking,
-- so this costs a table lookup per tick in the normal case.
local function reap()
    local now = getTimestampMs()
    local stale
    for id, rec in pairs(playing) do
        if now - rec.at > CLIENT_FAILSAFE_MS then
            stale = stale or {}
            stale[#stale + 1] = id
        end
    end
    if not stale then return end
    for _, id in ipairs(stale) do stopFor(id) end
end
Events.OnTick.Add(reap)

-- ---------------------------------------------------------------------------
-- The seam
-- ---------------------------------------------------------------------------

local origStart = ISVehicleMenu.onHornStart
local origStop  = ISVehicleMenu.onHornStop

-- The vehicle the local player last started a horn on. The stop half needs it
-- because "has a vehicle" is not a property key-up can rely on: exit the seat
-- while leaning on the horn and the key-up fires seatless. The old
-- early-return there left the loop running to the reaper locally and never
-- told the wire at all (the second half of the beta-crew bug).
local lastLocalId = nil

-- Disabled falls through to the captured originals, so the kill switch restores
-- vanilla - horn attracts zombies again - without a restart.
function ISVehicleMenu.onHornStart(playerObj)
    if not NoiseOrdinance.isEnabled() then return origStart(playerObj) end
    local vehicle = playerObj and playerObj:getVehicle()
    if not vehicle then return end
    -- Local first, so the horn answers the key rather than the round trip.
    startFor(vehicle:getId())
    lastLocalId = vehicle:getId()
    if isClient() then
        RDNet.send(OEShared.MODULE, "hornStart", {})
    end
end

function ISVehicleMenu.onHornStop(playerObj)
    if not NoiseOrdinance.isEnabled() then return origStop(playerObj) end
    local vehicle = playerObj and playerObj:getVehicle()
    local id = (vehicle and vehicle:getId()) or lastLocalId
    if id then stopFor(id) end
    lastLocalId = nil
    -- Always tell the wire, seated or not - the server resolves the vehicle
    -- from its own memory of the start, never from this packet.
    if isClient() then
        RDNet.send(OEShared.MODULE, "hornStop", {})
    end
end

-- ---------------------------------------------------------------------------
-- Other people's horns
-- ---------------------------------------------------------------------------

-- soundHornOn never becomes true anywhere now, so the engine's own state sync
-- carries nothing and remote horns have to be relayed. The upside of that same
-- fact is that nothing can contradict us: there is no server-side horn flag to
-- go stale and cut the blast short.
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= OEShared.MODULE then return end
    if not NoiseOrdinance.isEnabled() then return end
    local id = args and args.vehicle
    if not id then return end
    if command == "hornStart" then
        startFor(id)
    elseif command == "hornStop" then
        stopFor(id)
    end
end)

return NoiseOrdinance

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
