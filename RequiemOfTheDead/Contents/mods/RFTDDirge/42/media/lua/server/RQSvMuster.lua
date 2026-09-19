-- SPDX-License-Identifier: GPL-3.0-or-later

-- RQSvMuster - a struck protector musters its escort.
--
-- When a player hits a Juggernaut or a Boss, the ordinary zombies inside its
-- aura are told to come for the attacker, so the fight is a pressure bubble
-- and not a stationary tank. The server decides WHO is told and WHEN; the
-- client that simulates each escort does the telling (RQMuster).
--
-- =============================================
-- WHY THE SERVER ONLY NOTIFIES
-- =============================================
-- Zombie AI runs on the zombie's owning client, and a perception call sticks
-- only on that machine: spottedNew returns before it sets any target on a
-- zombie this side does not simulate (IsoZombie.java:1671-1685). A spotted()
-- on the server's copy of a client-owned zombie would be the exact call the
-- soak taught us not to make - it changes a copy nobody reads. So this file
-- sends one targeted command per hit to the players within relevance, each
-- of whom commands the escorts THEY own. The server itself commands nothing.
--
-- =============================================
-- WHY ONCE A SECOND, PER SPECIAL
-- =============================================
-- Every hit on a special is a trigger (RQSvHit), and a fast weapon is many
-- hits a second. A forced spot paths the escort to the attacker's position
-- at that moment, and the engine drops the target again on the next memory
-- tick because the forced branch skips the flesh reset (IsoZombie.java:
-- 1898-1902, the drop at :2815-2817). Re-issuing on later hits is what
-- keeps an attacker at range covered, and once a second is as often as that
-- path needs refreshing: one packet per recipient per second is the whole
-- cost. Decided in the Bulwark lab (FINDINGS F32, 2026-09-16).
--
-- The stamp is keyed by onlineID, an integer, so the table pins no zombie
-- objects (Kahlua has no weak tables); a stamp a minute old is dropped on
-- the next muster, so the table holds only specials hit recently.
--
-- =============================================
-- WHO MUSTERS
-- =============================================
-- Juggernaut and Boss: the two that walk with an escort of ordinary zombies,
-- which is exactly the aura RQJuggernaut and RQBoss paint. An enraged
-- Scavenger's aura covers specials and not shamblers, and it is a hunter,
-- not a tank; it stays out. The radius on the wire is the same
-- JuggernautBuffRadius the escort paint uses, so what the player sees
-- painted is what turns on them.

if not isServer() then return end

require "RQCommon"
require "RQDirgeLog"
require "RQSvShared"

RQSvMuster = RQSvMuster or {}

-- Server -> client, targeted. The client half is RQCore's escortMuster
-- branch, which hands the special, the attacker's id and the radius to
-- RQMuster.muster.
RQSvMuster.COMMAND = "escortMuster"

local MUSTERS     = { Juggernaut = true, Boss = true }
local INTERVAL_MS = 1000
local PRUNE_MS    = 60000

RQSvMuster.stats = { mustered = 0, throttled = 0, recipients = 0, refused = {} }

local function refuse(reason)
    local r = RQSvMuster.stats.refused
    r[reason] = (r[reason] or 0) + 1
    return false
end

-- onlineID -> getTimestampMs of the last muster for that special.
local stamps = {}

-- Collect, then delete: the same shape RQMcCoy's sweep uses, never a delete
-- inside the pairs walk.
local function prune(now)
    local stale, n = {}, 0
    for oid, at in pairs(stamps) do
        if now - at > PRUNE_MS then
            n = n + 1
            stale[n] = oid
        end
    end
    for i = 1, n do stamps[stale[i]] = nil end
end

-- The fourth stage of RQSvHit.dispatch. Returns true when a muster went
-- out, false with a named reason or a throttle count otherwise.
function RQSvMuster.onAttacked(ctx)
    if not MUSTERS[ctx.zType] then return refuse("type") end
    local oid = ctx.zombie:getOnlineID()
    -- -1 is the only invalid onlineID (RDZombieId's rule); a special without
    -- one cannot be named to a client.
    if oid == nil or oid == -1 then return refuse("no-id") end

    prune(ctx.now)
    if not RQSvShared.due(stamps, oid, INTERVAL_MS, ctx.now) then
        RQSvMuster.stats.throttled = RQSvMuster.stats.throttled + 1
        return false
    end

    local cfg = RQSvShared.getSvConfig()
    local told = RQSvShared.sendNear(ctx.zombie, RQSvMuster.COMMAND, {
        onlineID   = oid,
        attackerID = ctx.attacker:getOnlineID(),   -- IsoPlayer.java:6050
        radius     = cfg.juggernautBuffRadius,
    })
    RQSvMuster.stats.mustered   = RQSvMuster.stats.mustered + 1
    RQSvMuster.stats.recipients = RQSvMuster.stats.recipients + told
    RQDirgeLog.write(ctx.zType, "[INFO] muster id=" .. tostring(oid)
        .. " attacker=" .. tostring(ctx.attacker:getOnlineID())
        .. " radius=" .. tostring(cfg.juggernautBuffRadius)
        .. " recipients=" .. told)
    return true
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
