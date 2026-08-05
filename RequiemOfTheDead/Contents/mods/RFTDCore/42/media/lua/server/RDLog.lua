-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDLog.lua - the family's two-tier logging engine (server only).
--
-- Two tiers, two functions, NOT one function with a flag:
--
--   CHRONICLE  permanent per-subject record. Never rotated. Volume is bounded
--              by the closed event enum (RDEvents) - an unregistered event is
--              REJECTED, so a chatty producer physically cannot write to a
--              permanent stream. Open-append-close per line: rare and
--              irreplaceable, so every line is flushed the moment it exists.
--
--   FORENSIC   bounded ring for high-volume telemetry ("what happened last
--              Tuesday"). Rotates; volume is bounded by segment size x ring
--              length, not by discipline. Buffered (<=25 lines or ~1s) because
--              the traffic is continuous and replaceable. Segments roll on
--              BYTES or lines, whichever trips first - see flushStream for why
--              a line count alone never bounded the disk.
--
-- Durability model: nothing here may depend on a graceful exit. The restart
-- scripts force-kill java (documented data-loss history), and while the
-- production dedi saves every 30 minutes, the local/test setup runs with
-- SaveWorldEveryMinutes=0 - so engine-save cadence is environment-dependent
-- and these files never rely on it. Chronicle lines are durable per line.
-- Forensic loses at
-- most one buffer (<=25 lines / <=1s). head.txt is rewritten every 500 lines,
-- so after a force-kill the line counter can be <=500 lines stale and a
-- segment runs slightly long or short. THAT IS ACCEPTABLE - do not "fix" it
-- with a boot-time full-file line count; that is an O(20k) Kahlua read per
-- stream on the tick thread.
--
-- Rotation without a delete primitive: PZ Lua cannot delete files, but
-- getFileWriter(path, createIfNull, false) truncates to zero bytes - that IS
-- the reclaim. Ring of RING segments x SEG_LINES lines, line-counted (Lua has
-- no stat). Existence probing would use cacheFileExists (roots at
-- cacheDir/Lua/); fileExists and serverFileExists root elsewhere.
--
-- 42.20 WRITE-EXTENSION ALLOWLIST - why these files are named ".jsonl.log":
-- getFileWriter returns nil unless the extension is in
-- Set.of("ini","cfg","txt","log") (LuaManager.java:9884, gate at :5514; the set
-- does not exist in 42.19.1). getFileExtension() takes the substring after the
-- LAST dot, so "events.jsonl.log" presents as "log" and passes while the name
-- still declares its real format. This was NOT a cosmetic choice: it is the
-- only route that keeps append=true, and the chronicle's per-line durability
-- depends on appending. getFileOutput() is ungated but cannot append at all
-- (no append arg - it truncates every open) and parks its stream in a single
-- private static field, so it is one file process-wide; getModFileWriter is
-- ungated but roots inside the mod dir, which is replaced on every update.
-- The check is CASE-SENSITIVE and unlowercased: ".LOG" fails. Extensionless
-- names fail too. Only the final path segment is inspected, so the dots in a
-- "<SafeName>.<SteamID>" DIRECTORY are irrelevant.
-- Reads are NOT gated - getFileReader still opens the pre-42.20 ".jsonl"
-- files, which is why nothing here migrates them: they stay on disk as
-- immutable history and a reader concatenates legacy-then-current. Lua cannot
-- rename or delete, and truncating them is impossible anyway now that their
-- extension is refused.
--
-- Layout (under <cacheDir>/Lua/). Every player owns ONE directory per season
-- (<SafeName>.<SteamID>, see RDIdentity) holding their permanent record and
-- their derived-state index side by side:
--   RFTD/season/<SeasonName>/chronicle/p/<Name.SID>/events.jsonl.log  permanent
--   RFTD/season/<SeasonName>/chronicle/p/<Name.SID>/index.json.txt    rewritten
--   RFTD/season/<SeasonName>/chronicle/world.jsonl.log                server scope
--   RFTD/forensic/<stream>/head.txt                    "<segment> <lines> <bytes>"
--   RFTD/forensic/<stream>/000.<stream>.jsonl.log ..         ring segments
--     e.g. forensic/guardian/000.guardian.jsonl.log - the name repeats the
--     stream so a segment stays identifiable once copied out of its folder.
--
-- The trailing ".log"/".txt" is forced by the 42.20 allowlist (see below).
-- ".log" marks an append-only stream, ".txt" a file rewritten in place.
--
-- Envelope (one JSON object per line, keys sorted by RDJson):
--   {"v":2,"t":<epoch>,"d":<gameDay>,"s":"<seasonName>","e":"<NS.EVENT>",
--    "m":"<producing mod>","u":"<user>","l":"<lifeId|null>","x":{...payload}}
--
-- Payload nests under "x" so caller keys can never clash with the envelope.

if not isServer() then return end

-- Explicit, because the line below is a FILE-SCOPE read of an RD* global and the
-- family rule since the 42.19 boot-log crashes is that those are declared, never
-- assumed. "RDLog.lua" happens to sort after "RDShared.lua", so this survived on
-- luck; it is also now pulled in earlier than the directory walk would, via
-- RDGuardian -> RDMeter -> here. Safe below the isServer() guard, which has
-- already returned on the client where this file self-aborts.
require "RDShared"

RDLog = RDLog or {}

local DIR = RDShared.DIR

-- ---------------------------------------------------------------------------
-- Config (sandbox-tunable; read lazily so SandboxVars is ready)
-- ---------------------------------------------------------------------------

local function cfgNum(key, default)
    local ok, v = pcall(function() return SandboxVars.RFTDCore and SandboxVars.RFTDCore[key] end)
    if ok and type(v) == "number" and v > 0 then return v end
    return default
end

local HEAD_SYNC_LINES = 500

-- ---------------------------------------------------------------------------
-- Low-level file helpers (every touch pcall-wrapped; a logging fault must
-- never disturb the caller)
-- ---------------------------------------------------------------------------

local function appendLine(path, line)
    local ok = pcall(function()
        local w = getFileWriter(path, true, true)
        if w then w:write(line .. "\n"); w:close() end
    end)
    return ok
end

local function appendMany(path, lines)
    pcall(function()
        local w = getFileWriter(path, true, true)
        if w then
            for i = 1, #lines do w:write(lines[i] .. "\n") end
            w:close()
        end
    end)
end

local function rewrite(path, content)
    pcall(function()
        local w = getFileWriter(path, true, false)   -- truncate: the only "delete"
        if w then w:write(content); w:close() end
    end)
end

local function readFirstLine(path)
    local line
    pcall(function()
        local r = getFileReader(path, false)
        if r then line = r:readLine(); r:close() end
    end)
    return line
end

-- Stream/segment names must stay path-safe; ".." is refused by the engine but
-- never produce one anyway.
local function safePath(s)
    s = tostring(s or "misc"):gsub("%.%.", "_"):gsub("[^%w%-_/]", "_")
    if s == "" then s = "misc" end
    return s
end

-- ---------------------------------------------------------------------------
-- Envelope
-- ---------------------------------------------------------------------------

local function usernameOf(subj)
    if type(subj) == "string" then return subj end
    if subj ~= nil then
        local ok, name = pcall(function() return subj:getUsername() end)
        if ok and name then return tostring(name) end
    end
    return nil
end

local function lifeIdOf(subj)
    if type(subj) ~= "table" and type(subj) ~= "userdata" then return nil end
    local ok, id = pcall(function()
        local md = subj:getModData()
        return md and md.RFTD_LifeId
    end)
    if ok and id then return tostring(id) end
    return nil
end

local function envelope(evt, modId, subj, payload)
    return RDJson.encode({
        v = RDEvents.SCHEMA_V,
        t = RDShared.nowSec(),
        d = RDShared.gameDay(),
        s = RDSeasonServer.current(),
        e = tostring(evt),
        m = modId,
        u = usernameOf(subj),
        l = lifeIdOf(subj),
        x = payload or {},
    })
end

-- ---------------------------------------------------------------------------
-- CHRONICLE
-- ---------------------------------------------------------------------------

local function chroniclePath(seasonId, def, subj)
    if def.scope == "w" then
        return DIR .. "season/" .. seasonId .. "/chronicle/world" .. RDShared.EXT_STREAM
    end
    return DIR .. "season/" .. seasonId .. "/chronicle/p/" .. RDIdentity.dirFor(subj)
        .. "/events" .. RDShared.EXT_STREAM
end

-- Write one chronicle record for the CURRENT season. Returns true on accept.
-- evt must be registered in RDEvents; subj is an IsoPlayer, a username string,
-- or nil for world-scope events.
function RDLog.chronicle(evt, subj, payload)
    local def, modId = RDEvents.get(evt)
    if not def then
        print("[RFTDCore] RDLog.chronicle REJECTED unregistered event '" .. tostring(evt) .. "'")
        return false
    end
    for _, key in ipairs(def.req or {}) do
        if payload == nil or payload[key] == nil then
            print("[RFTDCore] RDLog.chronicle: " .. tostring(evt) .. " missing required key '" .. key .. "'")
        end
    end
    RDLog.flush()   -- forensic buffers drain before any permanent write
    RDSeasonServer.ensure()
    local line = envelope(evt, modId, subj, payload)
    return appendLine(chroniclePath(RDSeasonServer.current(), def, subj), line)
end

-- Season bookkeeping needs to write world events into a season OTHER than the
-- current one (closing out the previous season at roll time). Not for general use.
function RDLog.chronicleInto(seasonId, evt, subj, payload)
    local def, modId = RDEvents.get(evt)
    if not def then return false end
    local line = envelope(evt, modId, subj, payload)
    return appendLine(chroniclePath(safePath(seasonId), def, subj), line)
end

-- Derived current-state snapshot, one JSON file per player, rewritten in
-- place. Convenience for ticket lookups ("what does this player have right
-- now") - always rebuildable from the chronicle, never authoritative.
function RDLog.state(subj, tbl)
    if not usernameOf(subj) then return end
    RDSeasonServer.ensure()
    local path = DIR .. "season/" .. RDSeasonServer.current()
        .. "/chronicle/p/" .. RDIdentity.dirFor(subj) .. "/index" .. RDShared.EXT_DOC
    rewrite(path, RDJson.encode(tbl or {}) .. "\n")
end

-- ---------------------------------------------------------------------------
-- FORENSIC ring
-- ---------------------------------------------------------------------------

local streams = {}   -- name -> { seg, lines, buf, lastMs, headDirty, loaded }

-- "000.guardian.jsonl.log", not the old bare "000.jsonl.log". The stream name was
-- only ever carried by the parent DIRECTORY, so a segment copied out of its folder
-- - dragged into a ticket, mailed to someone, opened in an editor - was an
-- anonymous "000". Self-describing filenames cost nothing and survive being moved.
--
-- THE EXTENSION IS NOT NEGOTIABLE: ".jsonl" alone is REFUSED since 42.20, which
-- allows only ini/cfg/txt/log and reads the substring after the LAST dot. So the
-- name declares its real format in the middle and presents "log" at the end.
-- "000.guardian.jsonl" would silently return nil from getFileWriter and write
-- nothing at all.
--
-- MIGRATION, which needs no code: existing streams have a head.txt naming an
-- OLD-style segment. The boot probe below (cacheFileExists on this path) will not
-- find it, so the ring resets to 0/0 and rewrites head - exactly the self-healing
-- path already built for the 42.20 outage. Old "000.jsonl.log" files stay on disk
-- as immutable history; Lua cannot delete or rename them, and the ring will never
-- reclaim them, so they are a one-time orphan per stream. Readers wanting full
-- history concatenate old-then-new.
local function segPath(name, seg)
    return DIR .. "forensic/" .. name .. "/"
        .. string.format("%03d", seg) .. "." .. name .. RDShared.EXT_STREAM
end

local function headPath(name)
    return DIR .. "forensic/" .. name .. "/head.txt"
end

-- "<seg> <lines> <bytes>". The third field is an EXTENSION: pre-2026-08-02 heads
-- carry only two, parse fine, and resume with bytes=0 - which under-counts the
-- current segment exactly once, then self-corrects at the next rotation. Do not
-- "fix" that by measuring the file; there is no stat and a read is O(segment).
local function writeHead(st, name)
    rewrite(headPath(name),
        tostring(st.seg) .. " " .. tostring(st.lines) .. " " .. tostring(st.bytes) .. "\n")
    st.headDirty = 0
end

-- Reclaim segments that fell OUTSIDE the ring, which nothing else can do.
-- `seg = (seg + 1) % ring` only ever visits 0..ring-1, so lowering
-- ForensicRingSegments (8 -> 4) strands 004..007 holding their bytes forever -
-- the ring silently stops bounding the thing it exists to bound. Truncation is
-- the only reclaim Lua has, so walk the directory once per stream per boot and
-- zero anything at or above the current ring size.
--
-- Filenames are matched by EXACT reconstruction rather than a pattern: safePath
-- allows "-", which is a magic character in a Lua pattern class, so a stream
-- named "a-b" would build a broken matcher. Rebuilding the expected name and
-- comparing strings has no such failure mode and cannot match head.txt or a
-- legacy ".jsonl" orphan by accident.
local function reclaimOutsideRing(name, ring)
    pcall(function()
        local files = listFilesInZomboidLuaDirectory(DIR .. "forensic/" .. name)
        if not files then return end
        local n = files:size()
        for i = 0, n - 1 do
            local f = files:get(i)
            if f then
                f = tostring(f)
                local num = f:match("^(%d+)%.")
                local seg = tonumber(num)
                if seg and seg >= ring
                   and f == string.format("%03d", seg) .. "." .. name .. RDShared.EXT_STREAM then
                    rewrite(DIR .. "forensic/" .. name .. "/" .. f, "")
                end
            end
        end
    end)
end

local function stream(name)
    name = safePath(name)
    local st = streams[name]
    if st then return st, name end
    st = { seg = 0, lines = 0, bytes = 0, buf = {}, lastMs = 0, headDirty = 0 }
    local head = readFirstLine(headPath(name))
    if head then
        local seg, lines, bytes = head:match("^(%d+)%s+(%d+)%s*(%d*)")
        if seg then
            st.seg   = tonumber(seg) or 0
            st.lines = tonumber(lines) or 0
            st.bytes = tonumber(bytes) or 0
            -- head.txt can describe a segment that does not exist, and the 42.20
            -- allowlist outage is exactly how: head.txt is ".txt" so it stayed
            -- writable while every ".jsonl" segment write returned nil, leaving
            -- the counter advancing over records that never landed. A pre-42.20
            -- head also points at the old ".jsonl" segment names. Either way the
            -- counter is not describing the file it names, so trust the disk and
            -- restart the ring rather than resuming at a fabricated offset.
            -- Probed once per stream per boot, and only when a head exists - a
            -- fresh install never gets here. cacheFileExists roots at
            -- cacheDir/Lua/, the same root these paths are relative to.
            local ok, exists = pcall(function() return cacheFileExists(segPath(name, st.seg)) end)
            if not ok or exists ~= true then
                st.seg, st.lines, st.bytes = 0, 0, 0
                st.headDirty = HEAD_SYNC_LINES   -- force a rewrite so disk stops lying
            end
        end
    end
    -- A head written under a LARGER ring can name a segment outside the current
    -- one. Left alone the stream would keep appending to it until it filled, then
    -- wrap inside the ring and never return - so the file it was writing becomes
    -- an orphan holding a full segment. Clamp before any write happens.
    local ring = cfgNum("ForensicRingSegments", 8)
    if st.seg >= ring then
        st.seg, st.lines, st.bytes = 0, 0, 0
        st.headDirty = HEAD_SYNC_LINES
    end
    reclaimOutsideRing(name, ring)
    streams[name] = st
    return st, name
end

-- Rotate on LINES OR BYTES, whichever trips first.
--
-- Lines alone never bounded the thing that actually fills a disk. Record size
-- across these streams spans more than an order of magnitude - a legacyLine is a
-- couple of hundred bytes, an RD.WIRE_TOP envelope carrying its full row list is
-- kilobytes - so one "20000 lines" segment is 4 MB for one stream and 30+ MB for
-- another, and the operator setting it cannot tell which they are getting. The
-- 2026-08-02 wire capture averaged ~900 B/line at topN=12; raising topN to 25 the
-- same day roughly doubled it, silently doubling the ring's disk footprint
-- without touching the setting that supposedly governs it. Bytes are the resource,
-- so bytes get a bound; the line cap stays as a secondary guard.
--
-- Counted, not measured: `#s` is bytes in Lua 5.1 (and Kahlua), so the buffer is
-- summed as it is written. There is no stat call and reading the file back to
-- size it would be O(segment) on the tick thread.
local function flushStream(st, name)
    if #st.buf == 0 then return end
    local ring  = cfgNum("ForensicRingSegments", 8)
    local segLn = cfgNum("ForensicSegmentLines", 20000)
    local segBy = cfgNum("ForensicSegmentKB", 4096) * 1024

    local added = 0
    for i = 1, #st.buf do added = added + #st.buf[i] + 1 end   -- +1 = the newline

    appendMany(segPath(name, st.seg), st.buf)
    st.lines     = st.lines + #st.buf
    st.bytes     = st.bytes + added
    st.headDirty = st.headDirty + #st.buf
    st.buf       = {}
    st.lastMs    = RDShared.nowMs()

    if st.lines >= segLn or st.bytes >= segBy then
        st.seg   = (st.seg + 1) % ring
        st.lines = 0
        st.bytes = 0
        rewrite(segPath(name, st.seg), "")   -- truncate-to-zero IS the reclaim
        writeHead(st, name)
    elseif st.headDirty >= HEAD_SYNC_LINES then
        writeHead(st, name)
    end
end

local BUF_MAX = 25

local function push(name, line)
    local st, safe = stream(name)
    st.buf[#st.buf + 1] = line
    if #st.buf >= BUF_MAX then flushStream(st, safe) end
end

-- High-volume telemetry. evt is free-form (namespaced "NS.NAME" by
-- convention); no enum gate - the ring bounds the volume instead.
-- modId names the PRODUCING mod, the envelope's "m". Chronicle gets it free from
-- RDEvents.get(evt) because that enum is closed and knows who registered each
-- event; forensic events are deliberately outside it, so the producer has to say.
-- It was hardcoded "?" here, which meant every forensic record in the family - not
-- just Guardian's - shipped an empty attribution field. Optional so an unconverted
-- caller degrades to the old behaviour rather than erroring.
function RDLog.forensic(streamName, evt, subj, payload, modId)
    push(streamName, envelope(evt, modId or "?", subj, payload))
end

-- Escape hatch for consolidating pre-Core writers incrementally: reroute an
-- existing logger's already-formatted line into a ring stream in one call,
-- keeping its current format. Reformatting to envelopes is a later,
-- separately verifiable step.
function RDLog.legacyLine(streamName, str)
    push(streamName, tostring(str))
end

-- Drain every stream buffer to disk. Called on the 1s tick throttle, every
-- minute, before any chronicle write, and by anything about to read the ring.
function RDLog.flush()
    for name, st in pairs(streams) do
        flushStream(st, name)
    end
end

-- ---------------------------------------------------------------------------
-- Flush cadence: OnTick throttled to ~1s (the only event proven to fire
-- server-side), plus EveryOneMinute as belt-and-braces.
-- ---------------------------------------------------------------------------

local lastTickMs = 0
Events.OnTick.Add(function()
    local now = RDShared.nowMs()
    if now - lastTickMs < 1000 then return end
    lastTickMs = now
    RDLog.flush()
end)

Events.EveryOneMinute.Add(function()
    RDLog.flush()
end)

return RDLog

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
