-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCUsage - driver-entry attribution (client).
--
-- The Janitor (DESIGN §5) reclaims UNCLAIMED cars nobody has been seen using
-- within JanitorAbandonDays - the Presence Law: "if the player logs in, their
-- stuff is preserved." Its free attribution feed listens on the vanilla
-- 'vehicle' command channel (doors, horn, keys, engine-start-by-key, tow...).
-- But HOTWIRING and raw driving send NO such command, so a player who lost the
-- key (keys despawn with looted zombies, burn, etc.) and hotwired a car was
-- never attributed - and the Janitor reclaimed their daily driver out from
-- under them. Hotwiring is legitimate, sometimes the ONLY, use.
--
-- Fix: attribute the DRIVER the moment they enter an unclaimed car. The server
-- stamps RC_LastUser and the Presence Law then protects the car exactly like a
-- key-holder's for as long as that player keeps logging in. Claiming is
-- orthogonal - a claimed car is already Janitor-immune, so we skip it (and the
-- traffic); claim-then-hotwire or hotwire-then-claim both just work.
--
-- OnEnterVehicle is a LOCAL-player client event (ISEnterVehicle:perform ->
-- triggerEvent, fired after the seat is set), invisible to the server, so we
-- relay one lightweight command. The server re-validates everything.

if isServer() and not isClient() then return end

local function onEnterVehicle(character)
    if not character then return end
    -- getVehicle is a field return (IsoGameCharacter.java:10160); isDriver is
    -- a bounds-checked seat scan (BaseVehicle.java:1815)
    local v = character:getVehicle()
    if not v then return end
    -- Attribute the DRIVER only - the one who took / hotwired the car. A
    -- passenger riding along is not the keeper.
    if not v:isDriver(character) then return end
    if RCShared.isWreck(v) then return end
    if RCClaim.isClaimed(v) then return end   -- claimed = already Janitor-immune
    sendClientCommand(RCShared.MODULE, "used", { vehicleId = v:getId() })
end

Events.OnEnterVehicle.Add(onEnterVehicle)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
