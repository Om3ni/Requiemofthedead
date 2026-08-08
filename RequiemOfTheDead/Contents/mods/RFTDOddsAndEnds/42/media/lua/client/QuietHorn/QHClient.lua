-- SPDX-License-Identifier: GPL-3.0-or-later
-- QHClient.lua - Quiet Horn: the horn still sounds, but it stops being a tool
-- for herding the dead.
--
-- THE ASK: a horn you can hear and cannot fight with. Leaning on it to drag a
-- crowd off a street is the exploit; the noise itself is not.
--
-- WHY THIS IS A REPLACEMENT AND NOT A TWEAK. The engine fuses the two halves.
-- BaseVehicle.onHornStart() sets soundHornOn AND calls
--   WorldSoundManager.instance.addSound(this, x, y, z, 150, 150, ...)
-- in the same method. That addSound IS the herding - radius 150, volume 150 -
-- and there is no way to ask for one half:
--
--   * hornEnable, the flag both halves are gated on, is a PUBLIC FIELD on
--     VehicleScript.Sounds. It has no setter, the struct carries no
--     @UsedFromLua, and Kahlua never exposes instance fields. A mod cannot turn
--     the horn off, so "disable it and replace it" is not on the table.
--   * WorldSoundManager has no removal call. Once a sound is added it is added.
--   * getSounds().horn - the FMOD event name - is a public field too, so we
--     cannot read a vehicle's own horn name either. Hence the table below.
--
-- So the only lever is to never let onHornStart run. Everything the engine
-- would have done, this module does instead.
--
-- WHERE THE VETO HAS TO LIVE, and it is not where you would want it. Vanilla's
-- server handler is server/Vehicles/VehicleCommands.lua, and its dispatch table
-- is declared `local Commands = {}` - FILE-LOCAL, dispatched at :458 through
-- that upvalue. It cannot be reached, let alone overridden, so there is no
-- server-side veto available at all. (Same shape as the file-local Transactions
-- table that silently swallowed LMRestrict's moveables veto in Limes. Check for
-- `local` before planning a seam.)
--
-- That makes the client override below LOAD BEARING rather than a convenience:
-- if a client ever sends the vanilla 'vehicle'/'onHorn' command, the server
-- calls onHornStart and the sound is created with nothing able to stop it. It
-- holds because Odds & Ends is in the server's mod list and PZ requires joining
-- clients to carry the server's mods - but say it plainly, because a
-- server-side guarantee is what we would normally want and this is not one.
--
-- ONE SEAM COVERS BOTH INPUTS. The keybind (ISVehicleMenu.lua:1686-1690) and
-- the radial menu (which queues ISHorn, whose start/stop/perform all call these
-- same two functions) both funnel through onHornStart/onHornStop. Nothing else
-- calls them.
--
-- NOTHING IS SHIPPED AND NOTHING IS EXTRACTED. The horn events are already in
-- every client's FMOD banks; we play them by name. That keeps the vehicles
-- sounding like themselves, adds no asset to a GPL tree, and redistributes none
-- of The Indie Stone's audio.

if isServer() then return end

require "OEShared"
require "Vehicles/ISUI/ISVehicleMenu"

QuietHorn = QuietHorn or {}

-- Read at use time, not at load: SandboxVars is not up when this file is
-- walked. Same idiom as the other modules.
function QuietHorn.isEnabled()
    return OEShared.enabled("QuietHornEnable")
end

-- Vanilla ships exactly four horn events across every vehicle in 42.20, and a
-- vehicle's own choice is unreadable (see the header), so it is recovered from
-- the script name. Checked against media/scripts/generated/vehicles: 49 scripts
-- take Standard, the Van* family takes Van, SportsCar/SportsCar_ez take
-- SportsCar, OffRoad takes Jeep.
--
-- Prefix rather than an exact list on purpose: the van family alone is ~70
-- scripts (VanMail, VanSpiffo, Van_Leather ...) and TIS adds more each build.
-- An unknown or modded vehicle falls through to Standard, which is the same
-- answer vanilla gives 49 times out of 53 - a wrong-flavoured horn is a far
-- cheaper failure than a silent one.
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
    local name = ""
    pcall(function() name = tostring(vehicle:getScriptName() or "") end)
    for _, entry in ipairs(HORN_BY_PREFIX) do
        if name:sub(1, #entry.prefix) == entry.prefix then return entry.sound end
    end
    return DEFAULT_HORN
end

-- vehicleId -> { instance = <FMOD handle>, at = <ms> }
local playing = {}

local function stopFor(id)
    local rec = playing[id]
    if not rec then return end
    playing[id] = nil
    pcall(function()
        local vehicle = getVehicleById(id)
        if vehicle then vehicle:getEmitter():stopSound(rec.instance) end
    end)
end

local function startFor(id)
    -- Already sounding. Reached routinely, not defensively: the server echoes
    -- the broadcast back to the honking player, who started theirs locally the
    -- moment they pressed the key.
    if playing[id] then return end
    pcall(function()
        local vehicle = getVehicleById(id)
        if not vehicle then return end
        -- Respect the vehicle's own script. A trailer has no horn and must not
        -- grow one just because we are the ones playing it now.
        if not vehicle:hasHorn() then return end
        local instance = vehicle:getEmitter():playSoundLooped(hornSoundFor(vehicle))
        if instance and instance ~= 0 then
            playing[id] = { instance = instance, at = getTimestampMs() }
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

-- Disabled falls through to the captured originals, so the kill switch restores
-- vanilla - horn attracts zombies again - without a restart.
function ISVehicleMenu.onHornStart(playerObj)
    if not QuietHorn.isEnabled() then return origStart(playerObj) end
    local vehicle = playerObj and playerObj:getVehicle()
    if not vehicle then return end
    -- Local first, so the horn answers the key rather than the round trip.
    startFor(vehicle:getId())
    if isClient() then
        RDNet.send(OEShared.MODULE, "hornStart", {})
    end
end

function ISVehicleMenu.onHornStop(playerObj)
    if not QuietHorn.isEnabled() then return origStop(playerObj) end
    local vehicle = playerObj and playerObj:getVehicle()
    if not vehicle then return end
    stopFor(vehicle:getId())
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
