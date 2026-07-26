-- RQReconcile - registry sync for MP clients
-- Keeps RQRegistry.activeZombies in sync with the server's special-zombie state.
--
-- Two server channels feed this, sharing one revision counter:
--   1. BASELINE (full table) via ModData "RQZombieState" - sent on player connect
--      and on ModData.request (late join / game start). Carries the complete active
--      set; reconciles the local registry by adding present and removing absent.
--   2. DELTA (RQ:zombieDelta command) - the steady-state path. Carries only the rows
--      that changed/were added since the last snapshot plus a list of removed ids.
--      This replaces the old full-table re-broadcast every ~2s (RQZombieState was
--      shipping the entire table on any single zombie's move; the delta ships just
--      the churn).
--
-- Event-driven broadcasts (zombieConverted, castStart, castDone) still handle
-- real-time feel; this is the self-healing structural layer.

RQReconcile = RQReconcile or {}

local lastRevision = 0

-- Last known world position per onlineID. Populated from rows so findZombieByID
-- has real coords to search from (instead of 0,0,0 which only works at world origin).
RQReconcile.lastKnownPos = RQReconcile.lastKnownPos or {}

-- Scavenger client-side rage state for the highlight gradient. Populated from rows
-- (server includes enraged/currentHP/peakHP/baseHealth).
-- RQScavenger.getHighlightColor(onlineID) reads from this table.
RQReconcile.scavClientState = RQReconcile.scavClientState or {}

-- Apply one server row to local client state: register the zombie, cache its
-- position, mirror scavenger rage state, and spin up a cast bar if it's casting.
-- Shared by both the baseline and the delta path so they can't drift apart.
local function applyRow(idStr, row, serverTime)
    if not row.alive then return end
    local oid = tonumber(idStr)
    if not oid then return end

    if row.x and row.y then
        RQReconcile.lastKnownPos[oid] = { x = row.x, y = row.y, z = row.z or 0 }
    end

    if not RQRegistry.activeZombies[oid] then
        RQRegistry.register(oid, row.zType)
    end

    if row.zType == "Scavenger" then
        RQReconcile.scavClientState[oid] = {
            enraged    = row.enraged   or false,
            currentHP  = row.currentHP  or 1,
            peakHP     = row.peakHP     or row.baseHealth or 1,
            baseHealth = row.baseHealth or 1,
        }
    end

    if row.castDue and row.castRingId and RQCore and RQCore.ensureCastFromSnapshot then
        RQCore.ensureCastFromSnapshot(row, serverTime)
    end
end

-- Drop all local trace of a zombie the server no longer reports.
local function removeLocal(oid)
    RQRegistry.unregister(oid)
    RQReconcile.lastKnownPos[oid]    = nil
    RQReconcile.scavClientState[oid] = nil
end

-- BASELINE: reconcile the full local registry against a complete server snapshot.
local function onReceiveSnapshot()
    if not isClient() then return end

    local md = ModData.getOrCreate("RQZombieState")
    if not md or not md.active then return end

    local revision = md.revision or 0
    if revision <= lastRevision then return end
    lastRevision = revision

    -- apply every server row, tracking which ids the server knows about
    local serverIds = {}
    for idStr, row in pairs(md.active) do
        if row.alive then
            local oid = tonumber(idStr)
            if oid then
                serverIds[oid] = true
                applyRow(idStr, row, md.serverTime)
            end
        end
    end

    -- remove anything locally tracked but absent from the full snapshot
    -- collect first, then delete -- safe pairs iteration pattern
    local toRemove   = {}
    local removeCount = 0
    for oid in pairs(RQRegistry.activeZombies) do
        if not serverIds[oid] then
            removeCount = removeCount + 1
            toRemove[removeCount] = oid
        end
    end
    for i = 1, removeCount do
        removeLocal(toRemove[i])
    end
end

-- DELTA: apply only the changed/added rows and explicit removals. No full-table
-- diff -- removals are authoritative from the server, not inferred from absence.
local function onReceiveDelta(delta)
    if not isClient() or not delta then return end

    local revision = delta.revision or 0
    if revision <= lastRevision then return end
    lastRevision = revision

    local md = ModData.getOrCreate("RQZombieState")
    md.active     = md.active or {}
    md.serverTime = delta.serverTime or md.serverTime

    if delta.changed then
        for idStr, row in pairs(delta.changed) do
            md.active[idStr] = row          -- keep the local mirror current
            applyRow(idStr, row, md.serverTime)
        end
    end

    if delta.removed then
        for i = 1, #delta.removed do
            local idStr = delta.removed[i]
            md.active[idStr] = nil
            local oid = tonumber(idStr)
            if oid then removeLocal(oid) end
        end
    end
end

-- Baseline channel: full ModData snapshot (connect / request).
Events.OnReceiveGlobalModData.Add(function(module, data)
    if module ~= "RQZombieState" then return end
    -- Merge server data into local ModData before reconciling, so the merge is
    -- guaranteed complete before onReceiveSnapshot reads the table.
    if data then ModData.add(module, data) end
    onReceiveSnapshot()
end)

-- Delta channel: lightweight per-tick churn.
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RQ" or command ~= "zombieDelta" then return end
    onReceiveDelta(args)
end)

Events.OnGameStart.Add(function()
    lastRevision = 0
    RQReconcile.lastKnownPos    = {}
    RQReconcile.scavClientState = {}
    if isClient() then
        ModData.request("RQZombieState")
    end
end)

-- Copyright Project_Omen
