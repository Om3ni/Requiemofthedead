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
--              Tuesday"). Rotates ON THE WALL CLOCK - one segment per period,
--              4 h by default - so the ring holds `ring x period` of history
--              (42 x 4 h = one week at the defaults) regardless of traffic
--              shape. Buffered (<=25 lines or ~1s) because the traffic is
--              continuous and replaceable. Size settings are per-segment
--              CEILINGS, not triggers; see the segment clock below for why
--              accumulated counters could not do this job.
--
-- Durability model: nothing here may depend on a graceful exit. The restart
-- scripts force-kill java (documented data-loss history), and while the
-- production dedi saves every 30 minutes, the local/test setup runs with
-- SaveWorldEveryMinutes=0 - so engine-save cadence is environment-dependent
-- and these files never rely on it. Chronicle lines are durable per line.
-- Forensic loses at most one buffer (<=25 lines / <=1s).
--
-- A force-kill CANNOT move a segment boundary or lose the ring's place: the
-- segment is a pure function of the clock (see the segment clock below), so it
-- survives by being recomputed rather than by being saved. Only the advisory
-- lines/bytes counters can go stale (<=500 lines), which slightly softens the
-- ceilings and nothing else. Do NOT "fix" that with a boot-time full-file line
-- count; that is an O(20k) Kahlua read per stream on the tick thread.
--
-- Rotation without a delete primitive: PZ Lua cannot delete files, but
-- getFileWriter(path, createIfNull, false) truncates to zero bytes - that IS
-- the reclaim, and it happens exactly once per segment, at the moment the ring
-- wraps back onto it. Ring of RING segments, one per time period. Existence
-- probing would use cacheFileExists (roots at cacheDir/Lua/); fileExists and
-- serverFileExists root elsewhere.
--
-- 42.20 WRITE-EXTENSION ALLOWLIST - why these files are named ".jsonl.log":
-- getFileWriter returns nil unless the extension is in the allowlist
-- (LuaManager gate; the set does not exist in 42.19.1). As of the 42.20.2
-- hotfix the set is Set.of("ini","cfg","txt","log","json") - "json" was ADDED
-- BACK (LuaManager.java:1045, gate at :5526, verified in the decompile). That
-- does NOT reopen ".jsonl": getFileExtension() takes the substring after the
-- LAST dot, so "events.jsonl" presents as "jsonl", and "jsonl" is not "json".
-- Renaming segments to ".json" would work but would orphan every current
-- segment a second time (Lua cannot rename or delete), for a purely cosmetic
-- win - so the names STAY ".jsonl.log", which passes as "log" while still
-- declaring the real format in the middle. This was NOT a cosmetic choice: it
-- is the only route that keeps append=true, and the chronicle's per-line
-- durability depends on appending. getFileOutput() is ungated but cannot
-- append at all (no append arg - it truncates every open) and parks its stream
-- in a single private static field, so it is one file process-wide;
-- getModFileWriter is ungated but roots inside the mod dir, which is replaced
-- on every update. The check is CASE-SENSITIVE and unlowercased: ".LOG" fails.
-- Extensionless names fail too. Only the final path segment is inspected, so
-- the dots in a "<SafeName>.<SteamID>" DIRECTORY are irrelevant.
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
--   RFTD/forensic/<stream>/head.txt        "<segment> <lines> <bytes> <bucket>"
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
-- THE SEGMENT CLOCK - why rotation is a function of the wall clock and nothing
-- else (2026-08-05).
--
-- Rotation used to trigger on accumulated lines/bytes. Both counters live in
-- the `streams` table, which is a file-scope Lua local, so BOTH RESET TO ZERO
-- ON EVERY BOOT while the file they describe keeps appending. Measured on the
-- live remote server: 1553 lines / 2.26 MB of wire telemetry over 19.5 h, but
-- the longest single uninterrupted run contributed only 414 lines / 0.62 MB.
-- The gates were 20000 lines and 4 MB, so ONE boot would have had to run ~22 h
-- to rotate on bytes and ~7 days to rotate on lines. Neither gate was ever
-- reachable, head.txt was never written on any stream on any server, and the
-- segment grew without bound. The ring had never rotated once, anywhere.
--
-- So the segment index is now DERIVED, not accumulated:
--
--     bucket = floor(epochSeconds / periodSeconds)
--     seg    = bucket % ring
--
-- Nothing carries across a restart, because nothing needs to: two processes
-- asking the same question at the same moment get the same answer. A crash, a
-- force-kill, a counter reset - none of them can move the boundary. "A new log
-- every four hours" is then true by construction rather than by bookkeeping,
-- and any timestamp can be mapped straight to the file that holds it.
--
-- Boundaries are ABSOLUTE, not relative to boot: with the 4 h default they
-- land on 00:00, 04:00, 08:00, ... UTC, so segments line up across streams and
-- across servers instead of drifting with each restart.
--
-- head.txt survives as bookkeeping only - it says which BUCKET the segment on
-- disk holds, which is what distinguishes "same period, resume appending" from
-- "a full ring ago, truncate first". Position no longer depends on it.
local function periodSec()
    local h = cfgNum("ForensicSegmentHours", 4)
    if h < 1 then h = 1 elseif h > 24 then h = 24 end
    return math.floor(h * 3600)
