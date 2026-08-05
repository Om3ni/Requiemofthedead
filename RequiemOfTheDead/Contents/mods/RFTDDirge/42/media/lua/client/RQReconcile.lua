-- SPDX-License-Identifier: GPL-3.0-or-later
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

-- ---------------------------------------------------------------------------
-- Loss recovery.
--
-- The delta channel is a strict +1 revision sequence carrying only that pass's
-- churn, so a dropped delta used to be PERMANENT: the client advanced past the
-- hole and the server had already committed md.active as its prevActive, so
-- svRowChanged would never re-ship those rows. On a busy server that shows up
-- as specials nobody can see and ghosts nobody can kill.
--
-- Recovery is a client PULL, not a server push. ModData.request is client-only,
-- served natively by the engine, and replies on the requesting connection
-- ALONE. ModData.transmit by contrast fans the whole blob to every connection
-- with no per-connection form -- a periodic server push would be a congestion
-- spike, which is the disease, not the cure.
--
-- resyncPending exists because a pulled baseline can carry a revision EQUAL to
-- the one we already advanced past on the gap delta; without the flag,
-- onReceiveSnapshot's own revision gate would discard the very baseline we
-- asked for.
-- ---------------------------------------------------------------------------
local resyncPending = false
local lastResyncAt  = 0
local nextPullAt    = 0
local pullTick      = 0

local RESYNC_FLOOR_MS = 15000   -- floor between pulls from THIS client
local PULL_PERIOD_MS  = 60000   -- routine safety-net pull
local PULL_JITTER_MS  = 30000   -- de-phases clients so they never pull in unison

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

-- Ask the server for a full baseline. Rate-floored so a client that keeps
-- gapping during an overload spike doesn't hammer an already-struggling server,
-- and so 29 clients gapping on the SAME spike don't stampede.
local function requestBaseline(reason)
    if not isClient() then return end
    local now = getTimestampMs()
    if now - lastResyncAt < RESYNC_FLOOR_MS then return end
    lastResyncAt  = now
    resyncPending = true
    -- Deliberately a print, not a log write: this line is the direct measure of
    -- how much the server is actually dropping.
    print("[RQReconcile] baseline pull (" .. tostring(reason)
        .. ") lastRevision=" .. tostring(lastRevision))
    ModData.request("RQZombieState")
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
    -- A baseline we explicitly pulled must bypass the revision gate: after a gap
    -- we already advanced lastRevision to the delta that exposed the hole, so
    -- the baseline answering that pull can legitimately be <= it.
    if not resyncPending and revision <= lastRevision then return end

    -- ...but a baseline OLDER than a delta we already applied must not run its
    -- removal-by-absence pass, or it would de-register specials that the newer
    -- delta just added. Adopt its rows, skip its removals.
    local trustRemovals = (revision >= lastRevision)
    resyncPending = false
    if revision > lastRevision then lastRevision = revision end

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
    if trustRemovals then
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
end

-- DELTA: apply only the changed/added rows and explicit removals. No full-table
-- diff -- removals are authoritative from the server, not inferred from absence.
local function onReceiveDelta(delta)
    if not isClient() or not delta then return end

    local revision = delta.revision or 0
    if revision <= lastRevision then return end

    -- The server bumps revision by exactly 1 per snapshot pass and each delta
    -- carries only that pass's churn, so a jump greater than 1 means deltas
    -- never arrived and their rows are gone for good -- pull a baseline.
    -- lastRevision == 0 means our connect-time baseline itself never landed, so
    -- we've been running on whatever fraction the deltas happened to touch;
    -- same remedy, and previously this failed silently forever.
    if lastRevision == 0 then
        requestBaseline("no-baseline")
    elseif revision > lastRevision + 1 then
        requestBaseline("gap:" .. tostring(revision - lastRevision - 1))
    end

    lastRevision = revision
    -- Apply this delta regardless: its rows are current whether or not we
    -- missed the ones before it.

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
    if not RQCommon.acceptsModule(module) or command ~= "zombieDelta" then return end
    onReceiveDelta(args)
end)

-- Routine safety net. Gap detection catches a hole between two deltas that DID
-- arrive; this catches what it structurally cannot see -- a lost removal
-- leaving a ghost, or a run of drops that hides the discontinuity. Jittered so
-- a full server's clients spread their pulls across the period instead of
-- landing together: same total bytes as a server-side periodic transmit, but
-- reshaped from one N-client burst into a trickle of single unicasts.
Events.OnTick.Add(function()
    if not isClient() then return end
    pullTick = pullTick + 1
    if pullTick < 60 then return end   -- ~1s
    pullTick = 0

    local now = getTimestampMs()
    if nextPullAt == 0 then
        -- Land the first pull at a random point in the period so clients that
        -- all connected after a restart never converge on the same second.
        nextPullAt = now + ZombRand(PULL_PERIOD_MS)
        return
    end
    if now < nextPullAt then return end
    nextPullAt = now + PULL_PERIOD_MS + ZombRand(PULL_JITTER_MS)
    requestBaseline("periodic")
end)

Events.OnGameStart.Add(function()
    lastRevision = 0
    resyncPending = false
    lastResyncAt  = 0
    nextPullAt    = 0
    pullTick      = 0
    RQReconcile.lastKnownPos    = {}
    RQReconcile.scavClientState = {}
    if isClient() then
        ModData.request("RQZombieState")
    end
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
