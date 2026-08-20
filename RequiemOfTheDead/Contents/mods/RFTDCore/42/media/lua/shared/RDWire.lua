-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDWire.lua - estimate the serialized size of a network payload (both sides).
--
-- Absorbed from OmenSpyNetwork's OSNSizer. OSN stays published and standalone
-- with its own users; this is the same absorption Guardian got, for the same
-- reason - the family wants the capability permanently, not as a drop-in probe.
--
-- WHY AN ESTIMATE AND NOT A MEASUREMENT: there is no engine API for true wire
-- bytes. TableNetworkUtils exposes zero @LuaMethod and the ByteBuffer is never
-- handed to Lua, so the only option is to model the wire format and walk the
-- table ourselves:
--
--   string  #s + 2   (length-prefixed UTF)
--   number  8        (Double, always - Kahlua has no integer subtype)
--   boolean 1
--   table   1 marker + contents
--   other   0        (functions/userdata are stripped before send)
--
-- This RANKS offenders. It is never exact and must never be reported as though
-- it were - every consumer calls the field "est", not "bytes".
--
-- BOUNDED, and this matters more here than it looks. OSN's walker was depth-
-- capped and cycle-safe but had no node budget, so sizing one enormous flat
-- blob meant walking every key of it on every single transmit - the probe
-- becomes the accomplice of the bandwidth hog it exists to find. A budget fixes
-- that, and blowing the budget is itself the signal: a payload too big to
-- measure is reported partial=true, which is exactly the alert an operator
-- wants. Under-reporting bytes would have hidden it.
--
-- Engine-free by construction: pcall, pairs, type and nothing else. That is
-- deliberate - it means tools/run-tests.bat exercises this under real Lua 5.1
-- with no stubs. Keep it that way; sandbox reads belong in RDMeter.

RDWire = RDWire or {}

RDWire.DEPTH_CAP    = 8       -- matches the wire serializer's own nesting limit
RDWire.NODE_BUDGET  = 20000   -- stop walking; report partial rather than stall a send

local function cost(v, depth, seen, budget)
    local t = type(v)
    if t == "string"  then return #v + 2 end
    if t == "number"  then return 8 end
    if t == "boolean" then return 1 end
    if t ~= "table"   then return 0 end

    if depth >= RDWire.DEPTH_CAP then return 1 end
    if seen[v] then return 1 end   -- cycle guard

    seen[v] = true
    local total = 1                -- table marker
    for k, val in pairs(v) do      -- pairs(), NOT next(): B42's Kahlua has no next global
        budget.n = budget.n - 2
        if budget.n <= 0 then
            budget.partial = true
            break
        end
        total = total + cost(k, depth + 1, seen, budget)
                      + cost(val, depth + 1, seen, budget)
    end
    -- Path-scoped, like RDJson's: the same table twice as siblings is a DAG,
    -- not a cycle, and both instances really do cost bytes on the wire.
    seen[v] = nil
    return total
end

-- estimate(args) -> approxBytes, partial
-- partial=true means the node budget ran out, so approxBytes is a floor rather
-- than an estimate - treat it as "at least this big". `cost` is this module's
-- own Lua walker over an already-table payload; its depth, cycle, and node
-- limits are the recovery for pathological shape. Do not hide an unexpected
-- walker fault by pretending the payload cost zero bytes.
function RDWire.estimate(args)
    if type(args) ~= "table" then return 0, false end
    local budget = { n = RDWire.NODE_BUDGET, partial = false }
    local n = cost(args, 0, {}, budget)
    return n, budget.partial
end

-- ---------------------------------------------------------------------------
-- Chunk declarations - telling correct paging apart from an unsplit blob.
--
-- WHY SIZE ALONE CANNOT DECIDE THIS, which is the mistake this section exists to
-- correct: a 26 KB payload and a 26 KB *chunk* of a paged stream are the same
-- number to a size probe, and the two need opposite fixes. "Unsplit" means go
-- wire a chunker. "Chunk over budget" means the chunker is already running and
-- its budget is wrong - usually one constant. A reader told "the chunker is not
-- running" about the second case goes looking for something that is already
-- there, which is exactly what happened to RFTDReaper's SnapshotChunk: paging
-- correctly into 21 chunks per snapshot, every chunk 26 KB, reported as no
-- chunker at all.
--
-- `partial` IS NOT THAT SIGNAL and must never be read as one. It means this
-- file's own node budget ran out mid-walk. A correctly-paged stream reports
-- partial=false on every chunk forever, and so does an unsplit blob small enough
-- to finish measuring. Anything keying "was it split?" off partial is reading a
-- constant and calling it a measurement.
--
-- Two ways a key becomes known-paged:
--   DECLARED  the emitter called declareChunked and supplied its own per-chunk
--             budget. Authoritative, and that budget is what breaches are judged
--             against - a stream may legitimately want chunks larger or smaller
--             than the consumer's general oversize limit.
--   IMPLIED   the payload carries seq/total. Costs an emitter nothing and catches
--             paged streams that never declared, but carries no budget, so
--             breaches fall back to the limit the caller passed in.
--
-- Declarations are per-side: each side loads its own copy of this file, so an
-- emitter declares on the side it sends from. The registry hangs off the table
-- rather than a file local so a second require cannot silently empty it.
-- ---------------------------------------------------------------------------

