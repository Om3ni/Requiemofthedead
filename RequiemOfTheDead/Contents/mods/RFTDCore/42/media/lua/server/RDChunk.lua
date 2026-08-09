-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDChunk.lua - paged, byte-paced server->client sends (server only).
--
-- ===========================================================================
-- WHY THIS IS IN CORE. It was written twice: once in RFTDReaper, correctly, and
-- nowhere else. A 2026-08-09 wire capture of four family mods read as a gradient
-- of the same discipline at four stages of adoption:
--
--   Reaper       SnapshotChunk   max 2.86 KB   declared 3 KB budget, none over
--   Reclamation  Fleet           max 12.6 KB   chunks, no declared budget, 4 over
--   Dragonfly    PlayerInventory max 12.9 KB   no chunker at all
--   Dirge        zombieDelta     max 7.73 KB   no chunker, 96% of the alert ceiling
--
-- Those are not four bugs. They are one lesson that was learned once, by the mod
-- that got burned, and never propagated. RDWire already carried the CONTRACT
-- (declareChunked, so a breach reports as "your budget is wrong" instead of "go
-- write a chunker") but not the MECHANISM, so every other mod had to rediscover
-- it - and rediscovering it is exactly what none of them did.
--
-- RDWire's own header records the same failure happening to Reaper first: paging
-- correctly into 21 chunks per snapshot, every chunk 26 KB, and reported as no
-- chunker at all. This file is that lesson made reusable.
-- ===========================================================================
--
-- WHAT A CORRECT PAGED SEND ACTUALLY REQUIRES, all four parts:
--
--   1. Split by BYTES, not by rows. A fixed row count drifts into oversized
--      payloads the moment a row grows, and the growth is never in the diff that
--      caused it. Rows are measured with RDWire.estimate - the same model the
--      meter judges the result by, so the budget and the verdict cannot disagree.
--   2. DECLARE the budget to RDWire, or the probe judges chunks against its
--      general ceiling and a working chunker reports as no chunker.
--   3. Always emit at least ONE chunk. An empty result that sends nothing leaves
--      a receiver waiting forever for a stream that already finished.
--   4. PACE the sends by bytes across ticks. "One command per tick" is a rate
--      only if every command weighs the same, and after chunking they do not.
--
-- Reaper had all four. This generalises them; the numbers stay per-stream because
-- a zombie row and a vehicle row are not the same size.
--
-- ONE PENDING SEND PER (player, command), newest wins. This is a deliberate
-- change from Reaper's plain FIFO, and it buys two things at once: the queue
-- cannot grow without bound when a client asks faster than the pump drains, and
-- a superseded send is exactly what a stale one IS - every stream this serves
-- carries current state, so an older generation still draining is already wrong.
-- It is also what makes the round-robin below safe: two generations of the same
-- stream can never be interleaved, because the second replaced the first.

if not isServer() then return end

require "RDWire"

RDChunk = RDChunk or { streams = {}, queue = {}, index = {} }

local DEFAULTS = {
    budget    = 3072,   -- per-chunk ceiling, envelope included
    envelope  = 220,    -- framing reserve (gen/seq/total/tail)
    maxRows   = 250,    -- backstop against one pathological row per chunk forever
    field     = "rows", -- name of the array field carried in each chunk
}

-- Global per-tick send budget, shared by every stream. Bounding the TOTAL is the
-- point: a per-stream budget lets N streams each behave and still add up to a
-- stall. Generous enough that a paged send finishes promptly at 30 FPS.
local TICK_BYTES = 8192

-- ---------------------------------------------------------------------------
-- Declaration
-- ---------------------------------------------------------------------------

-- Declare a stream once, at load. Registers the budget with RDWire so the wire
-- probe judges this key against ITS OWN ceiling rather than the general one.
function RDChunk.declare(module, command, opts)
    opts = opts or {}
    local key = tostring(module) .. ":" .. tostring(command)
    local s = {
        module   = tostring(module),
        command  = tostring(command),
        budget   = tonumber(opts.budget)   or DEFAULTS.budget,
        envelope = tonumber(opts.envelope) or DEFAULTS.envelope,
        maxRows  = tonumber(opts.maxRows)  or DEFAULTS.maxRows,
        field    = tostring(opts.field or DEFAULTS.field),
        gen      = 0,
    }
    -- A row budget that leaves no room for rows is a configuration error that
    -- would otherwise present as one row per chunk forever.
    if s.envelope >= s.budget then s.envelope = math.floor(s.budget / 4) end
    s.rowBudget = s.budget - s.envelope

    RDChunk.streams[key] = s
    pcall(function() RDWire.declareChunked(key, { budget = s.budget }) end)
    return s
end

-- ---------------------------------------------------------------------------
-- Splitting
-- ---------------------------------------------------------------------------
--
-- Returns chunks and their individual sizes. Sizes are kept because the pump
-- spends a byte budget, and re-estimating a chunk at send time would walk the
-- same rows a second time for a number already computed here.
-- `each` fields are copied onto EVERY chunk; `tail` only onto the last.
--
-- The distinction is routing versus reporting. A receiver has to know which
-- subject a fragment belongs to before it can start assembling - an inventory
-- chunk with no username cannot be filed - so identity goes on every chunk. A
-- summary that is only meaningful once the whole thing has landed (totals,
-- stats, timestamps) goes on the last, where it costs one copy instead of N.
local function split(s, rows, tail, each)
    rows = rows or {}
    s.gen = s.gen + 1
    local gen = s.gen

    local chunks, sizes = {}, {}
    local slice, sliceEst = {}, 0
    local eachEst = 0
    if type(each) == "table" then
        pcall(function() eachEst = RDWire.estimate(each) end)
    end

    -- Per-chunk fields come out of the ROW budget, not out of thin air. Charging
    -- them only to the reported size would let a fat `each` push every chunk over
    -- the very budget this function exists to hold. Floored well above zero so a
    -- pathological `each` degrades to small chunks rather than to one row each.
    local rowBudget = s.rowBudget - eachEst
    if rowBudget < 64 then rowBudget = 64 end

    local function flush()
        if #slice == 0 then return end
        -- n resolved once: `chunks[#chunks+1] = { seq = #chunks+1 }` would lean
        -- on an evaluation order Lua does not promise.
        local n = #chunks + 1
        local c = { gen = gen, seq = n }
        c[s.field] = slice
        if type(each) == "table" then
            for k, v in pairs(each) do if c[k] == nil then c[k] = v end end
        end
        chunks[n] = c
        -- Per-chunk fields are paid for in EVERY chunk, so they are charged
        -- against the budget rather than assumed to fit in the envelope reserve.
        sizes[n]  = sliceEst + s.envelope + eachEst
        slice, sliceEst = {}, 0
    end

    for i = 1, #rows do
        local row = rows[i]
        -- +8 for the row's own numeric index key, which costs a Double on the
        -- wire and is not part of the row's own estimate.
        local rowEst = 8
        pcall(function() rowEst = RDWire.estimate(row) + 8 end)
        if #slice > 0 and (sliceEst + rowEst > rowBudget or #slice >= s.maxRows) then
            flush()
        end
        slice[#slice + 1] = row
        sliceEst = sliceEst + rowEst
    end
    flush()

    -- An empty result still needs one chunk, or the receiver has nothing to
    -- complete against and waits forever for a stream that already finished.
    if #chunks == 0 then
        local c = { gen = gen, seq = 1 }
        c[s.field] = {}
        if type(each) == "table" then
            for k, v in pairs(each) do if c[k] == nil then c[k] = v end end
        end
        chunks[1] = c
        sizes[1]  = s.envelope + eachEst
    end

    -- total is only knowable once the last row has been placed, so it is
    -- stamped in afterwards rather than computed up front.
    local total = #chunks
    for i = 1, total do chunks[i].total = total end

    -- Caller extras ride on the LAST chunk, so a receiver that shows them does
    -- so on assembly rather than on a fragment.
    if type(tail) == "table" then
        for k, v in pairs(tail) do
            if chunks[total][k] == nil then chunks[total][k] = v end
        end
    end

    return chunks, sizes
end

-- ---------------------------------------------------------------------------
-- Raw splitter, for callers that own their own protocol
-- ---------------------------------------------------------------------------
--
-- NOT EVERY PAGED STREAM WANTS THE MANAGED PATH, and pretending otherwise would
-- have broken a working feature. RDChunk.send takes a COMPLETE collection and
-- supersedes any earlier send of the same key - correct for current-state streams
-- (a snapshot, an inventory, a fleet list) and actively wrong for a PROGRESSIVE
-- one, where the server discovers rows over time and emits them as it goes so the
-- reader can watch the list fill. Superseding there would delete every page but
-- the last.
--
-- So the byte-splitting and the size model are available on their own. A caller
-- keeps its own seq/page/done protocol and its own send calls, and still gets
-- chunks measured against the same model the wire probe judges them by - which is
-- the part that was actually missing.
--
-- Returns an array of row-arrays. Never returns zero slices for a non-empty
-- input; returns zero slices for an empty one, because a caller with its own
-- protocol already knows what an empty page means to it.
function RDChunk.slice(module, command, rows)
    local s = RDChunk.streams[tostring(module) .. ":" .. tostring(command)]
    if not s then
        print("[RFTDCore] RDChunk.slice: stream not declared - " .. tostring(module) .. ":" .. tostring(command))
        return { rows or {} }
    end
    rows = rows or {}
    if #rows == 0 then return {} end

    local out, slice, sliceEst = {}, {}, 0
    for i = 1, #rows do
        local row = rows[i]
        local rowEst = 8
        pcall(function() rowEst = RDWire.estimate(row) + 8 end)
        if #slice > 0 and (sliceEst + rowEst > s.rowBudget or #slice >= s.maxRows) then
            out[#out + 1] = slice
            slice, sliceEst = {}, 0
        end
        slice[#slice + 1] = row
        sliceEst = sliceEst + rowEst
    end
    if #slice > 0 then out[#out + 1] = slice end
    return out
end

-- ---------------------------------------------------------------------------
-- Queueing
-- ---------------------------------------------------------------------------

local function queueKey(player, s)
    local u = "*"
    if player then pcall(function() u = player:getUsername() or "?" end) end
    return u .. "|" .. s.module .. ":" .. s.command
end

local function enqueue(player, s, rows, tail, each)
    local chunks, sizes = split(s, rows, tail, each)
    local qk = queueKey(player, s)

    local entry = RDChunk.index[qk]
    if entry then
        -- Supersede in place. The older generation is stale by definition and the
        -- receiver discards it on gen anyway; draining it would only spend budget
        -- delivering state we already know is wrong.
        entry.chunks, entry.sizes, entry.nextIdx = chunks, sizes, 1
        entry.player = player
        entry.superseded = (entry.superseded or 0) + 1
        return entry
    end

    entry = { key = qk, player = player, stream = s,
              chunks = chunks, sizes = sizes, nextIdx = 1, superseded = 0 }
    RDChunk.index[qk] = entry
    RDChunk.queue[#RDChunk.queue + 1] = entry
    return entry
end

-- Send `rows` to one player as a paged stream. `tail` is an optional table whose
-- fields ride on the final chunk.
function RDChunk.send(player, module, command, rows, tail, each)
    local s = RDChunk.streams[tostring(module) .. ":" .. tostring(command)]
    if not s then
        print("[RFTDCore] RDChunk.send: stream not declared - " .. tostring(module) .. ":" .. tostring(command))
        return false
    end
    if not player then return false end
    enqueue(player, s, rows, tail, each)
    return true
end

-- Broadcast a paged stream to every client. Same pacing, same budget.
function RDChunk.broadcast(module, command, rows, tail, each)
    local s = RDChunk.streams[tostring(module) .. ":" .. tostring(command)]
    if not s then
        print("[RFTDCore] RDChunk.broadcast: stream not declared - " .. tostring(module) .. ":" .. tostring(command))
        return false
    end
    enqueue(nil, s, rows, tail, each)
    return true
end

-- ---------------------------------------------------------------------------
-- Pump
-- ---------------------------------------------------------------------------
--
-- ROUND-ROBIN, one chunk per pending stream per pass, until the tick budget is
-- spent. Plain FIFO would let one large send hold every other stream behind it -
-- a fleet list arriving would delay a zombie delta by however long the fleet
-- takes, which is precisely the coupling paging exists to avoid. Ordering WITHIN
-- a stream is still strict, which is the only ordering a receiver depends on.

local function sendChunk(entry, chunk)
    local s = entry.stream
    if entry.player then
        pcall(sendServerCommand, entry.player, s.module, s.command, chunk)
    else
        pcall(sendServerCommand, s.module, s.command, chunk)
    end
end

local function pump()
    if #RDChunk.queue == 0 then return end
    local spent = 0

    while spent < TICK_BYTES do
        local progressed = false
        local i = 1
        while i <= #RDChunk.queue do
            if spent >= TICK_BYTES then break end
            local e = RDChunk.queue[i]
            local chunk = e.chunks[e.nextIdx]
            if chunk then
                sendChunk(e, chunk)
                spent = spent + (e.sizes[e.nextIdx] or e.stream.budget)
                e.nextIdx = e.nextIdx + 1
                progressed = true
                i = i + 1
            else
                -- Drained. Remove from both the queue and the supersede index, or
                -- the next send for this key would supersede a finished entry that
                -- the pump will never look at again.
                RDChunk.index[e.key] = nil
                table.remove(RDChunk.queue, i)
            end
        end
        if not progressed then return end
    end
end

Events.OnTick.Add(function() pcall(pump) end)

-- Depth, for a diagnostic report. Cheap enough to call from one.
function RDChunk.pending()
    local n, chunks = 0, 0
    for _, e in ipairs(RDChunk.queue) do
        n = n + 1
        chunks = chunks + (#e.chunks - e.nextIdx + 1)
    end
    return n, chunks
end

return RDChunk

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
