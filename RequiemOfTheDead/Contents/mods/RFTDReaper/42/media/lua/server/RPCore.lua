-- SPDX-License-Identifier: GPL-3.0-or-later
-- RPCore - vanilla twin-spawn detector and culler.
--
-- Root cause: PZPopMan64.dll's virtual zombie pool appends entries without a
-- duplicate-position check. When n_addZombie() is called multiple times for
-- the same (x,y) the pool accumulates N entries. On the next n_updateMain()
-- all N entries emit as spawn events; Java creates N zombies in a single tick
-- with:
--   * sequential OnlineIDs (gap of 1)
--   * shared persistentOutfitID (same clothing/hair template)
--   * same starting tile
-- Skin/hair colors are randomized per zombie post-spawn, so twins look
-- different visually despite being template-clones.
--
-- IMPORTANT: do NOT virtualizeZombie() culled duplicates - that re-feeds the
-- DLL pool and reseeds the bug. We use removeFromWorld/removeFromSquare only.
--
-- Detection is event-driven: OnZombieCreate fires inside createRealZombieAlways
-- for every materialization (popman chunk-load spawns, hordes, Lua creates), so
-- a bloom's twins arrive the frame they exist. The full sweep remains as a slow
-- safety net. Engine notes: engine-popman-observability-42.20.md at repo root.

if not isServer() then return end

RPCore = {}

-- -------------------------------------------------------------------------
-- Config (re-read each sweep; lets sandbox edits land without restart)
-- -------------------------------------------------------------------------

-- Runtime overrides for live threshold tuning from the Dragonfly Necro
-- tab. Sandbox is read first, then any override in RPCore.runtime wins.
-- Persisted only in memory; clears on server restart.
RPCore.runtime = RPCore.runtime or {}

local function cfg()
    local s = SandboxVars.RFTDReaper or {}
    local r = RPCore.runtime
    return {
        enabled             = s.Enabled ~= false,
        cullEnabled         = s.CullEnabled ~= false,
        -- Default OFF. The line is cheap to read and expensive to write: print()
        -- is synchronous main-thread I/O, and a bloom drain emits one line per
        -- cull. Opt in while tuning, not in production.
        logCulls            = s.LogCulls == true,
        sequentialThreshold = r.sequentialThreshold or s.SequentialThreshold or 2,
        stackThreshold      = r.stackThreshold      or s.StackThreshold      or 5,
        -- REAL minutes for one full rotation of the three bloom scans. The
        -- scans are staggered one per interval/3 slot, so this is the age of
        -- the oldest evidence, not the frequency of a triple-scan burst.
        bloomInterval       = s.BloomInterval or 5,
        maxPerScan          = s.MaxRemovalsPerScan or 500,
        cullsPerTick        = s.CullsPerTick or 15,
        outfitIdGap         = r.outfitIdGap     or s.OutfitIdGap     or 15,
        outfitMinCluster    = r.outfitMinCluster or s.OutfitMinCluster or 3,
        outfitProximity     = r.outfitProximity  or s.OutfitProximity  or 75,
        -- Full-sweep cadence in REAL minutes. OnZombieCreate carries newborn
        -- detection now; the sweep is a safety net, not the detector.
        sweepInterval       = r.sweepInterval or s.SweepInterval or 2,
        -- Zombies inspected per tick while a scan is in flight. This is the
        -- knob that decides whether a scan is a stutter or a background hum:
        -- the walk costs 2-4 engine calls per zombie, so it is bounded by count
        -- rather than run to completion in one tick.
        scanBudget          = r.scanBudget or s.ScanBudget or 200,
    }
end

-- -------------------------------------------------------------------------
-- Fingerprint - outfit + sorted inventory type-counts
-- -------------------------------------------------------------------------

local function safeOutfit(z)
    -- Try persistent outfit ID first - integer, survives saves, twins share it.
    local id = z:getPersistentOutfitID()
    if id and id ~= 0 then return "o" .. tostring(id) end
    -- getOutfitName guard stays: the 42.20.2 body routes through
    -- ModelManager.dressInRandomOutfit on a per-zombie flag, so failure is
    -- per-zombie state, not per-build - a cached verdict would be a gamble.
    local ok2, name = pcall(z.getOutfitName, z)
    if ok2 and name and name ~= "" then return tostring(name) end
    return "?outfit?"
end