end

-- nil when the clock is unavailable - callers then leave the segment alone
-- rather than guessing. Fail-safe: an unreadable clock must not rotate, and
-- must never truncate.
local function bucketNow()
    local now = RDShared.nowSec()
    if type(now) ~= "number" or now <= 0 then return nil end
    return math.floor(now / periodSec())
end

-- ---------------------------------------------------------------------------
-- Low-level file helpers (every touch pcall-wrapped; a logging fault must
-- never disturb the caller)
--
-- A REFUSED WRITER IS REPORTED, NOT SWALLOWED (2026-08-07). Every helper here
-- used to treat `getFileWriter(...) == nil` as success: the pcall completed, so
-- `ok` was true, and the record simply ceased to exist. That is the exact shape
-- of the 42.20 allowlist outage - every ".jsonl" write silently returned nil
-- for days while head.txt (".txt", still allowed) kept advancing - and nothing
-- anywhere printed a single line about it. A logging system whose own failure
-- is invisible cannot be trusted about anything else, so: the failure count is
-- kept, and the FIRST failure per file extension prints loudly to the console.
-- Per extension rather than per path, because the plausible causes (allowlist
-- change, case regression) bite whole extensions at a time, and per-path would
-- print thousands of lines for one cause.
-- ---------------------------------------------------------------------------

local writeFailCount = 0
local writeFailSaid  = {}   -- extension -> true, printed once each

local function reportRefused(path)
    writeFailCount = writeFailCount + 1
    local ext = tostring(path):match("%.([^%./\\]+)$") or "(none)"
    if not writeFailSaid[ext] then
        writeFailSaid[ext] = true
        print("[RFTDCore] RDLog CRITICAL: getFileWriter refused '" .. tostring(path)
            .. "' - every write to a ." .. ext .. " file is being DROPPED."
            .. " The engine's write-extension allowlist has probably changed"
            .. " (42.20.2 allows ini/cfg/txt/log/json). Records are lost until"
            .. " this is fixed; the failure count is in RDLog.writeFailures().")
    end
end

-- How many writes the engine has refused since boot. Zero is the only good
-- answer; anything else means records are being dropped RIGHT NOW.
function RDLog.writeFailures() return writeFailCount end

local function appendLine(path, line)
    local wrote = false
    pcall(function()
        local w = getFileWriter(path, true, true)
        if w then w:write(line .. "\n"); w:close(); wrote = true end
    end)
    if not wrote then reportRefused(path) end
    return wrote
end

local function appendMany(path, lines)
    local wrote = false
    pcall(function()
        local w = getFileWriter(path, true, true)
        if w then
            for i = 1, #lines do w:write(lines[i] .. "\n") end
            w:close()
            wrote = true
        end
    end)
    if not wrote then reportRefused(path) end
    return wrote
end

