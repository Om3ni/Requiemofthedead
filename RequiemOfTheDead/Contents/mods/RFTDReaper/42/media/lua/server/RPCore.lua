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
        logCulls            = s.LogCulls ~= false,
        sequentialThreshold = r.sequentialThreshold or s.SequentialThreshold or 2,
        stackThreshold      = r.stackThreshold      or s.StackThreshold      or 5,
        bloomInterval       = s.BloomInterval or 5,
        maxPerScan          = s.MaxRemovalsPerScan or 500,
        cullsPerTick        = s.CullsPerTick or 15,
        outfitIdGap         = r.outfitIdGap     or s.OutfitIdGap     or 15,
        outfitMinCluster    = r.outfitMinCluster or s.OutfitMinCluster or 3,
        outfitProximity     = r.outfitProximity  or s.OutfitProximity  or 75,
    }
end

-- -------------------------------------------------------------------------
-- Fingerprint - outfit + sorted inventory type-counts
-- -------------------------------------------------------------------------

local function safeOutfit(z)
    -- Try persistent outfit ID first - integer, survives saves, twins share it.
    local ok, id = pcall(function() return z:getPersistentOutfitID() end)
    if ok and id and id ~= 0 then return "o" .. tostring(id) end
    -- Fall back to getOutfitName (may only work on IsoDeadBody).
    local ok2, name = pcall(function() return z:getOutfitName() end)
    if ok2 and name and name ~= "" then return tostring(name) end
    return "?outfit?"
end