local function inventorySig(z)
    local inv = z:getInventory()
    if not inv then return "" end
    local items = inv:getItems()
    if not items then return "" end
    local counts = {}
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it then
            local t = it:getFullType() or "?"
            counts[t] = (counts[t] or 0) + 1
        end
    end
    local parts = {}
    for t, c in pairs(counts) do parts[#parts + 1] = t .. "x" .. c end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function tileKey(z)
    local sq = z:getSquare()
    if not sq then return nil end
    local x, y, zc = sq:getX(), sq:getY(), sq:getZ()
    return x .. "," .. y .. "," .. zc, x, y, zc
end

-- Two-stage fingerprint: tile+outfit is the cheap key; the inventory walk in
-- inventorySig only runs when a cheap key collides, to confirm the template
-- match. Twins share empty-ish inventories at birth, so the cheap key does
-- the discriminating and the signature does the confirming.

-- -------------------------------------------------------------------------
-- Removal - three engine paths, only the ones that can actually throw guarded
-- -------------------------------------------------------------------------

local function cullZombie(z)
    z:removeFromSquare() -- null-checks every field it touches
    -- removeFromWorld DOES throw: IsoZombie's override reaches
    -- IsoMovingObject.removeFromWorld, which calls getCell().isSafeToAdd()
    -- with no null check, and getCell() is null until a world exists.
    pcall(z.removeFromWorld, z)
    -- Same getCell() hazard, plus getZombieList/remove are probed because the
    -- cell's list API has moved between builds.
    pcall(function()
        local cell = z:getCell()
        if cell and cell.getZombieList then
            local list = cell:getZombieList()
            if list and list.remove then list:remove(z) end
        end
    end)
end

-- -------------------------------------------------------------------------
-- Newborn watcher state
-- -------------------------------------------------------------------------

local knownIds     = {}   -- [OnlineID] = birthTileKey; recorded at first-seen time
local bootstrapped = false
local stats        = { culled = 0, ticks = 0, births = 0 }

local tickTotal    = 0    -- monotone; never resets (ages recentBirths)

-- The FIRST sweep stays early - it is the bootstrap that registers the
-- world's existing zombies. After bootstrap the cadence relaxes to
-- cfg().sweepInterval, because OnZombieCreate now catches twins at birth.
local BOOTSTRAP_MS = 7000

-- Wall clock, not game time and not ticks.
--
-- The scan cadence used to hang off EveryOneMinute, which GameTime fires from
-- minutesStamp - in-game minutes (GameTime.setMinutesStamp: worldAgeHours*60 +
-- getMinutes()). DayLength therefore scaled it: at DayLength=5 (2 real hours
-- per day) an in-game minute is 5 real seconds, so a "5 minute" bloom interval
-- was really 25 seconds. Shortening the day silently multiplied the scan load.
--
-- Tick counting is no better: OnTick fires once per fixed-step iteration
-- (IngameState:1647) at a rate that sags under exactly the load these scans
-- create, so a tick budget stretches when the server is already struggling.
-- System.currentTimeMillis is the only clock that means what it says.
local function clockMs()
    if getTimestampMs then return getTimestampMs() end
    return tickTotal * 33   -- degraded fallback: assume ~30Hz
end

local function isValidId(id)
    return id and id ~= 0 and id ~= -1
end

-- -------------------------------------------------------------------------
-- Cull queue - detection and removal are decoupled. Scans enqueue their
-- verdicts; drainCullQueue removes a bounded number per tick. Every
-- removal makes the engine broadcast a despawn packet to each connected
-- client, so executing a 1500-cull scan pass inline is a ~30k-packet
-- burst on a 20-player server (resend-buffer balloon + update-loop stall).
-- Spread across ticks, the same work stays under the per-tick budget.
-- -------------------------------------------------------------------------

local queue = { head = 1, tail = 0, items = {}, pending = {} }

local function queueSize()
    return queue.tail - queue.head + 1
end

-- batch is optional: { requested, done, removed, onDone } shared by all
-- entries of one admin cullByIds call, so a completion reply can fire
-- once the whole batch has drained.
local function enqueueCull(z, id, why, batch)
    if queue.pending[id] then return false end
    queue.pending[id] = true
    queue.tail = queue.tail + 1
    queue.items[queue.tail] = { z = z, id = id, why = why, batch = batch }
    return true
end

local function finishBatchEntry(batch, removed)
    if not batch then return end
    batch.done = batch.done + 1
    if removed then batch.removed = batch.removed + 1 end
    if batch.done >= batch.requested and batch.onDone then
        pcall(batch.onDone, batch.requested, batch.removed)
        batch.onDone = nil
    end
end

local function drainCullQueue(c)
    if queue.head > queue.tail then return end

    -- Culling switched off mid-drain: drop the backlog instead of
    -- continuing to remove zombies against the new setting.
    if not c.enabled or not c.cullEnabled then
        while queue.head <= queue.tail do
            local e = queue.items[queue.head]
            queue.items[queue.head] = nil
            queue.head = queue.head + 1
            queue.pending[e.id] = nil
            finishBatchEntry(e.batch, false)
        end
        queue.head, queue.tail, queue.items = 1, 0, {}
        return
    end

    local n = c.cullsPerTick
    while n > 0 and queue.head <= queue.tail do
        local e = queue.items[queue.head]
        queue.items[queue.head] = nil
        queue.head = queue.head + 1
        queue.pending[e.id] = nil

        -- The engine pools IsoZombie objects: a queued reference may have
        -- unloaded and been recycled as a different zombie by drain time.
        -- Only cull if it still answers to the ID it was queued under.
        if e.z:getOnlineID() == e.id then
            if c.logCulls then
                print(string.format("[Reaper:%s] CULL id=%d @%s",
                    tostring(e.why), e.id, tileKey(e.z) or "?"))
            end
            cullZombie(e.z)
            stats.culled = stats.culled + 1
            finishBatchEntry(e.batch, true)
        else
            finishBatchEntry(e.batch, false)
        end
        n = n - 1
    end

    if queue.head > queue.tail then
        queue.head, queue.tail, queue.items = 1, 0, {}
        if c.logCulls then print("[Reaper:queue] drained; queue empty") end
    end
end

-- -------------------------------------------------------------------------
-- Zombie enumeration - the server runs ONE IsoCell world-wide. Every
-- player's loaded area feeds that same cell, and its zombie list holds all
-- loaded real zombies regardless of who loaded them (the engine's own
-- cell-save snapshot filters this one list by cell coords -
-- ZombiePopulationManager.requestSaveCell). One pass covers everything;
-- the old per-player walk visited the same list once per online player.
-- -------------------------------------------------------------------------

local function forEachLoadedZombie(visitor)
    -- getCell dereferences IsoWorld.instance, nil until a world exists.
    local okCell, cell = pcall(getCell)
    local zlist = okCell and cell and cell:getZombieList() or nil
    if not zlist then return end
    local zsize = zlist:size()
    for zi = 0, zsize - 1 do
        local z = zlist:get(zi)
        if z then
            local id = z:getOnlineID()
            if isValidId(id) then
                visitor(z, id)
            end
        end
    end
end

-- -------------------------------------------------------------------------
-- Newborn intake - OnZombieCreate fires inside createRealZombieAlways for
-- every real-zombie materialization, so twins arrive here the frame they
-- exist. Two engine facts shape the flow:
--   * The event fires BEFORE the OnlineID is assigned (VirtualZombieManager
--     triggers at :325, assigns at :335) - getOnlineID() returns -1 in the
--     handler. Refs are queued and resolved on the following ticks.
--   * A bloom's twins all emit from one n_updateMain drain, so they land in
--     the same batch; recentBirths keeps a short tail for stragglers.
-- A side benefit: birth tiles recorded here are exact (the zombie has not
-- moved yet), which sharpens the wandered-bloom scan's birth-tile buckets.
-- -------------------------------------------------------------------------

local pendingNewborns = {}   -- { z = ref, tries = n } awaiting an OnlineID
local recentBirths    = {}   -- [birthTile|outfit] = { {id, z, inv, tick}, ... }
local RECENT_TICKS    = 300  -- ~10s at 30Hz; how long a birth key stays hot

local function onZombieCreate(z)
    if z then pendingNewborns[#pendingNewborns + 1] = { z = z, tries = 0 } end
end

local function pruneRecentBirths(now)
    for key, list in pairs(recentBirths) do
        local keep = {}
        for _, e in ipairs(list) do
            if now - e.tick <= RECENT_TICKS then keep[#keep + 1] = e end
        end
        if #keep > 0 then recentBirths[key] = keep else recentBirths[key] = nil end
    end
end

-- Runs even while disabled, to drain and drop: OnZombieCreate keeps appending
-- regardless, so an early return in the caller would grow this list forever.
local function processNewborns(c, now)
    if #pendingNewborns == 0 then return end
    local batch = pendingNewborns
    pendingNewborns = {}

    if not c.enabled then return end

    -- Resolve ids; re-queue refs the engine has not numbered yet. A ref
    -- that never resolves was removed before it mattered - drop it.
    local resolved = {}
    for _, e in ipairs(batch) do
        local id = e.z:getOnlineID()
        if isValidId(id) then
            resolved[#resolved + 1] = { z = e.z, id = id }
        elseif e.tries < 3 then
            e.tries = e.tries + 1
            pendingNewborns[#pendingNewborns + 1] = e
        end
    end
    if #resolved == 0 then return end

    pruneRecentBirths(now)
    stats.births = stats.births + #resolved

    for _, e in ipairs(resolved) do
        local key = tileKey(e.z)
        if not key then
            -- No square yet; nothing to fingerprint against. Register only.
            knownIds[e.id] = "?"
        else
            local birthKey = key .. "|" .. safeOutfit(e.z)
            local siblings = recentBirths[birthKey]
            local twin = false
            if siblings and bootstrapped and c.cullEnabled then
                -- Cheap key collided with a recent birth on the same tile
                -- with the same outfit template: escalate to the inventory
                -- signature to confirm. Sibling refs may have been recycled
                -- by the engine pool - only trust one that still answers to
                -- the id it was recorded under.
                local myInv
                for _, s in ipairs(siblings) do
                    if s.z:getOnlineID() == s.id then
                        if s.inv == nil then s.inv = inventorySig(s.z) end
                        if myInv == nil then myInv = inventorySig(e.z) end
                        if s.inv == myInv then twin = true; break end
                    end
                end
            end
            if twin then
                enqueueCull(e.z, e.id, "newborn")
            else
                knownIds[e.id] = key
                local list = recentBirths[birthKey]
                if not list then list = {}; recentBirths[birthKey] = list end
                list[#list + 1] = { id = e.id, z = e.z, inv = nil, tick = now }
            end
        end
    end
end

-- -------------------------------------------------------------------------
-- Incremental scanner
--
-- Every detection pass below is O(N) over the whole loaded zombie list with
-- 2-4 engine calls per zombie, and N is unbounded whenever the vanilla cull is off
-- (ZombiesCountBeforeDelete = 0) - which is exactly the configuration this mod
-- exists to make survivable. Running a pass to completion inside one tick
-- therefore costs more the better the server is doing.
--
-- So a scan is a resumable job, not a function call. Each tick spends at most
-- cfg().scanBudget zombie-inspections on the scan in flight; the job carries
-- its own cursor and buckets across ticks and retires when it runs out of
-- list. Only one scan runs at a time, and the three bloom scans take turns -
-- one per interval/3 slot - instead of firing as a burst of three.
--
-- Two consequences of spreading the walk, both handled below:
--   * The zombie list mutates underneath an index walk. A removal shifts the
--     tail down, so the same zombie can be visited twice - and two copies of
--     one zombie in a bucket read as a twin pair. Every pass dedupes by
--     OnlineID (scan.seen), so a revisit cannot manufacture a verdict.
--   * A pass can equally MISS a zombie that shifted past the cursor. That only
--     matters for the sweep's knownIds prune, where a miss would discard a
--     live zombie's birth tile, so ids must go unseen twice running.
-- -------------------------------------------------------------------------

local SCAN_TILE, SCAN_WANDER, SCAN_CLUSTER, SCAN_SWEEP = 1, 2, 3, 4

local SCAN_NAME = {
    [SCAN_TILE]    = "bloom",
    [SCAN_WANDER]  = "wander",
    [SCAN_CLUSTER] = "cluster",
    [SCAN_SWEEP]   = "sweep",
}

-- The three bloom scans rotate: one starts per slot, never all three at once.
local BLOOM_ROTATION = { SCAN_TILE, SCAN_WANDER, SCAN_CLUSTER }

local scan       = nil   -- the job in flight, or nil
local scanQueue  = {}    -- FIFO of pending kinds
local queuedKind = {}    -- [kind] = true; stops a slow scan from stacking up
local staleIds   = {}    -- ids missing from the previous sweep (prune grace)

local function requestScan(kind)
    if queuedKind[kind] then return false end
    if scan and scan.kind == kind then return false end
    queuedKind[kind] = true
    scanQueue[#scanQueue + 1] = kind
    return true
end

local function startScan(kind, c)
    if not c.enabled then return false end
    -- The sweep still runs in monitor-only mode: it maintains knownIds, which
    -- the wander scan and the Necro tab both read. The cull scans do not.
    if kind ~= SCAN_SWEEP and not c.cullEnabled then return false end

    -- getCell dereferences IsoWorld.instance, nil until a world exists.
    local okCell, cell = pcall(getCell)
    local zlist = okCell and cell and cell:getZombieList() or nil
    if not zlist then return false end

    scan = {
        kind     = kind,
        -- Frozen for the life of the job: a sandbox edit landing mid-scan
        -- must not change the rules halfway through one verdict pass.
        c        = c,
        zlist    = zlist,
        index    = 0,
        phase    = "collect",
        judgeIdx = 1,
        removed  = 0,
        seen     = {},
        buckets  = {},
        -- Bucket keys in insertion order. pairs() cannot be resumed across
        -- ticks; an array cursor can.
        order    = {},
        newborns = {},
    }
    if kind == SCAN_SWEEP then stats.ticks = stats.ticks + 1 end
    return true
end

local function bucketFor(s, key)
    local b = s.buckets[key]
    if not b then
        b = {}
        s.buckets[key] = b
        s.order[#s.order + 1] = key
    end
    return b
end

-- -------------------------------------------------------------------------
-- Collect phase - the expensive half. Every branch here is per-zombie engine
-- calls, so this is what cfg().scanBudget actually rations.
-- -------------------------------------------------------------------------

local function collectOne(s, z, id)
    local kind = s.kind

    if kind == SCAN_TILE then
        -- Group by current tile + outfit.
        local tile = tileKey(z)
        if not tile then return end
        local b = bucketFor(s, tile .. "|" .. safeOutfit(z))
        b[#b + 1] = { id = id, z = z }

    elseif kind == SCAN_WANDER then
        -- Group by RECORDED BIRTH tile + outfit, to catch twins that spawned
        -- together and separated since.
        local birthTile = knownIds[id]
        if not birthTile or birthTile == "?" then return end
        local b = bucketFor(s, birthTile .. "|" .. safeOutfit(z))
        b[#b + 1] = { id = id, z = z }

    elseif kind == SCAN_CLUSTER then
        -- Group by outfit alone, across all tiles; position rides along for
        -- the bounding-box gate in the judge phase.
        local sq = z:getSquare()
        if not sq then return end
        local x, y, zc = sq:getX(), sq:getY(), sq:getZ()
        local b = bucketFor(s, safeOutfit(z))
        b[#b + 1] = { id = id, z = z, x = x, y = y, zc = zc }

    else -- SCAN_SWEEP
        local tile = tileKey(z)
        if not tile then return end
        local cheap = tile .. "|" .. safeOutfit(z)
        if knownIds[id] then
            -- Known zombies are the buckets newborns get tested against. They
            -- are only ever looked up by key, never walked, so they stay out
            -- of s.order.
            local b = s.buckets[cheap]
            if not b then b = {}; s.buckets[cheap] = b end
            b[#b + 1] = { z = z, inv = nil }
        else
            local nb = s.newborns
            nb[#nb + 1] = { z = z, id = id, cheap = cheap, birthTile = tile }
        end
    end
end

local function collectStep(s, budget)
    local zlist = s.zlist
    -- Re-read every tick: the list is live and its length moves under us.
    local size = zlist:size()

    while budget > 0 and s.index < size do
        local z = zlist:get(s.index)
        s.index = s.index + 1
        budget  = budget - 1
        if z then
            local id = z:getOnlineID()
            if isValidId(id) and not s.seen[id] then
                s.seen[id] = true
                collectOne(s, z, id)
            end
        end
    end

    return s.index >= size, budget
end

-- -------------------------------------------------------------------------
-- Judge phase - pure Lua over the collected buckets, no engine calls except
-- the enqueue itself. Cheap per entry, but still cursored so one enormous
-- bucket set cannot own a tick. A single bucket is judged atomically: a
-- verdict cannot be reached from a subset of it.
-- -------------------------------------------------------------------------

-- Tile + outfit. Two rules, whichever fires first:
--   1. Sequential IDs: runs of consecutive OnlineIDs within threshold (tight)
--   2. Stack threshold: bucket size >= stackThreshold (safety net for older
--      accumulations whose IDs are no longer perfectly sequential)
local function judgeTile(s, budget)
    local c = s.c
    local seqGap, stackMin = c.sequentialThreshold, c.stackThreshold
    local maxRemove = c.maxPerScan
    local order = s.order

    while budget > 0 and s.judgeIdx <= #order do
        if s.removed >= maxRemove then s.judgeIdx = #order + 1; break end
        local entries = s.buckets[order[s.judgeIdx]]
        s.judgeIdx = s.judgeIdx + 1

        local n = #entries
        budget = budget - (n > 1 and n or 1)
        if n > 1 then
            table.sort(entries, function(a, b) return a.id < b.id end)

            local culledIdx = {}

            -- Rule 1: sequential ID runs
            local i = 1
            while i <= n do
                local j = i + 1
                while j <= n and entries[j].id - entries[j-1].id <= seqGap do
                    j = j + 1
                end
                if j - i >= 2 then
                    for k = i + 1, j - 1 do culledIdx[k] = "seq" end
                end
                i = j
            end

            -- Rule 2: stack threshold (keeps the lowest ID; only counts
            -- entries not already flagged)
            if n >= stackMin then
                for k = stackMin + 1, n do
                    if not culledIdx[k] then culledIdx[k] = "stack" end
                end
            end

            for k = 1, n do
                if s.removed >= maxRemove then break end
                local why = culledIdx[k]
                if why and enqueueCull(entries[k].z, entries[k].id, why) then
                    s.removed = s.removed + 1
                end
            end
        end
    end

    return s.judgeIdx > #order, budget
end

-- Birth tile + outfit, sequential-ID rule only. Outfit narrows the bucket so
-- legit zombies that happened to first-load on the same tile don't match.
local function judgeWander(s, budget)
    local c = s.c
    local seqGap, maxRemove = c.sequentialThreshold, c.maxPerScan
    local order = s.order

    while budget > 0 and s.judgeIdx <= #order do
        if s.removed >= maxRemove then s.judgeIdx = #order + 1; break end
        local entries = s.buckets[order[s.judgeIdx]]
        s.judgeIdx = s.judgeIdx + 1

        local n = #entries
        budget = budget - (n > 1 and n or 1)
        if n > 1 then
            table.sort(entries, function(a, b) return a.id < b.id end)

            local i = 1
            while i <= n do
                if s.removed >= maxRemove then break end
                local j = i + 1
                while j <= n and entries[j].id - entries[j-1].id <= seqGap do
                    j = j + 1
                end
                if j - i >= 2 then
                    for k = i + 1, j - 1 do
                        if s.removed >= maxRemove then break end
                        if enqueueCull(entries[k].z, entries[k].id, "wander") then
                            s.removed = s.removed + 1
                        end
                    end
                end
                i = j
            end
        end
    end

    return s.judgeIdx > #order, budget
end

-- Outfit clusters. Three gates must all fire: same outfit ID, an ID run with
-- gaps <= outfitIdGap of at least outfitMinCluster entries, and a bounding box
-- no larger than outfitProximity tiles. Outfit alone would false-positive in
-- legit uniform zones (hospital, police station).
local function judgeCluster(s, budget)
    local c = s.c
    local idGap, minCount = c.outfitIdGap, c.outfitMinCluster
    local maxBox, maxRemove = c.outfitProximity, c.maxPerScan
    local order = s.order

    while budget > 0 and s.judgeIdx <= #order do
        if s.removed >= maxRemove then s.judgeIdx = #order + 1; break end
        local entries = s.buckets[order[s.judgeIdx]]
        s.judgeIdx = s.judgeIdx + 1

        local n = #entries
        budget = budget - (n > 1 and n or 1)
        if n >= minCount then
            table.sort(entries, function(a, b) return a.id < b.id end)

            local i = 1
            while i <= n do
                if s.removed >= maxRemove then break end
                local j = i + 1
                while j <= n and entries[j].id - entries[j-1].id <= idGap do
                    j = j + 1
                end
                if j - i >= minCount then
                    local minX, minY = entries[i].x, entries[i].y
                    local maxX, maxY = entries[i].x, entries[i].y
                    local zRef, sameZ = entries[i].zc, true
                    for k = i, j - 1 do
                        local e = entries[k]
                        if e.x < minX then minX = e.x end
                        if e.x > maxX then maxX = e.x end
                        if e.y < minY then minY = e.y end
                        if e.y > maxY then maxY = e.y end
                        if e.zc ~= zRef then sameZ = false end
                    end
                    if sameZ and (maxX - minX) <= maxBox and (maxY - minY) <= maxBox then
                        -- Cluster confirmed - cull all but the lowest ID.
                        for k = i + 1, j - 1 do
                            if s.removed >= maxRemove then break end
                            if enqueueCull(entries[k].z, entries[k].id, "cluster") then
                                s.removed = s.removed + 1
                            end
                        end
                    end
                end
                i = j
            end
        end
    end

    return s.judgeIdx > #order, budget
end

-- The safety-net sweep: registers anything OnZombieCreate did not see, and
-- ages out knownIds. Two-stage like the newborn intake - the cheap key
-- (tile|outfit) buckets, and the inventory walk only runs on a collision.
local function judgeSweep(s, budget)
    local c = s.c
    local newborns = s.newborns

    -- Bootstrap pass: register the world's existing population, cull nothing.
    -- Pure table writes, no engine calls, so it stays atomic.
    if not bootstrapped then
        for _, nb in ipairs(newborns) do knownIds[nb.id] = nb.birthTile or "?" end
        bootstrapped = true
        return true, 0
    end

    while budget > 0 and s.judgeIdx <= #newborns do
        local nb = newborns[s.judgeIdx]
        s.judgeIdx = s.judgeIdx + 1
        budget = budget - 1

        local b = s.buckets[nb.cheap]
        local twin = false
        if b and #b > 0 and c.cullEnabled then
            -- Cheap key collided; escalate to the inventory signature to
            -- confirm the template match. Each signature is a full inventory
            -- walk, so charge the budget for them rather than for one newborn.
            local myInv = inventorySig(nb.z)
            budget = budget - 4
            for _, e in ipairs(b) do
                if e.inv == nil then
                    e.inv = inventorySig(e.z)
                    budget = budget - 4
                end
                if e.inv == myInv then twin = true; break end
            end
        end

        if twin then
            if enqueueCull(nb.z, nb.id, "newborn") then
                s.removed = s.removed + 1
            end
        else
            knownIds[nb.id] = nb.birthTile or "?"
            if not b then b = {}; s.buckets[nb.cheap] = b end
            b[#b + 1] = { z = nb.z, inv = nil }
        end
    end
    if s.judgeIdx <= #newborns then return false, budget end

    -- Prune ids the pass never saw. An incremental walk can miss a zombie the
    -- list shifted past the cursor, so a single absence is not proof of death:
    -- an id must go unseen across two consecutive sweeps before its birth tile
    -- is discarded. Pure table work - no engine calls - so it stays atomic;
    -- pairs() cannot be resumed and the cost is one hash lookup per known id.
    local nextStale, doomed = {}, {}
    for id in pairs(knownIds) do
        if not s.seen[id] then
            if staleIds[id] then doomed[#doomed + 1] = id
            else nextStale[id] = true end
        end
    end
    for _, id in ipairs(doomed) do knownIds[id] = nil end
    staleIds = nextStale

    return true, 0
end

local JUDGE = {
    [SCAN_TILE]    = judgeTile,
    [SCAN_WANDER]  = judgeWander,
    [SCAN_CLUSTER] = judgeCluster,
    [SCAN_SWEEP]   = judgeSweep,
}

local function stepScan(budget)
    local s = scan
    local done

    if s.phase == "collect" then
        done, budget = collectStep(s, budget)
        if not done then return end
        s.phase    = "judge"
        s.judgeIdx = 1
        if budget <= 0 then return end
    end

    done = JUDGE[s.kind](s, budget)
    if not done then return end

    if s.removed > 0 and s.c.logCulls then
        print(string.format("[Reaper:%s] scan complete: queued=%d (cap=%d)",
            SCAN_NAME[s.kind], s.removed, s.c.maxPerScan))
    end
    scan = nil
end

-- -------------------------------------------------------------------------
-- Scheduler
-- -------------------------------------------------------------------------

local nextSlotMs  = nil
local nextSweepMs = nil
local lastNowMs   = 0
local rotationIdx = 0

local function onTick()
    local c = cfg()

    drainCullQueue(c)
    tickTotal = tickTotal + 1
    processNewborns(c, tickTotal)

    if not c.enabled then return end

    local now         = clockMs()
    local slotPeriod  = math.max(1, c.bloomInterval) * 60000 / #BLOOM_ROTATION
    local sweepPeriod = math.max(1, c.sweepInterval) * 60000

    if not nextSlotMs or now < lastNowMs then
        -- First tick, or the wall clock stepped backwards (NTP correction).
        -- Rebase, rather than stall until the stale deadlines come round.
        nextSweepMs = now + BOOTSTRAP_MS
        nextSlotMs  = now + slotPeriod
    end
    lastNowMs = now

    -- One bloom scan per slot, taking turns. The scans used to run back to
    -- back in a single handler, so a bloom interval bought three full O(N)
    -- walks in one tick instead of three walks spread over the interval.
    if now >= nextSlotMs then
        nextSlotMs  = now + slotPeriod
        rotationIdx = rotationIdx % #BLOOM_ROTATION + 1
        requestScan(BLOOM_ROTATION[rotationIdx])
    end
    if now >= nextSweepMs then
        nextSweepMs = now + sweepPeriod
        requestScan(SCAN_SWEEP)
    end

    if not scan then
        while #scanQueue > 0 do
            local kind = table.remove(scanQueue, 1)
            queuedKind[kind] = nil
            if startScan(kind, c) then break end
        end
    end
    if scan then stepScan(c.scanBudget) end
end

Events.OnTick.Add(onTick)
-- Engine-registered event (LuaEventManager AddEvent at boot), safe to hook
-- directly. RPCore only loads server-side (guard at top of file), so this
-- never binds on clients, where the same creation funnel also runs.
Events.OnZombieCreate.Add(onZombieCreate)

-- -------------------------------------------------------------------------
-- Force full scan - requests all three bloom scans immediately instead of
-- waiting for their slots. Invoked from the right-click debug menu.
--
-- They still run one at a time on the per-tick budget: "force" moves the
-- schedule up, it does not buy the caller a synchronous triple walk of the
-- whole population. Verdicts land in the cull queue as each scan finishes,
-- so the return value is scans requested, not zombies queued.
-- -------------------------------------------------------------------------

function RPCore.forceScan()
    local requested = 0
    for _, kind in ipairs(BLOOM_ROTATION) do
        if requestScan(kind) then requested = requested + 1 end
    end
    print(string.format("[Reaper:force] full scan requested: %d queued (%d already pending)",
        requested, #BLOOM_ROTATION - requested))
    return requested
end

-- -------------------------------------------------------------------------
-- Snapshot for Dragonfly's Necro tab.
--
-- Walks every loaded zombie, tags each with the strictest verdict that
-- would fire on the next scan (clean / seq / stack / cluster), plus
-- position, outfit, birth tile, and Dirge type when present. Returns a
-- pure-Lua table safe to send via sendServerCommand.
--
-- SUSPECTS ONLY BY DEFAULT. Verdicts still get tagged across the WHOLE loaded
-- population - they have to be, a bucket cannot be judged from a subset - but
-- only rows worth looking at are returned. At bloom scale the difference is the
-- whole problem: a 5,300-zombie snapshot shipped every row at ~106 estimated
-- bytes (~40% of it the key names, repeated per row) for a tab whose entire job
-- is triage, when perhaps dozens were suspect. The rest ship as a count.
--
-- Dirge specials are kept even when clean: the tab filters on them, and there
-- are never many.
--
-- opts.includeClean sends everything anyway, for the tab's explicit "All
-- zombies" / "Clean only" views. Still chunked, so it is slow rather than
-- oversized - the size ceiling is enforced by the chunker in RPServer, not by
-- hoping the caller asks for little.
-- -------------------------------------------------------------------------

function RPCore.snapshot(opts)
    local c = cfg()
    local includeClean = opts and opts.includeClean == true
    local seqGap   = c.sequentialThreshold
    local stackMin = c.stackThreshold
    local idGap    = c.outfitIdGap
    local minCount = c.outfitMinCluster
    local maxBox   = c.outfitProximity

    local zombies = {}

    forEachLoadedZombie(function(z, id)
        local sq = z:getSquare()
        if not sq then return end
        local x, y, zc = sq:getX(), sq:getY(), sq:getZ()

        local md = z:getModData()
        local dirgeType
        if md and md.RQType then dirgeType = tostring(md.RQType) end

        local entry = {
            id        = id,
            x         = x, y = y, z = zc,
            outfit    = safeOutfit(z),
            birthTile = knownIds[id] or "?",
            dirgeType = dirgeType,
            verdict   = "clean",
        }
        zombies[#zombies + 1] = entry
    end)

    -- Tag verdicts. Same grouping logic as the cull scans, but we mark
    -- entries with their strictest rule instead of removing them. Order
    -- of precedence: cluster > stack > seq > clean (later writes win).
    local function setVerdict(entry, v) entry.verdict = v end

    -- Tile + outfit grouping (drives both seq and stack verdicts).
    local byTileOutfit = {}
    for _, e in ipairs(zombies) do
        local key = e.x .. "," .. e.y .. "," .. e.z .. "|" .. e.outfit
        local g = byTileOutfit[key]
        if not g then g = {}; byTileOutfit[key] = g end
        g[#g + 1] = e
    end
    for _, group in pairs(byTileOutfit) do
        if #group > 1 then
            table.sort(group, function(a, b) return a.id < b.id end)

            -- seq runs
            local i = 1
            while i <= #group do
                local j = i + 1
                while j <= #group and group[j].id - group[j-1].id <= seqGap do
                    j = j + 1
                end
                if j - i >= 2 then
                    for k = i + 1, j - 1 do setVerdict(group[k], "seq") end
                end
                i = j
            end

            -- stack overflow
            if #group >= stackMin then
                for k = stackMin + 1, #group do
                    if group[k].verdict ~= "seq" then setVerdict(group[k], "stack") end
                end
            end
        end
    end

    -- Outfit cluster across tiles (with bbox gate).
    local byOutfit = {}
    for _, e in ipairs(zombies) do
        local g = byOutfit[e.outfit]
        if not g then g = {}; byOutfit[e.outfit] = g end
        g[#g + 1] = e
    end
    for _, group in pairs(byOutfit) do
        if #group >= minCount then
            table.sort(group, function(a, b) return a.id < b.id end)
            local i = 1
            while i <= #group do
                local j = i + 1
                while j <= #group and group[j].id - group[j-1].id <= idGap do
                    j = j + 1
                end
                local count = j - i
                if count >= minCount then
                    local minX, minY = group[i].x, group[i].y
                    local maxX, maxY = group[i].x, group[i].y
                    local zRef = group[i].z
                    local sameZ = true
                    for k = i, j - 1 do
                        local e = group[k]
                        if e.x < minX then minX = e.x end
                        if e.x > maxX then maxX = e.x end
                        if e.y < minY then minY = e.y end
                        if e.y > maxY then maxY = e.y end
                        if e.z ~= zRef then sameZ = false end
                    end
                    if sameZ and (maxX - minX) <= maxBox and (maxY - minY) <= maxBox then
                        for k = i + 1, j - 1 do setVerdict(group[k], "cluster") end
                    end
                end
                i = j
            end
        end
    end

    -- Scope the payload AFTER tagging, never before.
    local out, cleanCount = {}, 0
    for _, e in ipairs(zombies) do
        if includeClean or e.verdict ~= "clean" or e.dirgeType then
            out[#out + 1] = e
        else
            cleanCount = cleanCount + 1
        end
    end

    return {
        zombies    = out,
        cleanCount = cleanCount,   -- tagged clean and not sent
        loaded     = #zombies,     -- everything the scan actually walked
        cfg        = c,
        stats      = {
            culled = stats.culled,
            ticks  = stats.ticks,
            queued = queueSize(),
            births = stats.births,
            -- Which scan is mid-walk, if any. Scans are incremental now, so
            -- "nothing queued" no longer means "nothing looking".
            scan   = scan and SCAN_NAME[scan.kind] or "idle",
        },
        timestamp  = getTimestampMs and getTimestampMs() or 0,
    }
end

-- Batch cull by OnlineID list. One resolve pass, no matter how many IDs;
-- matches go through the drain queue like every other cull. onDone
-- (requested, removed) fires once the whole batch has drained. An ID
-- already pending from a scan is culled under the scan's entry and not
-- attributed to this batch.
function RPCore.cullByIds(idList, onDone)
    if not idList or #idList == 0 then
        if onDone then onDone(0, 0) end
        return 0
    end
    local idSet = {}
    for _, id in ipairs(idList) do idSet[tonumber(id) or -1] = true end
    local batch = { requested = 0, done = 0, removed = 0, onDone = onDone }
    local queued = 0
    forEachLoadedZombie(function(z, id)
        if idSet[id] and enqueueCull(z, id, "admin", batch) then
            queued = queued + 1
        end
    end)
    batch.requested = queued
    if queued == 0 and onDone then
        onDone(0, 0)
    end
    return queued
end

-- Live runtime override for a threshold. Used by Necro tab tuning.
function RPCore.setRuntime(key, value)
    if not key then return end
    RPCore.runtime[key] = value
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
