-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQZombieCache.lua - onlineID -> IsoZombie, for this machine.
--
-- SHARED TIER SINCE 2026-08-25: both sides needed the same map and the file
-- never touched a client-only surface. The client half is the original story
-- (below). The server half exists because svFindZombieByOnlineID was the same
-- mistake at admin-command cadence - a 31x31 box sweep from whatever
-- coordinates arrived, so a zombie that wandered past the box was a MISS and
-- an id was only as good as the position sent with it. The engine keeps
-- exactly this map server-side (ServerMap.instance.zombieMap,
-- ZombieID.java:32) but it is an instance field on an unexposed class, so
-- Lua cannot reach it and we maintain our own. Every event and global this
-- file uses fires on both sides; getCell() on the server is the one
-- world-wide cell, so the fallback pass covers every loaded zombie.
--
-- WHAT THIS REPLACES, and why it was worth replacing.
--
-- RQCore.findZombieByID USED TO resolve a zombie by walking a 31x31 block of
-- grid squares - 961 getGridSquare calls, each then iterating that square's
-- moving objects - centred on a CACHED position. RQHighlight calls it once per
-- special per render tick. At 60fps with three specials that was roughly
-- 173,000 grid-square lookups a second.
--
-- And it did not even work. The cached position only refreshed on
-- RQReconcile's periodic baseline pull, so a moving special outran its own
-- cache and fell outside the +/-15 window. RQReflect logged 718 of those
-- (DRIFT) in one archive - Glutton 271, Scavenger 149, Screamer 102,
-- Juggernaut 95, EMP 89. Every one is a special that silently lost its
-- outline. We were paying six figures a second to fail.
--
-- A map from onlineID to the object has no search window, so there is nothing
-- to drift out of, and the lookup is a table index.
--
-- =============================================
-- WHY THIS IS NOT JUST A TABLE
-- =============================================
-- Because Kahlua has no weak tables (RDLedger's header carries the decompile
-- evidence), a plain table here would pin every zombie this client has ever
-- seen for the life of the session. RDLedger owns that problem: the row states
-- its liveness rule once and the sweep enforces it on a budget.
--
-- The rule below is deliberately three-part. "Not dead" is not sufficient:
-- onlineIDs are recycled, so a row whose zombie no longer answers to the key
-- it is filed under would hand a caller the WRONG BODY. That is worse than a
-- miss, and it is the failure a naive cache invites.
--
-- =============================================
-- -1 IS THE ONLY INVALID ID. NEGATIVE IS NOT.
-- =============================================
-- IsoZombie.onlineId is a `short` (IsoZombie.java:325) handed out by
-- ServerMap.getUniqueZombieId (:2781). It wraps past 32767 into negative
-- numbers, and the engine's own tests everywhere are `onlineId == -1`
-- (IsoZombie.java:2780, FakeClientManager.java:1397, VoiceManager.java:781) -
-- never `< 0`. Confirmed live: this client's own reflect archive is full of
-- ids like -10307 and -10653 belonging to perfectly ordinary zombies.
--
-- So `id >= 0` as a validity test throws away roughly half the zombie
-- population on any server that has been up long enough to wrap. Do not
-- "tidy" the test below into a positivity check.
-- =============================================

require "RQCommon"
require "RDLedger"

RQZombieCache = RQZombieCache or {}

-- The engine's sentinel for "no id yet", and the ONLY invalid value.
local NO_ID = -1

-- OnZombieCreate fires BEFORE the zombie is networked or even added to the
-- cell list (VirtualZombieManager.java:325 triggers the event; :327 is the
-- list insert), so a newborn frequently has no id yet. Client-side the id
-- arrives with the packet (NetworkZombieSimulator.java:187). We therefore
-- re-check for a short while, then give up - a zombie that never gets an id
-- is not ours to track, and an unbounded retry list is just the leak again.
local PENDING_TRIES     = 8
local PENDING_RETRY_MS  = 120

-- A full cell-list pass is cheap next to the grid walk it replaces, but it is
-- not free, and a genuinely absent zombie would otherwise trigger one on every
-- caller every frame. One pass per this many ms, shared by all callers.
local RESOLVE_INTERVAL_MS = 250

-- Three-part liveness. See the header: matching the key back is what stops a
-- recycled id handing out the wrong body.
local cache = RDLedger.new({
    name = "RQZombieCache",
    live = function(onlineID, zombie)
        if not zombie then return false end
        if zombie:isDead() then return false end
        return zombie:getOnlineID() == onlineID
    end,
})
RQZombieCache.ledger = cache

