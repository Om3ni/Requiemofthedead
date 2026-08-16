-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDForage.lua - forensic record of server-side foraging traffic (server only).
--
-- New surface in 42.20. Foraging moved onto the typed-packet channel
-- (INetworkPacket / PacketTypes.ForageRequestZone, ForageSpot, ForagePool) and -
-- unusually for that channel - TWO of the three fire a Lua event on the SERVER:
--
--   ForageRequestZonePacket.processServer -> OnForageRequestZone(player, focus)
--   ForageSpotPacket.processServer        -> OnForageSpot(player, iconID)
--   ForagePoolPacket.processClient        -> OnForagePool(...)   <- client, ignored here
--
-- That makes these the only new server-side observability 42.20 handed us. Contrast
-- RDGuardian's header: factions moved to the same packet channel and got NO
-- server-side hook at all, so they are unobservable. Foraging is the exception,
-- which is precisely why it is worth wiring while it exists.
--
-- REGISTRATION IS MANDATORY, and this is the subtle part. Neither event is
-- registered by the engine: LuaEventManager only AddEvent()s "preAddForageDefs"
-- and "onAddForageDefs", and vanilla's forageClient.lua registers "OnForagePool"
-- CLIENT-side only. An unregistered event still fires - LuaEventManager.checkEvent
-- auto-creates it (:239-249) - BUT checkEvent returns null while the callback list
-- is empty, so the FIRST trigger is swallowed and only later ones arrive. Calling
-- AddEvent here first means we never lose that first record. AddEvent is idempotent
-- (returns the existing Event if present), so this is safe regardless of load order.
--
-- Why forensic and not chronicle: foraging is continuous sensor telemetry, not
-- a declared life/season fact. Chronicle's enum is a domain contract; forensic
-- accepts the observation stream and preserves it in immutable archive parts.
-- The two client-controlled strings are bounded below, and operators can disable
-- this producer by removing the sensor if its value no longer justifies volume.
--
-- SECURITY NOTE for whatever classifies this stream: both payload fields are
-- client-supplied Strings and processServer does NOT validate, gate on authority,
-- or rate-limit them - it only triggers the event. A client can therefore send
-- arbitrary and arbitrarily long `focus` / `iconID` values. They are capped below
-- before they reach the archive; treat them as untrusted input on read, too.

if not isServer() then return end

-- Explicit: "RDForage.lua" sorts before "RDLog.lua" and "RDShared.lua" on the
-- client's alphabetical cross-mod walk, so neither global exists at file scope
-- here. Declared, not assumed - the family rule since the 42.19 boot-log crashes.
-- Safe below the isServer() guard, which has already returned on the client.
require "RDShared"
require "RDLog"

RDForage = RDForage or {}

local STREAM   = "forage"
local MAX_STR  = 256   -- client-supplied; long enough for any real id, short enough to bound a record

local function capped(s)
    s = tostring(s or "")
    if #s > MAX_STR then return s:sub(1, MAX_STR) .. "~" end
    return s
end

-- Position is worth carrying for the same reason Guardian carries it: a forage
-- record without a location cannot be cross-referenced against anything.
local function recordAt(player)
    local x, y, z = -1, -1, -1
    if player then
        x = math.floor(player:getX()); y = math.floor(player:getY()); z = math.floor(player:getZ())
    end
    return x, y, z
end

local function log(evt, player, key, value)
    -- A sensor fault must never disturb the path it observes.
    pcall(function()
        -- player comes from PlayerID.getPlayer() and can be nil if the id does not
        -- resolve; RDLog handles a nil subject, so record the event either way
        -- rather than dropping it - an unattributable forage is still a data point.
        local x, y, z = recordAt(player)
        local payload = { x = x, y = y, z = z }
        payload[key] = capped(value)
        RDLog.forensic(STREAM, evt, player, payload, "RFTDCore")
    end)
end

if not RDForage._hooked then
    RDForage._hooked = true

    -- Register BEFORE listening - see the header. Wrapped because LuaEventManager
    -- is an exposed Java class and a signature change upstream must not take the
    -- whole file down with it.
    pcall(function()
        LuaEventManager.AddEvent("OnForageRequestZone")
        LuaEventManager.AddEvent("OnForageSpot")
    end)

    if Events.OnForageRequestZone then
        Events.OnForageRequestZone.Add(function(player, focus)
            log("RD.FORAGE_ZONE", player, "focus", focus)
        end)
    end

    if Events.OnForageSpot then
        Events.OnForageSpot.Add(function(player, iconID)
            log("RD.FORAGE_SPOT", player, "iconID", iconID)
        end)
    end
end

return RDForage

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
