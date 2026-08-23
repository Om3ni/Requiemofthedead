-- SPDX-License-Identifier: GPL-3.0-or-later
-- RPServer - receives client commands and dispatches to RPCore.
-- Server is the authority on zombie removal in MP.
--
-- Commands:
--   forceScan       - run all three bloom scans on demand (legacy)
--   requestSnapshot - reply with a Necro-tab snapshot, paged as SnapshotChunk
--                     commands so bloom-scale snapshots never leave as a single
--                     multi-hundred-KB packet
--   cullById        - cull a single zombie by OnlineID
--   cullIds         - cull a batch of zombies by OnlineID list, itself paged
--   setThreshold    - live override for sequentialThreshold / stackThreshold /
--                     outfitIdGap / outfitMinCluster / outfitProximity
--
-- Every action also pushes a LogBroadcast into the RFTDDragonfly module so
-- Dragonfly's Console tab gets a live audit line. If Dragonfly isn't
-- installed nothing listens; harmless.

if not isServer() then return end

local MODULE = "RFTDReaper"

require "RDShared"   -- explicit: file-scope RD* use must not ride on load order (see MMSvShared header)
require "RDWire"     -- same rule; the chunker sizes itself with RDWire's model

RDShared.registerMod(MODULE, "1.2.1")   -- keep in sync with mod.info

-- Staff gate: RDAccess capability model (RFTDCore adoption) - the old
-- four-level access allowlist is retired; any role holding at least one
-- capability is staff, per family policy.
local function privileged(player)
    return RDAccess.hasAnyCapability(player)
end

local function broadcastAudit(action, player, extra)
    local username = player and player.getUsername and player:getUsername() or "?"
    local tail = extra and (" " .. tostring(extra)) or ""
    print(string.format("[Reaper] %s by %s%s", action, username, tail))
    -- Staff only since 2026-08-19; this was the all-connections overload, which
    -- pushed every Reaper admin action to every player. See RDNet.sendStaff.
    RDNet.sendStaff("RFTDDragonfly", "LogBroadcast", {
        source = "Mod:RFTDReaper",
        level  = "audit",
        text   = string.format("%s by %s%s", action, username, tail),
    })
end

-- No guard on the send: GameServer.sendServerCommand returns early both when
-- the player has left PlayerToAddressMap and when the connection is already
-- closed, so a disconnect between queue and send is the engine's no-op, not
-- ours to catch.
local function reply(player, command, args)
    sendServerCommand(player, MODULE, command, args)
end

-- -------------------------------------------------------------------------
-- Snapshot paging. At bloom scale (thousands of loaded zombies) a snapshot
-- serializes to hundreds of KB; sent as one sendServerCommand it fragments
-- on the wire and camps in the RakNet resend buffer as a single burst.
--
-- THE BUDGET IS BYTES, NOT ROWS, and that distinction is the entire bug this
-- replaced. The old chunker paged 250 rows per command and was, in every other
-- respect, working perfectly - 21 chunks per snapshot, correctly sequenced,
-- correctly reassembled. It just had no idea what a row weighed. At ~106
-- estimated bytes each that is a 26 KB "chunk": past any safe command size,
-- and indistinguishable on a size probe from having no chunker at all.
--
-- So rows are now accumulated against RDWire's own size model - the same model
-- the meter judges the result by - and the budget is declared to RDWire so a
-- breach reports as "chunk-oversize" (this constant is wrong) rather than
-- "unsplit" (go write a chunker). MAXROWS is a backstop only: it stops a
-- pathological row from being the sole occupant of every chunk forever.
-- -------------------------------------------------------------------------

local SNAP_CHUNK_BYTES = 3072                          -- hard per-chunk ceiling, envelope included
local SNAP_ENVELOPE    = 220                           -- gen/seq/total/stats framing reserve
local SNAP_ROW_BUDGET  = SNAP_CHUNK_BYTES - SNAP_ENVELOPE
local SNAP_CHUNK_MAXROWS = 250
local SNAP_TICK_BYTES  = 4096                          -- per-tick send budget, all pending snapshots

RDWire.declareChunked(MODULE .. ":SnapshotChunk", { budget = SNAP_CHUNK_BYTES })

local snapGen   = 0
local snapSends = {}   -- pending sends, serviced against a per-tick byte budget

