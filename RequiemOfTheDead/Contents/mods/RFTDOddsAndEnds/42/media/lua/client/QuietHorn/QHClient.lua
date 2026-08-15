-- SPDX-License-Identifier: GPL-3.0-or-later
if isServer() then return end

require "OEShared"
require "Vehicles/ISUI/ISVehicleMenu"

QuietHorn = QuietHorn or {}

-- Read at use time, not at load: SandboxVars is not up when this file is
-- walked. Same idiom as the other modules.
function QuietHorn.isEnabled()
    return OEShared.enabled("QuietHornEnable")
end


local HORN_BY_PREFIX = {
    { prefix = "SportsCar", sound = "VehicleHornSportsCar" },
    { prefix = "OffRoad",   sound = "VehicleHornJeep" },
    { prefix = "Van",       sound = "VehicleHornVan" },
}
local DEFAULT_HORN = "VehicleHornStandard"

-- A horn nobody stopped. The stop is an event, and events go missing: the
-- driver disconnects mid-blast, the vehicle unloads, a packet is dropped. A
-- looped FMOD instance with no owner plays until the client restarts, so every
-- start gets a deadline. Vanilla's own ISHorn force-completes at 1500ms and a
-- held key is bounded by the player's patience, so this only ever fires on a
-- genuine orphan.
local MAX_MS = 10000

local function hornSoundFor(vehicle)
    -- getScriptName (BaseVehicle:1593) answers with a field even when the
    -- script itself is null; the caller has already nil-checked the vehicle.
    local name = tostring(vehicle:getScriptName() or "")
    for _, entry in ipairs(HORN_BY_PREFIX) do
        if name:sub(1, #entry.prefix) == entry.prefix then return entry.sound end
    end
    return DEFAULT_HORN
end

-- vehicleId -> { instance, emitter, sound, at }
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
    playing[id] = nil
    -- guarded: the emitter may be the abandoned handle of a streamed-out
    -- vehicle (see the table note above), and FMODSoundEmitter.stopSound:98
    -- derefs each instance's clip on the way through - FMOD internals on a
    -- stale emitter are exactly what this must survive.
    pcall(rec.emitter.stopSound, rec.emitter, rec.instance)
    -- Belt over braces: if the instance stop missed (engine restarted the
    -- sound under the same emitter), kill it by name. Guarded by isPlaying
    -- so a normal stop never touches an unrelated same-name loop - and by
    -- pcall for the same stale-emitter reason as above.
    pcall(function()
        if rec.emitter:isPlaying(rec.sound) then rec.emitter:stopSoundByName(rec.sound) end
    end)
end

local function startFor(id)
    -- Already sounding. Reached routinely, not defensively: the server echoes
    -- the broadcast back to the honking player, who started theirs locally the
    -- moment they pressed the key.
    if playing[id] then return end
    -- guarded: hasHorn NPEs on a scriptless vehicle (VehicleSoundOwner.java:73
    -- derefs getScript() unguarded), and playSoundLooped is FMOD internals - a
    -- horn that fails to start must cost one blast, not the handler.
    pcall(function()
        local vehicle = getVehicleById(id)
        if not vehicle then return end
        -- Respect the vehicle's own script. A trailer has no horn and must not
        -- grow one just because we are the ones playing it now.
        if not vehicle:hasHorn() then return end
        local emitter = vehicle:getEmitter()
        local sound = hornSoundFor(vehicle)
        local instance = emitter:playSoundLooped(sound)
        if instance and instance ~= 0 then
            playing[id] = { instance = instance, emitter = emitter, sound = sound, at = getTimestampMs() }
        end
    end)
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
        if now - rec.at > MAX_MS then
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
    if not QuietHorn.isEnabled() then return origStart(playerObj) end
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
    if not QuietHorn.isEnabled() then return origStop(playerObj) end
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
    if not QuietHorn.isEnabled() then return end
    local id = args and args.vehicle
    if not id then return end
    if command == "hornStart" then
        startFor(id)
    elseif command == "hornStop" then
        stopFor(id)
    end
end)

return QuietHorn

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
