-- SPDX-License-Identifier: GPL-3.0-or-later
-- QHServer.lua - Quiet Horn, server half: a relay and nothing else.
--
-- The whole module is explained in client/QuietHorn/QHClient.lua. The short
-- version: BaseVehicle.onHornStart() adds a 150/150 WorldSound in the same
-- breath as it sets the horn flag, so Quiet Horn never lets that method run and
-- plays the horn on each client instead.
--
-- Which leaves one gap this file exists to close. With onHornStart never
-- called, soundHornOn is false everywhere, so the engine's own vehicle-sound
-- sync carries no horn bit and nobody else hears you. This relays it.
--
-- THIS FILE DELIBERATELY NEVER TOUCHES THE VEHICLE. It reads the driver's
-- vehicle to get an id and forwards; it does not call onHornStart, onHornStop,
-- or anything else that could reach WorldSoundManager. The server is the one
-- machine where addSound would actually herd zombies (on a client the call is
-- guarded by !GameClient.client and never runs), so the rule here is simple:
-- the server never learns the horn is on.
--
-- It is also NOT a security boundary, and that is worth stating rather than
-- implying. Vanilla's own handler lives behind `local Commands = {}` in
-- server/Vehicles/VehicleCommands.lua and is dispatched through that upvalue at
-- :458, so it cannot be overridden or vetoed. If a client sends the vanilla
-- 'vehicle'/'onHorn' command, the server calls onHornStart and the herding
-- sound happens with nothing here able to prevent it. The client override is
-- what keeps that command from ever being sent, and it holds only because PZ
-- makes joining clients carry the server's mod list.

if not isServer() then return end

require "OEShared"

QuietHornSv = QuietHornSv or {}

-- The vehicle is taken from the player, never from the wire - the same shape
-- vanilla's own onHorn uses, and it means a forged id cannot make somebody
-- else's car sound. isDriver is checked on START for the same reason: a
-- passenger leaning on the horn is not a thing.
--
-- STOPS ARE NEVER GATED ON THE SEAT (beta-crew bug, 2026-08-08): the player
-- who exits mid-blast arrives here seatless, and the old shared guard dropped
-- their stop - every other client's loop ran to its deadline, or forever if
-- the vehicle also streamed out for them. The vehicle a stop refers to comes
-- from OUR memory of that player's start, so the forgery protection holds:
-- the wire still names no vehicle, and a player can only ever stop the horn
-- they started.
local lastHorn = {}   -- username -> vehicle id, remembered at start

local function keyFor(player)
    return (player and player:getUsername()) or tostring(player)
end

local function onStart(player, _args)
    if not OEShared.enabled("QuietHornEnable") then return end
    local vehicle = player and player:getVehicle()
    if not vehicle then return end
    if not vehicle:isDriver(player) then return end
    if not vehicle:hasHorn() then return end
    lastHorn[keyFor(player)] = vehicle:getId()
    RDNet.broadcast(OEShared.MODULE, "hornStart", { vehicle = vehicle:getId() })
end

local function onStop(player, _args)
    if not OEShared.enabled("QuietHornEnable") then return end
    local key = keyFor(player)
    local vehicle = player and player:getVehicle()
    local id = (vehicle and vehicle:isDriver(player) and vehicle:getId()) or lastHorn[key]
    lastHorn[key] = nil
    if not id then return end
    RDNet.broadcast(OEShared.MODULE, "hornStop", { vehicle = id })
end

-- Rate: one honk is a start and a stop, and the radial menu's ISHorn adds its
-- own stop when it force-completes at 1500ms. 6/sec leaves normal use alone
-- while capping what a held-down or scripted key can turn into - each accepted
-- command becomes one packet to EVERY connected client, so this is the one
-- amplifying command in the mod and the bucket matters more than usual.
-- Buckets are per command since RDNet scopes them by module.command.
--
-- No capability: honking is not staff-gated, and default-deny already means an
-- unregistered command never runs.
RDNet.register(OEShared.MODULE, "hornStart", { rate = 6 }, onStart)
RDNet.register(OEShared.MODULE, "hornStop",  { rate = 6 }, onStop)

return QuietHornSv

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