local function inventorySig(z)
    local ok, inv = pcall(function() return z:getInventory() end)
    if not ok or not inv then return "" end
    local ok2, items = pcall(function() return inv:getItems() end)
    if not ok2 or not items then return "" end
    local counts = {}
    local size = 0
    pcall(function() size = items:size() end)
    for i = 0, size - 1 do
        local it
        pcall(function() it = items:get(i) end)
        if it then
            local t
            pcall(function() t = it:getFullType() end)
            t = t or "?"
            counts[t] = (counts[t] or 0) + 1
        end
    end
    local parts = {}
    for t, c in pairs(counts) do parts[#parts + 1] = t .. "x" .. c end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function tileKey(z)
    local sq
    pcall(function() sq = z:getSquare() end)
    if not sq then return nil end
    local x, y, zc
    pcall(function() x = sq:getX(); y = sq:getY(); zc = sq:getZ() end)
    if not x or not y or not zc then return nil end
    return x .. "," .. y .. "," .. zc, x, y, zc
end

local function fingerprintFull(z)
    local key, x, y, zc = tileKey(z)
    if not key then return nil end
    return key .. "|" .. safeOutfit(z) .. "|" .. inventorySig(z), x, y, zc
end

-- -------------------------------------------------------------------------
-- Removal - defensive; multiple known APIs, pcall each
-- -------------------------------------------------------------------------

local function cullZombie(z)
    pcall(function() z:removeFromSquare() end)
    pcall(function() z:removeFromWorld() end)
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
local stats        = { culled = 0, ticks = 0 }

local LIVE_INTERVAL    = 200  -- ticks; ~7s at 30Hz - catches twins before they wander
local tickCount        = 0
local bloomMinuteCount = 0

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

local function drainCullQueue()
    if queue.head > queue.tail then return end
    local c = cfg()

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
        local ok, curId = pcall(function() return e.z:getOnlineID() end)
        if ok and curId == e.id then
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
-- Zombie enumeration - server-side getCell() only exposes one cell, so a
-- bloom in a remote player's loaded area is invisible to it. We instead
-- walk every online player's cell and dedupe by OnlineID. This covers all
-- loaded chunks across all connected players.
-- -------------------------------------------------------------------------

local function forEachLoadedZombie(visitor)
    local players = getOnlinePlayers()
    if not players then return end
    local seen = {}
    for pi = 0, players:size() - 1 do
        local p = players:get(pi)
        if p then
            local pcell
            pcall(function() pcell = p:getCell() end)
            if pcell then
                local zlist
                pcall(function() zlist = pcell:getZombieList() end)
                if zlist then
                    local zsize = zlist:size()
                    for zi = 0, zsize - 1 do
                        local z = zlist:get(zi)
                        if z then
                            local id = z:getOnlineID()
                            if isValidId(id) and not seen[id] then
                                seen[id] = true
                                visitor(z, id)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function newbornSweep()
    local c = cfg()
    if not c.enabled then return end

    stats.ticks = stats.ticks + 1

    local bucketByFp = {}
    local newborns   = {}
    local seenIds    = {}

    forEachLoadedZombie(function(z, id)
        seenIds[id] = true
        local fp = fingerprintFull(z)
        if fp then
            if knownIds[id] then
                local b = bucketByFp[fp]
                if not b then b = {}; bucketByFp[fp] = b end
                b[#b + 1] = z
            else
                newborns[#newborns + 1] = { z = z, id = id, fp = fp, birthTile = tileKey(z) }
            end
        end
    end)

    -- Bootstrap pass: register everyone as known, do not cull.
    if not bootstrapped then
        for _, nb in ipairs(newborns) do knownIds[nb.id] = nb.birthTile or "?" end
        bootstrapped = true
        return
    end

    for _, nb in ipairs(newborns) do
        local twins = bucketByFp[nb.fp]
        if twins and #twins > 0 and c.cullEnabled then
            enqueueCull(nb.z, nb.id, "newborn")
        else
            knownIds[nb.id] = nb.birthTile or "?"
            local b = bucketByFp[nb.fp]
            if not b then b = {}; bucketByFp[nb.fp] = b end
            b[#b + 1] = nb.z
        end
    end

    for id in pairs(knownIds) do
        if not seenIds[id] then knownIds[id] = nil end
    end
end

-- -------------------------------------------------------------------------
-- Tile+outfit bloom scan - catches existing/migrated blooms that the newborn
-- watcher missed. Groups loaded zombies by (current tile, outfit ID). Within
-- each bucket, culls based on two rules (whichever fires first):
--   1. Sequential IDs: runs of consecutive OnlineIDs within threshold (tight)
--   2. Stack threshold: bucket size >= stackThreshold (safety net for blooms
--      whose IDs aren't perfectly sequential - e.g., older accumulated stacks)
-- Removals are capped per scan to avoid frame spikes on huge blooms.
-- -------------------------------------------------------------------------

local function tileSequentialScan()
    local c = cfg()
    if not c.enabled then return end
    if not c.cullEnabled then return end

    local seqGap    = c.sequentialThreshold
    local stackMin  = c.stackThreshold
    local maxRemove = c.maxPerScan
    local byKey     = {}

    forEachLoadedZombie(function(z, id)
        local tile = tileKey(z)
        if tile then
            local key = tile .. "|" .. safeOutfit(z)
            local t = byKey[key]
            if not t then t = { tile = tile, entries = {} }; byKey[key] = t end
            local e = t.entries
            e[#e + 1] = { id = id, z = z }
        end
    end)

    local removed = 0

    for key, group in pairs(byKey) do
        if removed >= maxRemove then break end
        local entries = group.entries
        if #entries > 1 then
            table.sort(entries, function(a, b) return a.id < b.id end)

            local culledIdx = {}

            -- Rule 1: sequential ID runs
            local i = 1
            while i <= #entries do
                local j = i + 1
                while j <= #entries and entries[j].id - entries[j-1].id <= seqGap do
                    j = j + 1
                end
                if j - i >= 2 then
                    for k = i + 1, j - 1 do culledIdx[k] = "seq" end
                end
                i = j
            end

            -- Rule 2: stack threshold (anything beyond stackMin gets culled,
            -- keeping the lowest ID; only counts entries not already flagged)
            if #entries >= stackMin then
                for k = stackMin + 1, #entries do
                    if not culledIdx[k] then culledIdx[k] = "stack" end
                end
            end

            for k = 1, #entries do
                if removed >= maxRemove then break end
                local why = culledIdx[k]
                if why and enqueueCull(entries[k].z, entries[k].id, why) then
                    removed = removed + 1
                end
            end
        end
    end

    if removed > 0 and c.logCulls then
        print(string.format("[Reaper:bloom] scan complete: queued=%d (cap=%d)", removed, maxRemove))
    end
end

-- -------------------------------------------------------------------------
-- Wandered bloom scan - catches twins that spawned together and separated.
-- Groups loaded zombies by (recorded birth tile, outfit ID) and applies the
-- same sequential-ID rule. Outfit narrows the bucket so legit zombies that
-- happened to first-load on the same tile don't false-positive.
-- -------------------------------------------------------------------------

local function wanderedBloomScan()
    local c = cfg()
    if not c.enabled then return end
    if not c.cullEnabled then return end

    local seqGap    = c.sequentialThreshold
    local maxRemove = c.maxPerScan
    local byKey     = {}

    forEachLoadedZombie(function(z, id)
        local birthTile = knownIds[id]
        if birthTile and birthTile ~= "?" then
            local key = birthTile .. "|" .. safeOutfit(z)
            local t = byKey[key]
            if not t then t = { birthTile = birthTile, entries = {} }; byKey[key] = t end
            local e = t.entries
            e[#e + 1] = { id = id, z = z }
        end
    end)

    local removed = 0

    for key, group in pairs(byKey) do
        if removed >= maxRemove then break end
        local entries = group.entries
        if #entries > 1 then
            table.sort(entries, function(a, b) return a.id < b.id end)

            local i = 1
            while i <= #entries do
                if removed >= maxRemove then break end
                local j = i + 1
                while j <= #entries and entries[j].id - entries[j-1].id <= seqGap do
                    j = j + 1
                end
                if j - i >= 2 then
                    for k = i + 1, j - 1 do
                        if removed >= maxRemove then break end
                        if enqueueCull(entries[k].z, entries[k].id, "wander") then
                            removed = removed + 1
                        end
                    end
                end
                i = j
            end
        end
    end

    if removed > 0 and c.logCulls then
        print(string.format("[Reaper:wander] scan complete: queued=%d (cap=%d)", removed, maxRemove))
    end
end

-- -------------------------------------------------------------------------
-- Outfit cluster scan - catches wandered/dispersed blooms that tile-based
-- scans miss. Groups by outfit ID (across all tiles), finds runs of nearly-
-- sequential IDs within the outfit bucket, and only culls clusters that
-- are geographically proximate (bbox <= outfitProximity tiles).
--
-- Three gates must all fire:
--   1. Same outfit ID (twin template match)
--   2. ID run with gaps <= outfitIdGap, cluster size >= outfitMinCluster
--   3. Bounding box width AND height <= outfitProximity tiles
--
-- Tile and ID together discriminate; outfit alone would false-positive in
-- legit zones (hospital, police station). All three together = bloom.
-- -------------------------------------------------------------------------

local function outfitClusterScan()
    local c = cfg()
    if not c.enabled then return end
    if not c.cullEnabled then return end

    local idGap     = c.outfitIdGap
    local minCount  = c.outfitMinCluster
    local maxBox    = c.outfitProximity
    local maxRemove = c.maxPerScan

    -- Group all loaded zombies by outfit ID, with each entry's position.
    local byOutfit = {}
    forEachLoadedZombie(function(z, id)
        local sq
        pcall(function() sq = z:getSquare() end)
        if not sq then return end
        local x, y, zc
        pcall(function() x = sq:getX(); y = sq:getY(); zc = sq:getZ() end)
        if not (x and y and zc) then return end
        local outfit = safeOutfit(z)
        local g = byOutfit[outfit]
        if not g then g = {}; byOutfit[outfit] = g end
        g[#g + 1] = { id = id, z = z, x = x, y = y, zc = zc }
    end)

    local removed = 0

    for outfit, entries in pairs(byOutfit) do
        if removed >= maxRemove then break end
        if #entries >= minCount then
            table.sort(entries, function(a, b) return a.id < b.id end)

            -- Walk ID-based runs within the outfit bucket.
            local i = 1
            while i <= #entries do
                if removed >= maxRemove then break end
                local j = i + 1
                while j <= #entries and entries[j].id - entries[j-1].id <= idGap do
                    j = j + 1
                end
                local count = j - i
                if count >= minCount then
                    -- Geographic check: bounding box must be tight.
                    local minX, minY, maxX, maxY = entries[i].x, entries[i].y, entries[i].x, entries[i].y
                    local sameZ = true
                    local zRef = entries[i].zc
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
                            if removed >= maxRemove then break end
                            if enqueueCull(entries[k].z, entries[k].id, "cluster") then
                                removed = removed + 1
                            end
                        end
                    end
                end
                i = j
            end
        end
    end

    if removed > 0 and c.logCulls then
        print(string.format("[Reaper:cluster] scan complete: queued=%d (cap=%d)", removed, maxRemove))
    end
end

local function onTick()
    drainCullQueue()
    tickCount = tickCount + 1
    if tickCount < LIVE_INTERVAL then return end
    tickCount = 0
    newbornSweep()
end

local function onMinute()
    bloomMinuteCount = bloomMinuteCount + 1
    if bloomMinuteCount >= cfg().bloomInterval then
        bloomMinuteCount = 0
        tileSequentialScan()
        wanderedBloomScan()
        outfitClusterScan()
    end
end

Events.OnTick.Add(onTick)
Events.EveryOneMinute.Add(onMinute)

-- -------------------------------------------------------------------------
-- Force full scan - runs all three bloom scans on demand instead of waiting
-- for the interval timer. Invoked from the right-click debug menu.
-- -------------------------------------------------------------------------

function RPCore.forceScan()
    local before = queueSize()
    print("[Reaper:force] full scan starting")
    tileSequentialScan()
    wanderedBloomScan()
    outfitClusterScan()
    local queued = queueSize() - before
    print(string.format("[Reaper:force] full scan complete: queued=%d", queued))
    return queued
end

-- -------------------------------------------------------------------------
-- Snapshot for Dragonfly's Necro tab.
--
-- Walks every loaded zombie, tags each with the strictest verdict that
-- would fire on the next scan (clean / seq / stack / cluster), plus
-- position, outfit, birth tile, and Dirge type when present. Returns a
-- pure-Lua table safe to send via sendServerCommand.
-- -------------------------------------------------------------------------

function RPCore.snapshot()
    local c = cfg()
    local seqGap   = c.sequentialThreshold
    local stackMin = c.stackThreshold
    local idGap    = c.outfitIdGap
    local minCount = c.outfitMinCluster
    local maxBox   = c.outfitProximity

    local zombies = {}
    local byId    = {}

    forEachLoadedZombie(function(z, id)
        local sq
        pcall(function() sq = z:getSquare() end)
        if not sq then return end
        local x, y, zc
        pcall(function() x = sq:getX(); y = sq:getY(); zc = sq:getZ() end)
        if not (x and y and zc) then return end

        local dirgeType
        pcall(function()
            local md = z:getModData()
            if md and md.RQType then dirgeType = tostring(md.RQType) end
        end)

        local entry = {
            id        = id,
            x         = x, y = y, z = zc,
            outfit    = safeOutfit(z),
            birthTile = knownIds[id] or "?",
            dirgeType = dirgeType,
            verdict   = "clean",
        }
        zombies[#zombies + 1] = entry
        byId[id] = entry
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

    return {
        zombies   = zombies,
        cfg       = c,
        stats     = { culled = stats.culled, ticks = stats.ticks, queued = queueSize() },
        timestamp = getTimestampMs and getTimestampMs() or 0,
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
