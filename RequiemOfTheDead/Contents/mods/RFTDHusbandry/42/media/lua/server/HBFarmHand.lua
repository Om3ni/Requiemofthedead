-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBFarmHand - hutch upkeep, on the hutches rather than on the players.
--
-- THE BUG THIS EXISTS TO FIX (diagnosed 2026-08-20 from a live report: a coop
-- showing Bedding 88% and Dirtiness 25% at the same time, which the bedding
-- design says is impossible). Hutch upkeep used to ride HBKeepAlive's scan,
-- which walks +/-20 squares around each connected PLAYER. But vanilla dirties a
-- hutch on a completely different condition:
--
--   IsoHutch.update() runs when the hutch isExistInTheWorld() and isOwner()
--   (IsoHutch.java:258-266) - i.e. whenever it is LOADED. Player proximity
--   is not part of it. HutchManager.updateAll (HutchManager.java:44-49) is
--   what drives it.
--
-- So the two conditions never matched. Someone drives past a base forty tiles
-- away, the chunk loads, vanilla ticks the coop and dirt accrues - and the
-- owner is offline, so no player is within twenty squares and no cleaning pass
-- ever reaches it. Bedding sits full while dirt climbs. Every drive-by makes it
-- worse, and doMeta (IsoHutch.java:404-417) adds a further point per unloaded
-- hour on top when the chunk finally reloads.
--
-- Widening the radius was the wrong repair. +/-20 is already 1,681 squares per
-- player per pass; matching the loaded box (+/-20 to +/-76 tiles depending on
-- the client's chunk setting, IsoChunkMap.java:107-140) would be over twenty
-- thousand squares per player, every ten minutes, to service a handful of
-- coops. The real defect was that hutch work was riding a scan built for
-- TRAILERS. Trailers move, so they genuinely need a player-relative search.
-- Hutches do not move and never needed spatial search at all.
--
-- WHY A REGISTRY AND NOT THE ENGINE'S OWN LIST. HutchManager holds exactly the
-- set we want - every live hutch, the same list it calls update() on - but
-- `hutchList` is private and the class exposes no getter (:11, and the whole
-- surface is add/remove/clear/updateAll/checkHutchExistInList). There is
-- nothing to read from Lua, so we keep our own.
--
-- LoadGridsquare was the other candidate and was rejected: it fires per SQUARE
-- for every square of every loading chunk (IsoChunk.java:3492), which is 64
-- squares per chunk on a server streaming constantly for every player. The
-- engine ships a class literally named LoadGridsquarePerformanceWorkaround for
-- traffic on that path; adding an object walk to it is not something to do
-- without a way to measure the cost.

if not isServer() then return end

require "HBData"

HBFarmHand = HBFarmHand or {}

-- coordKey -> { x = , y = , z = }. In memory only, and deliberately NOT
-- GlobalModData: a new persisted key is a save-schema change, which
-- CLAUDE.md sect. 13 makes a compatibility decision rather than an
-- implementation one. The cost of that choice is stated honestly in
-- HBFarmHand.coverage below.
local known = {}
local knownCount = 0

-- Read-only counters. Hutch upkeep is the module whose failure is hardest to
-- see from outside - it either runs or silently does not, and the symptom
-- (slowly rising dirt) takes days to notice. These make a live answer possible
-- without a debugger.
HBFarmHand.stats = {
    registered = 0,   -- hutches currently known
    lastSeen   = 0,   -- resolved and serviced on the last pass
    lastSkipped= 0,   -- known but unloaded on the last pass (normal)
    pruned     = 0,   -- entries dropped because the hutch is gone (cumulative)
    passes     = 0,
}

local function keyOf(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- Record a hutch we have encountered. Cheap and idempotent, so every code path
-- that happens to touch a hutch can call it without thinking about cost - which
-- is exactly how the registry fills.
--
-- getSquare is a plain field read; a hutch that is mid-teardown can return nil
-- and is simply not registered, because an unplaced hutch has no coordinates to
-- come back to.
function HBFarmHand.remember(hutch)
    if not hutch then return end
    -- Normalise to the MASTER at the door. A multi-tile coop puts linked slave
    -- IsoHutches on its other squares, and dirt, animals and bedding all live
    -- on the master alone. IsoHutch.getHutch returns `this` for a master and
    -- follows linkedX/Y/Z for a slave (IsoHutch.java:127-142), so registering
    -- the master's coordinates means the pass resolves one entry per coop
    -- instead of one per tile.
    --
    -- It answers nil when the master's square is cold, which for a slave we
    -- have just walked past is unlikely but not impossible - fall back to the
    -- object we were handed rather than dropping the coop entirely. The pass
    -- re-resolves through the master anyway.
    hutch = hutch:getHutch() or hutch
    local sq = hutch:getSquare()
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local k = keyOf(x, y, z)
    if known[k] then return end
    known[k] = { x = x, y = y, z = z }
    knownCount = knownCount + 1
    HBFarmHand.stats.registered = knownCount
end

-- How complete the registry is, in words, for the admin panel and for anyone
-- reading a bug report. The honest limitation of an in-memory registry is that
-- it starts empty after a restart: a coop is unserviced until something sees it
-- once. That is strictly better than the old behaviour (unserviced unless a
-- player happened to be within twenty squares at the moment of the pass) but it
-- is not "complete", and saying so here is cheaper than someone re-deriving it.
function HBFarmHand.coverage()
    return {
        registered = knownCount,
        note = "in-memory; refills as hutches are seen after a restart",
    }
end

-- One upkeep round over every hutch we know about.
--
-- Resolution is per-coordinate rather than by held reference on purpose: a
-- reference kept across a chunk unload is a stale object whose writes go
-- nowhere, and hutches outlive the sessions that saw them. getGridSquare
-- returns nil for a cold coordinate (IsoCell.java:2800-2818), which is the
-- normal "not loaded right now" answer and costs one lookup.
--
-- getHutch walks the square's specialObjects and casts (IsoGridSquare.java:
-- 9846-9854) - no script-def read, so it cannot hit the engine-internal NPE
-- that getMaxAnimals() does (see HBKeepAlive's note on that).
function HBFarmHand.pass()
    local cell = getCell()
    if not cell then return 0, 0 end

    local seen, serviced, skipped = {}, 0, 0
    local dead = nil

    for k, pos in pairs(known) do
        local sq = cell:getGridSquare(pos.x, pos.y, pos.z)
        if not sq then
            -- Cold coordinate. Keep the entry: the coop still exists, it is
            -- simply out of anyone's loaded area this minute.
            skipped = skipped + 1
        elseif not sq:getHutch() then
            -- The square is LOADED and holds no IsoHutch object at all, so this
            -- coop was picked up or destroyed. Prune only on that positive
            -- evidence: never on a nil square, which would drop every coop on
            -- the map the moment nobody was near them.
            --
            -- IsoGridSquare.getHutch is the raw specialObjects walk
            -- (IsoGridSquare.java:9846-9854) - deliberately NOT the master
            -- resolution below, because "is there a hutch on this tile" and
            -- "can I reach its master right now" are different questions and
            -- only the first one justifies forgetting the coop.
            dead = dead or {}
            dead[#dead + 1] = k
        else
            -- Master resolution, through the one resolver the command path
            -- already uses - it handles the slave hop and the cold-master case.
            -- A nil here means the master's square is not loaded yet, which is
            -- a skip and not evidence of anything.
            local hutch = HBBedding and HBBedding.resolveHutchAt(pos.x, pos.y, pos.z)
            if hutch then
                HBFarmHand.upkeep(hutch, seen)
                serviced = serviced + 1
            else
                skipped = skipped + 1
            end
        end
    end

    if dead then
        for i = 1, #dead do
            known[dead[i]] = nil
            knownCount = knownCount - 1
            HBFarmHand.stats.pruned = HBFarmHand.stats.pruned + 1
        end
        HBFarmHand.stats.registered = knownCount
    end

    HBFarmHand.stats.lastSeen    = serviced
    HBFarmHand.stats.lastSkipped = skipped
    HBFarmHand.stats.passes      = HBFarmHand.stats.passes + 1
    return serviced, skipped
end

-- The two independent jobs a live hutch wants, in one place so the pass does
-- not need to know what upkeep means. `seen` dedups animals across a pass the
-- same way HBKeepAlive's own tracking does, so a hutch reached twice in one
-- round does not double-refill.
--
-- Bedding first: it is the cheaper of the two and the one whose absence the
-- player can actually see.
function HBFarmHand.upkeep(hutch, seen)
    if HBBedding then HBBedding.applyBedding(hutch) end
    if HBKeepAlive and HBKeepAlive.refillHutch then
        HBKeepAlive.refillHutch(hutch, seen or {})
    end
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