local pending = {}
local lastResolveAt = 0

RQZombieCache.stats = {
    warmed   = 0,   -- rows added by a resolve pass
    resolves = 0,   -- full cell-list passes actually run
    deferred = 0,   -- newborns parked for a later id
    dropped  = 0,   -- newborns that never got one
}

local function remember(zombie)
    if not zombie then return false end
    local onlineID = zombie:getOnlineID()
    if onlineID == nil or onlineID == NO_ID then return false end
    cache.set(onlineID, zombie)
    return true
end
RQZombieCache.remember = remember

-- One pass over the cell's zombie list, filing EVERY zombie it walks past.
-- Warming the whole list costs nothing extra once we are iterating it, and it
-- means the second lookup this frame is already a hit.
--
-- getZombieList returns a java.util.ArrayList, which exposes size/get to Lua.
-- (Sets do not - CLAUDE.md section 3 - but lists are fine, and this is the
-- same access shape RQCore already uses on getMovingObjects.)
local function resolveAll(now)
    local cell = getCell()
    if not cell then return end
    local list = cell:getZombieList()
    if not list then return end
    lastResolveAt = now
    RQZombieCache.stats.resolves = RQZombieCache.stats.resolves + 1
    for i = 0, list:size() - 1 do
        local zombie = list:get(i)
        if zombie and not zombie:isDead() then
            local onlineID = zombie:getOnlineID()
            if onlineID ~= nil and onlineID ~= NO_ID and not cache.has(onlineID) then
                cache.set(onlineID, zombie)
                RQZombieCache.stats.warmed = RQZombieCache.stats.warmed + 1
            end
        end
    end
end

-- The lookup. Cache first; on a miss, at most one rate-limited cell-list pass.
--
-- A miss is not necessarily an error - a special outside this client's loaded
-- chunks legitimately has no object here. RQReflect independently checks the
-- complete cell list before classifying that as ABSENT-FROM-CELL; callers here
-- simply treat nil as "not here right now".
function RQZombieCache.get(onlineID)
    if onlineID == nil or onlineID == NO_ID then return nil end
    local zombie = cache.get(onlineID)
    if zombie then return zombie end

    local now = getTimestampMs()
    if now - lastResolveAt < RESOLVE_INTERVAL_MS then return nil end
    resolveAll(now)
    return cache.get(onlineID)
end

function RQZombieCache.forget(onlineID)
    if onlineID == nil then return false end
    return cache.remove(onlineID)
end

function RQZombieCache.count()
    return cache.count()
end

-- Newborns whose id has not arrived yet. Bounded on both axes: a fixed retry
-- count and a fixed interval, so this list always drains.
local function drainPending(now)
    for i = #pending, 1, -1 do
        local row = pending[i]
        local zombie = row.zombie
        local settled = false
        if not zombie or zombie:isDead() then
            settled = true
        elseif now >= row.nextAt then
            if remember(zombie) then
                settled = true
            else
                row.tries = row.tries - 1
                row.nextAt = now + PENDING_RETRY_MS
                if row.tries <= 0 then
                    settled = true
                    RQZombieCache.stats.dropped = RQZombieCache.stats.dropped + 1
                end
            end
        end
        if settled then
            pending[i] = pending[#pending]
            pending[#pending] = nil
        end
    end
end

Events.OnZombieCreate.Add(function(zombie)
    if not zombie then return end
    if remember(zombie) then return end
    pending[#pending + 1] = { zombie = zombie, tries = PENDING_TRIES, nextAt = 0 }
    RQZombieCache.stats.deferred = RQZombieCache.stats.deferred + 1
end)

-- The death hook is the cheap, immediate path. It is NOT sufficient on its own
-- and never was: a zombie unloaded with its chunk dies no death, which is
-- precisely the gap RDLedger's sweep exists to close.
Events.OnZombieDead.Add(function(zombie)
    if not zombie then return end
    local onlineID = zombie:getOnlineID()
    if onlineID ~= nil and onlineID ~= NO_ID then cache.remove(onlineID) end
end)

Events.OnTick.Add(function()
    if #pending == 0 then return end
    drainPending(getTimestampMs())
end)

function RQZombieCache.reset()
    cache.clear()
    pending = {}
    lastResolveAt = 0
    RQZombieCache.stats.warmed   = 0
    RQZombieCache.stats.resolves = 0
    RQZombieCache.stats.deferred = 0
    RQZombieCache.stats.dropped  = 0
end

Events.OnGameStart.Add(RQZombieCache.reset)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
