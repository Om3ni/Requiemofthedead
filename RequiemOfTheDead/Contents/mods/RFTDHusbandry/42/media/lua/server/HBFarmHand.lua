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

require "RDShared"   -- badNum is read at file scope below; declare it (CLAUDE.md sect. 4)
require "HBData"

HBFarmHand = HBFarmHand or {}

-- coordKey -> { x = , y = , z = }, backed by the "HBFarmHand" GlobalModData
-- table since 2026-08-25 (owner approved the new persisted key - it was held
-- back as a save-schema decision, and the restart gap it closed was the one
-- stated cost of the in-memory first version: a coop went unserviced after
-- every restart until something happened to see it again).
--
-- RQDormant's pattern, for RQDormant's reasons: GMD is already in RAM,
-- survives restarts by definition, and needs no sync plumbing. Same accepted
-- limit too - durability rides the engine's save cadence, so a force-kill
-- can lose the tail of registry changes; a coop lost that way merely waits
-- to be seen once, which is the OLD behaviour as the fallback instead of as
-- the design. This table must NEVER be transmitted or nested into anything
-- a client requests.
--
-- Rows are plain {x,y,z} numbers - exactly what the .bin can carry. A
-- malformed row (NaN/inf coordinate from a corrupt save) would poison the
-- pass's getGridSquare calls forever, so load-time sanitation drops them;
-- global_mod_data.bin is a full atomic rewrite per save, so a dropped row
-- vanishes from disk at the next autosave.
local SCHEMA_VERSION = 1
local store = nil
local registry = {}
local registryCount = 0

-- badNum lives in RDShared (promoted 2026-08-25).
local badNum = RDShared.badNum

local function sanitize(t)
    if t.schemaVersion ~= SCHEMA_VERSION or type(t.records) ~= "table" then
        t.schemaVersion = SCHEMA_VERSION
        t.records = {}
        return t
    end
    for k, pos in pairs(t.records) do
        if type(pos) ~= "table" or badNum(pos.x) or badNum(pos.y) or badNum(pos.z) then
            t.records[k] = nil
        end
    end
    return t
end

local function bindStore()
    store = sanitize(ModData.getOrCreate("HBFarmHand"))
    registry = store.records
    registryCount = 0
    for _ in pairs(registry) do registryCount = registryCount + 1 end
    HBFarmHand.stats.registered = registryCount
end

Events.OnInitGlobalModData.Add(function()
    -- Re-fetch on every init: after a restart the engine has loaded a fresh
    -- table from disk and any cached reference would be stale (RQDormant's
    -- same note).
    bindStore()
    print("[HB] farm hand: " .. registryCount .. " coop(s) restored from GlobalModData")
end)

-- Read-only counters. Hutch upkeep is the module whose failure is hardest to
-- see from outside - it either runs or silently does not, and the symptom
-- (slowly rising dirt) takes days to notice. These make a live answer possible
-- without a debugger.
HBFarmHand.stats = {
    registered   = 0, -- hutches currently in the registry
    lastServiced = 0, -- hutches resolved and serviced on the last pass
    lastSkipped  = 0, -- registered but unreachable last pass (normal)
    pruned       = 0, -- entries dropped, hutch confirmed gone (cumulative)
    passes       = 0,
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
    if registry[k] then return end
    registry[k] = { x = x, y = y, z = z }
    registryCount = registryCount + 1
    HBFarmHand.stats.registered = registryCount
end

-- How complete the registry is, in words, for the admin panel and for anyone
-- reading a bug report. The honest limitation of an in-memory registry is that
-- it starts empty after a restart: a coop is unserviced until something sees it
-- once. That is strictly better than the old behaviour (unserviced unless a
-- player happened to be within twenty squares at the moment of the pass) but it
-- is not "complete", and saying so here is cheaper than someone re-deriving it.
function HBFarmHand.coverage()
    return {
        registered = registryCount,
        note = "persisted in GlobalModData; a force-kill can lose changes "
            .. "since the last save, and a coop lost that way re-registers "
            .. "when next seen",
    }
end

-- ---------------------------------------------------------------------------
-- OBSERVABILITY
--
-- The counters above shipped with the first version of this file and NOTHING
-- READ THEM, which left the module exactly as invisible as the bug it replaced:
-- a pass that either services coops or silently does not, with a symptom that
-- takes days to surface. CLAUDE.md sect. 14 wants to know whether a feature ran,
-- what it decided and why - "entered function" is not enough - and an unread
-- field answers none of it. HBKeepAlive's `verbose` flag is the same trap one
-- step on: off by default, with no way to turn it on mid-run on a dedicated
-- server, so its instrumentation has never once been read either.
--
-- THE LINE IS BUILT AROUND ONE CLAIM. The old path could only reach a coop with
-- a player inside twenty squares of it. So `serviced` above zero while `online`
-- is zero is positive proof of the repair - the previous code could not have
-- produced it - and that is why the player count belongs on the line rather
-- than in another field nobody reads.
--
-- BOUNDED, because EveryTenMinutes is compressed GAME time: at the default day
-- length ten game-minutes is roughly twenty-five real seconds, so a line per
-- pass would be about 144 an hour. A line is emitted only when the registry
-- CHANGES - a coop learned or forgotten, which is rare and bounded by how many
-- coops exist - or as a heartbeat every REPORT_EVERY passes, so silence still
-- separates "running quietly" from "not running at all".
local REPORT_EVERY = 36   -- ~15 real minutes at the default day length

local lastReportedCount  = -1
local lastReportedPruned = -1
local passesSinceReport  = 0
local saidCoverage       = false

local function report(serviced, skipped)
    passesSinceReport = passesSinceReport + 1

    local churned = registryCount ~= lastReportedCount
                 or HBFarmHand.stats.pruned ~= lastReportedPruned
    if not churned and passesSinceReport < REPORT_EVERY then return end

    -- The honest limitation, once per server run and only where there is a line
    -- to attach it to: the registry starts empty and fills as hutches are seen,
    -- so a low count shortly after a restart is expected rather than a fault.
    -- This is also the only consumer coverage() has ever had.
    if not saidCoverage then
        saidCoverage = true
        print("[HB] farm hand: " .. HBFarmHand.coverage().note)
    end

    -- Plain nil-check, not a guard: getOnlinePlayers is an exposed method whose
    -- body cannot throw into Lua (MethodCaller.java:33-56), and it returns an
    -- empty list rather than null on every branch (LuaManager.java:3823-3832).
    -- nil here would mean the call shape failed, and zero is the honest answer.
    local online = getOnlinePlayers()
    print(string.format(
        "[HB] farm hand: %d known, %d serviced, %d out of reach, %d pruned, %d online (pass %d)",
        registryCount, serviced, skipped, HBFarmHand.stats.pruned,
        online and online:size() or 0, HBFarmHand.stats.passes))

    lastReportedCount  = registryCount
    lastReportedPruned = HBFarmHand.stats.pruned
    passesSinceReport  = 0
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
    local gone = nil

    for k, pos in pairs(registry) do
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
            gone = gone or {}
            gone[#gone + 1] = k
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

    if gone then
        for i = 1, #gone do
            registry[gone[i]] = nil
            registryCount = registryCount - 1
            HBFarmHand.stats.pruned = HBFarmHand.stats.pruned + 1
        end
        HBFarmHand.stats.registered = registryCount
    end

    HBFarmHand.stats.lastServiced = serviced
    HBFarmHand.stats.lastSkipped  = skipped
    HBFarmHand.stats.passes       = HBFarmHand.stats.passes + 1

    report(serviced, skipped)
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