RDWire.CHUNK_BUDGET_DEFAULT = 4096

RDWire._chunks = RDWire._chunks or {}   -- "Module:Command" -> { budget = bytes }

-- Declare a key as a paged stream. `key` is the same "Module:Command" string the
-- meters aggregate under. Returns the resolved budget.
function RDWire.declareChunked(key, opts)
    if type(key) ~= "string" then return nil end
    if type(opts) ~= "table" then opts = {} end
    local budget = opts.budget
    if type(budget) ~= "number" or budget <= 0 then
        budget = RDWire.CHUNK_BUDGET_DEFAULT
    end
    RDWire._chunks[key] = { budget = budget }
    return budget
end

function RDWire.chunkDeclaration(key)
    if type(key) ~= "string" then return nil end
    return RDWire._chunks[key]
end

-- The seq/total convention. Deliberately strict - seq and total must both be
-- numbers and describe a coherent position - so an unrelated payload that
-- happens to carry a field called `total` is not mistaken for a chunk.
function RDWire.chunkMarkers(args)
    if type(args) ~= "table" then return nil, nil end
    local seq, total = args.seq, args.total
    if type(seq) ~= "number" or type(total) ~= "number" then return nil, nil end
    if seq < 1 or total < 1 or seq > total then return nil, nil end
    return seq, total
end

-- classify(key, est, partial, args, limit) -> verdict table, never nil:
--   chunked  "declared" | "implied" | "no"
--   budget   the declared per-chunk budget, when there is one
--   ceiling  what this payload was actually judged against
--   seq/total   position in the stream, when the payload carries it
--   streamStart true on seq == 1, so a consumer can count streams not just chunks
--   over     true when the payload breached its ceiling
--   reason   nil when fine, else:
--     "unmeasurable"   the size walk ran out of budget; est is a floor
--     "chunk-oversize" a paged stream whose chunks are too big - fix the budget
--     "unsplit"        a single large payload with no paging - fix by chunking
--
-- `limit` is the caller's general oversize threshold. Passed in rather than read
-- here because thresholds are policy and this file holds none - it stays free of
-- sandbox reads so the pure-Lua test path keeps working with zero stubs.
function RDWire.classify(key, est, partial, args, limit)
    if type(est) ~= "number" then est = 0 end
    if type(limit) ~= "number" or limit <= 0 then limit = RDWire.CHUNK_BUDGET_DEFAULT end

    local seq, total = RDWire.chunkMarkers(args)
    local decl = RDWire.chunkDeclaration(key)

    local v = {
        est         = est,
        seq         = seq,
        total       = total,
        chunked     = (decl and "declared") or (seq and "implied") or "no",
        budget      = decl and decl.budget or nil,
        streamStart = (seq == 1) or nil,
    }

    -- Too big to finish measuring outranks everything: est is a floor, so any
    -- comparison below it would be answering a question we cannot see.
    if partial then
        v.over    = true
        v.reason  = "unmeasurable"
        v.ceiling = v.budget or limit
        return v
    end

    local ceiling = v.budget or limit
    v.ceiling = ceiling
    if est > ceiling then
        v.over   = true
        v.reason = (v.chunked ~= "no") and "chunk-oversize" or "unsplit"
    end
    return v
end

-- sendClientCommand / sendServerCommand are overloaded with an OPTIONAL leading
-- player argument. The (module, command, args) form has a string first; the
-- (player, module, command, args) form does not.
function RDWire.parseSend(a1, a2, a3, a4)
    if type(a1) == "string" then return a1, a2, a3 end
    return a2, a3, a4
end

-- The size a command costs beyond its payload: both name strings plus framing.
function RDWire.commandEstimate(module, command, args)
    local est, partial = RDWire.estimate(args)
    return est + #tostring(module) + #tostring(command) + 3, partial
end

return RDWire

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