local function rewrite(path, content)
    local wrote = false
    pcall(function()
        local w = getFileWriter(path, true, false)   -- truncate: the only "delete"
        if w then w:write(content); w:close(); wrote = true end
    end)
    if not wrote then reportRefused(path) end
    return wrote
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

-- "<seg> <lines> <bytes> <bucket>". Fields have only ever been APPENDED, and
-- every historical shape still loads: two-field heads (pre-2026-08-02) resume
-- with bytes=0, three-field heads (pre-2026-08-05) resume with no bucket, which
-- reads as "unknown period" and costs one truncation of the current partial
-- segment. Parsed by scanning for integers rather than by a positional pattern,
-- so a missing trailing field cannot silently shift the others.
--
-- The BUCKET is the load-bearing field now. lines/bytes are advisory: they feed
-- the ceilings below and may be up to HEAD_SYNC_LINES stale after a force-kill.
-- Do not "fix" that staleness by measuring the file; there is no stat and a read
-- is O(segment) on the tick thread.
local function writeHead(st, name)
    rewrite(headPath(name),
        tostring(st.seg) .. " " .. tostring(st.lines) .. " " .. tostring(st.bytes)
        .. " " .. tostring(st.bucket or 0) .. "\n")
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
    st = { seg = 0, lines = 0, bytes = 0, bucket = nil,
           buf = {}, lastMs = 0, headDirty = 0, over = false, fresh = false }

    local head = readFirstLine(headPath(name))
    if head then
        -- Scan for integers rather than matching positionally, so a two-, three-
        -- or four-field head all load correctly and a missing trailing field
        -- cannot shift the ones before it.
        local n = {}
        for d in head:gmatch("%d+") do n[#n + 1] = tonumber(d) end
        st.seg    = n[1] or 0
        st.lines  = n[2] or 0
        st.bytes  = n[3] or 0
        st.bucket = n[4]          -- nil for a pre-2026-08-05 head
    end

    local ring = cfgNum("ForensicRingSegments", 42)
    local b    = bucketNow()
    if b then
        -- THE CLOCK DECIDES, not the head. The head is consulted only to answer
        -- "does the file already hold THIS period?" - if it does, resume
        -- appending with its counters; if it does not (a different period, a
        -- head from before buckets existed, or no head at all) the file on disk
        -- is from an earlier turn of the ring and must be reclaimed before the
        -- first write, or a wrap would silently splice new records onto records
        -- up to `ring` periods old.
        local want = b % ring
        if st.bucket ~= b or st.seg ~= want then
            st.seg, st.lines, st.bytes = want, 0, 0
            st.bucket = b
            st.fresh  = true      -- truncate on first write; see flushStream
        end
    else
        -- No clock. Keep whatever the head named and never truncate - a broken
        -- clock must not be able to erase a segment. `seg` can still be outside
        -- a shrunken ring here (the modulo above never ran), so clamp it.
        if st.seg >= ring then
            st.seg, st.lines, st.bytes = 0, 0, 0
            st.headDirty = HEAD_SYNC_LINES
        end
    end

    reclaimOutsideRing(name, ring)
    streams[name] = st
    return st, name
end

-- TIME ROTATES; SIZE ONLY CAPS.
--
-- The period boundary is the only thing that moves the segment, so every
-- segment is exactly one wall-clock window and the ring holds
-- `ring x period` of history no matter how the traffic is shaped. Lines and
-- bytes stay as CEILINGS on a single segment - a flood inside one window is
-- dropped rather than allowed to spend the whole ring's disk in twenty
-- minutes. They no longer rotate anything, because a size-triggered rotation
-- would break the property that makes this reliable: that the segment holding
-- a given moment can be computed from that moment alone.
--
-- Dropping is the correct response to a flood on THIS tier and only this tier.
-- Forensic is explicitly the bounded, replaceable stream; the chronicle is the
-- permanent one and is never rotated, never capped, and never dropped. A flood
-- that would blow the ceiling is itself the interesting event, so it is
-- announced once per segment rather than silently discarded.
--
-- Counted, not measured: `#s` is bytes in Lua 5.1 (and Kahlua), so the buffer is
-- summed as it is written. There is no stat call and reading the file back to
-- size it would be O(segment) on the tick thread.
local function flushStream(st, name)
    if #st.buf == 0 then return end
    local ring  = cfgNum("ForensicRingSegments", 42)
    local segLn = cfgNum("ForensicSegmentLines", 20000)
    local segBy = cfgNum("ForensicSegmentKB", 2048) * 1024

    -- The period boundary. Crossing it reclaims the segment being entered,
    -- which is what bounds the ring: that file holds records from `ring`
    -- periods ago and this is the only moment anything can reclaim them.
    local b = bucketNow()
    if b and st.bucket ~= b then
        st.seg    = b % ring
        st.bucket = b
        st.lines, st.bytes, st.over = 0, 0, false
        st.fresh  = true
    end

    -- Deferred to the first actual write so an idle stream never truncates a
    -- segment it is not going to use.
    if st.fresh then
        rewrite(segPath(name, st.seg), "")   -- truncate-to-zero IS the reclaim
        st.fresh = false
        writeHead(st, name)                  -- head exists from the first flush on
    end

    local added = 0
    for i = 1, #st.buf do added = added + #st.buf[i] + 1 end   -- +1 = the newline

    if st.lines + #st.buf > segLn or st.bytes + added > segBy then
        if not st.over then
            st.over = true
            print("[RFTDCore] RDLog: forensic stream '" .. name .. "' hit its segment"
                .. " ceiling (" .. st.lines .. " lines / " .. st.bytes .. " B); further"
                .. " records are dropped until the next period")
            writeHead(st, name)
        end
        st.buf = {}
        return
    end

    appendMany(segPath(name, st.seg), st.buf)
    st.lines     = st.lines + #st.buf
    st.bytes     = st.bytes + added
    st.headDirty = st.headDirty + #st.buf
    st.buf       = {}
    st.lastMs    = RDShared.nowMs()

    if st.headDirty >= HEAD_SYNC_LINES then
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

    -- Fingerprint tally, same removable-file idiom as the rest of the family.
    -- The ring records every event; RDTally answers which handful of them account
    -- for the volume - the question a rolled ring can no longer be asked. It gets
    -- the payload already in hand here rather than re-deriving it from a second
    -- listener, which is the whole reason this call lives inside this function.
    -- Delete RDTally.lua and this is a nil check.
    if RDTally then
        pcall(function() RDTally.note(streamName, evt, payload) end)
    end
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

-- ---------------------------------------------------------------------------
-- BOOT SELF-TEST - one decisive console line per boot (2026-08-07).
--
-- Write a canary through the SAME extension every stream uses, read it back,
-- and say plainly whether logging works. This exists because both historical
-- outages were silent: the 42.20 allowlist change dropped every write for days
-- with nothing in the console, and "is logging working?" was answerable only by
-- ssh-ing into the box and looking for files. After this, the boot console
-- answers it: one VERIFIED line, or one BROKEN line naming the failure.
--
-- Round-trip, not just open: getFileWriter returning non-nil proves the gate
-- passed, but only reading the line back proves the bytes landed where the
-- reader roots. The canary is truncate-mode so it never grows, and it doubles
-- as a boot marker - its one line records when this server last verified.
-- ---------------------------------------------------------------------------

function RDLog.selfTest()
    local path  = DIR .. "forensic/selftest" .. RDShared.EXT_STREAM
    local stamp = "verified " .. tostring(RDShared.nowSec())
    local wrote = rewrite(path, stamp .. "\n")
    local back  = wrote and readFirstLine(path) or nil
    if back == stamp then
        print("[RFTDCore] RDLog: write path VERIFIED (" .. path .. ")")
        return true
    end
    print("[RFTDCore] RDLog CRITICAL: write path BROKEN - "
        .. (wrote and "wrote but could not read back" or "getFileWriter refused the stream extension")
        .. " (" .. path .. "). NOTHING IS BEING LOGGED. If the engine just"
        .. " updated, check the write-extension allowlist against the decompile.")
    return false
end

if Events.OnServerStarted then
    Events.OnServerStarted.Add(function() pcall(RDLog.selfTest) end)
end

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
