-- SPDX-License-Identifier: GPL-3.0-or-later
-- NOServer.lua - Noise Ordinance horn relay and lease owner.
--
-- The horn replacement is explained in client/NoiseOrdinance/NOClient.lua. The short
-- version: BaseVehicle.onHornStart() adds a 150/150 WorldSound in the same
-- breath as it sets the horn flag, so Noise Ordinance never lets that method run and
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

NoiseOrdinanceSv = NoiseOrdinanceSv or {}

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
local LEASE_MS = 10000
local active = {}   -- username -> { vehicle, expiresAt }

local function keyFor(player)
    return (player and player:getUsername()) or tostring(player)
end

local function onStart(player, _args)
    if not OEShared.enabled("NoiseOrdinanceEnable") then return end
    local vehicle = player and player:getVehicle()
    if not vehicle then return end
    if not vehicle:isDriver(player) then return end
    if not vehicle:hasHorn() then return end
    local key = keyFor(player)
    local id = vehicle:getId()
    local prior = active[key]
    if prior and prior.vehicle ~= id then
        RDNet.broadcast(OEShared.MODULE, "hornStop", { vehicle = prior.vehicle })
    end
    -- getTimestampMs is System.currentTimeMillis (LuaManager.java:7469-7472).
    -- A repeated start refreshes the same lease instead of stacking state.
    active[key] = { vehicle = id, expiresAt = getTimestampMs() + LEASE_MS }
    RDNet.broadcast(OEShared.MODULE, "hornStart", { vehicle = id })
end

local function onStop(player, _args)
    local key = keyFor(player)
    local rec = active[key]
    active[key] = nil
    if not rec then return end
    RDNet.broadcast(OEShared.MODULE, "hornStop", { vehicle = rec.vehicle })
end

-- There is no server-side player-disconnect Lua event in 42.20.2. The lease
-- makes disconnect cleanup independent of that missing surface and also bounds
-- a dropped hornStop packet. OnTick is registered by LuaEventManager.java:636.
local function reap()
    local now = getTimestampMs()
    local stale
    for key, rec in pairs(active) do
        if now >= rec.expiresAt then
            stale = stale or {}
            stale[#stale + 1] = key
        end
    end
    if not stale then return end
    for _, key in ipairs(stale) do
        local rec = active[key]
        if rec and now >= rec.expiresAt then
            active[key] = nil
            RDNet.broadcast(OEShared.MODULE, "hornStop", { vehicle = rec.vehicle })
        end
    end
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
-- public on purpose: sounding a vehicle horn is an ordinary player action. The
-- rate limit is the whole control here, and the live capture shows it working -
-- 15 refusals on these two commands over 3.28 days.
RDNet.register(OEShared.MODULE, "hornStart", { public = true, rate = 6 }, onStart)
RDNet.register(OEShared.MODULE, "hornStop",  { public = true, rate = 6 }, onStop)
Events.OnTick.Add(reap)

return NoiseOrdinanceSv

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