local function queueSnapshot(player, includeClean)
    local snap    = RPCore.snapshot({ includeClean = includeClean })
    local zombies = snap.zombies or {}
    snapGen = snapGen + 1

    local chunks, sizes  = {}, {}
    local slice, sliceEst = {}, 0

    local function flush()
        if #slice == 0 then return end
        -- n resolved once: `chunks[#chunks+1] = { seq = #chunks+1 }` would lean on
        -- an evaluation order Lua does not promise.
        local n = #chunks + 1
        chunks[n] = { gen = snapGen, seq = n, zombies = slice }
        sizes[n]  = sliceEst + SNAP_ENVELOPE
        slice, sliceEst = {}, 0
    end

    for i = 1, #zombies do
        local row = zombies[i]
        -- +8 for the row's own numeric index key, which costs a Double on the
        -- wire and is not part of the row's own estimate.
        local rowEst = RDWire.estimate(row) + 8
        if #slice > 0 and (sliceEst + rowEst > SNAP_ROW_BUDGET or #slice >= SNAP_CHUNK_MAXROWS) then
            flush()
        end
        slice[#slice + 1] = row
        sliceEst = sliceEst + rowEst
    end
    flush()

    -- An empty result still needs one chunk, or the client has nothing to
    -- complete against and waits forever for a stream that already finished.
    if #chunks == 0 then
        chunks[1] = { gen = snapGen, seq = 1, zombies = {} }
        sizes[1]  = SNAP_ENVELOPE
    end

    -- total is only knowable once the last row has been placed, so it is
    -- stamped in afterwards rather than computed up front.
    local total = #chunks
    for i = 1, total do chunks[i].total = total end

    -- Stats ride on the last chunk; the client shows them on assembly.
    chunks[total].stats      = snap.stats
    chunks[total].timestamp  = snap.timestamp
    chunks[total].cleanCount = snap.cleanCount
    chunks[total].loaded     = snap.loaded

    snapSends[#snapSends + 1] = { player = player, chunks = chunks, sizes = sizes, nextIdx = 1 }
end

-- Paced by bytes for the same reason the chunks are sized by bytes: one command
-- per tick is a rate only if every command weighs the same, and now they do not.
local function pumpSnapshotSends()
    local spent = 0
    while spent < SNAP_TICK_BYTES do
        local send = snapSends[1]
        if not send then return end
        local idx   = send.nextIdx
        local chunk = send.chunks[idx]
        if not chunk then
            table.remove(snapSends, 1)
        else
            reply(send.player, "SnapshotChunk", chunk)
            spent = spent + (send.sizes[idx] or SNAP_CHUNK_BYTES)
            send.nextIdx = idx + 1
            if send.nextIdx > #send.chunks then table.remove(snapSends, 1) end
        end
    end
end

-- -------------------------------------------------------------------------
-- Cull batching. The client pages a large id list the same way the server
-- pages a snapshot, for the same reason: "Cull selected" over a bloom-scale
-- selection was one command carrying every OnlineID at ~16 estimated bytes
-- apiece (a Double key plus a Double value), which is the snapshot bug again
-- with the arrow pointing the other way. It never showed up in telemetry only
-- because the tab it is driven from never populated, so nobody could select
-- anything to cull.
--
-- Parts are accumulated per (username, token) and the cull runs once, on the
-- last part - one resolve pass and one CullResult, exactly as before. A batch
-- whose sender disconnects mid-send would otherwise sit here forever, so parts
-- age out and the caller is told rather than left waiting on a reply that is
-- never coming.
-- -------------------------------------------------------------------------

local CULL_BATCH_TTL = 900   -- ticks (~30s at 30Hz) without a new part
local cullBatches    = {}    -- "user:token" -> { ids, seen, got, total, player, age }

RDWire.declareChunked(MODULE .. ":cullIds", { budget = 3072 })

local function runCull(player, ids)
    local n = #ids
    local queued = RPCore.cullByIds(ids, function(_, removed)
        reply(player, "CullResult", { requested = n, removed = removed })
    end)
    broadcastAudit("cullIds", player, "count=" .. n .. " queued=" .. queued)
end

local function acceptCullPart(player, args)
    local ids   = args.ids or {}
    local total = tonumber(args.total) or 1
    local seq   = tonumber(args.seq) or 1

    if total <= 1 then
        runCull(player, ids)
        return
    end

    local user = player and player.getUsername and player:getUsername() or "?"
    local bkey = user .. ":" .. tostring(args.token or "single")

    local b = cullBatches[bkey]
    if not b then
        b = { ids = {}, seen = {}, got = 0, total = total, player = player, age = 0 }
        cullBatches[bkey] = b
    end
    b.age = 0
    if not b.seen[seq] then
        b.seen[seq] = true
        b.got = b.got + 1
        for _, id in ipairs(ids) do b.ids[#b.ids + 1] = id end
    end
    if b.got >= b.total then
        cullBatches[bkey] = nil
        runCull(player, b.ids)
    end
end

local function expireCullBatches()
    for k, b in pairs(cullBatches) do
        b.age = b.age + 1
        if b.age > CULL_BATCH_TTL then
            cullBatches[k] = nil
            print(string.format("[Reaper] cull batch %s expired incomplete (%d/%d parts, %d ids)",
                tostring(k), b.got, b.total, #b.ids))
            reply(b.player, "CullResult",
                { requested = #b.ids, removed = 0, incomplete = true })
        end
    end
end

Events.OnTick.Add(function()
    pumpSnapshotSends()
    expireCullBatches()
end)

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    local s = SandboxVars.RFTDReaper or {}
    if s.Enabled == false then
        print("[Reaper] command ignored: mod disabled (" .. tostring(command) .. ")")
        return
    end
    args = args or {}

    if command == "forceScan" then
        if s.DebugContextMenu ~= true then
            print("[Reaper] forceScan ignored: DebugContextMenu disabled")
            return
        end
        -- The sandbox flag gates whether the CLIENT draws the menu option; it was
        -- never an authority check, and this was the one branch here without one.
        -- Reaper has not adopted RDNet, so there is no default-deny underneath
        -- either: any client could spam a server-wide scan on a debug-enabled
        -- server, under an audit line that read as though it had been gated.
        if not privileged(player) then
            broadcastAudit("forceScan refused", player, "(no access)")
            return
        end
        broadcastAudit("forceScan", player)
        RPCore.forceScan()

    elseif command == "requestSnapshot" then
        if not privileged(player) then
            broadcastAudit("requestSnapshot refused", player, "(no access)")
            return
        end
        queueSnapshot(player, args.includeClean == true)

    elseif command == "cullById" then
        if not privileged(player) then return end
        local id = tonumber(args.id)
        if not id then return end
        -- CullResult fires once the queued cull has actually drained, so
        -- the client's auto-refresh snapshot reflects the removal.
        local queued = RPCore.cullByIds({ id }, function(_, removed)
            reply(player, "CullResult", { requested = 1, removed = removed })
        end)
        broadcastAudit("cullById", player, "id=" .. id .. " queued=" .. queued)

    elseif command == "cullIds" then
        if not privileged(player) then return end
        acceptCullPart(player, args)

    elseif command == "setThreshold" then
        if not privileged(player) then return end
        local key   = args.key
        local value = tonumber(args.value)
        if not key or not value then return end
        -- The key was allow-listed but the VALUE was not, and it goes straight
        -- into the live automatic-cull thresholds. A negative or absurd figure
        -- from a staff account - fat-fingered as easily as forged - could make
        -- the culler match everything or nothing, on a server where culling is
        -- how the population stays survivable. A capability answers who may
        -- attempt this; it does not make the payload true.
        --
        -- Ranges are the operational envelope each key actually has: run
        -- lengths and cluster sizes are counts of zombies, the id gap is a
        -- spread within an outfit run, and proximity is measured in tiles.
        local RANGE = {
            sequentialThreshold = { 2, 500 },
            stackThreshold      = { 2, 500 },
            outfitIdGap         = { 1, 10000 },
            outfitMinCluster    = { 2, 500 },
            outfitProximity     = { 1, 200 },
        }
        local bounds = RANGE[key]
        if not bounds then return end
        if value ~= value or value < bounds[1] or value > bounds[2] then
            print(string.format(
                "[Reaper] setThreshold refused: %s=%s outside [%d, %d]",
                tostring(key), tostring(value), bounds[1], bounds[2]))
            -- No `value` in the refusal: there is no RPCore.getRuntime to read
            -- the live figure back from, and echoing the REJECTED number would
            -- let the panel display it as though it had been applied.
            reply(player, "ThresholdAck",
                { key = key, refused = true,
                  reason = string.format("%s must be between %d and %d",
                                         key, bounds[1], bounds[2]) })
            return
        end
        RPCore.setRuntime(key, value)
        broadcastAudit("setThreshold", player, key .. "=" .. tostring(value))
        reply(player, "ThresholdAck", { key = key, value = value })
    end
end

Events.OnClientCommand.Add(onClientCommand)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
