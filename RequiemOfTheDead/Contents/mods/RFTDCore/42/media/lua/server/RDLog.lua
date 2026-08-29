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
--   FORENSIC   permanent high-volume telemetry, split into immutable archive
--              segments. The wall clock starts one segment window per period
--              (4 h by default); line/size thresholds start another PART in
--              that window. A closed part is never reopened, truncated, or
--              reclaimed by RFTD. Buffered (<=25 lines or ~1s) to keep the
--              continuous traffic affordable.
--
-- Durability model: nothing here may depend on a graceful exit. The restart
-- scripts force-kill java (documented data-loss history), and while the
-- production dedi saves every 30 minutes, the local/test setup runs with
-- SaveWorldEveryMinutes=0 - so engine-save cadence is environment-dependent
-- and these files never rely on it. Chronicle lines are durable per line.
-- Forensic loses at most one buffer (<=25 lines / <=1s).
--
-- A force-kill cannot damage an older segment: every process chooses a fresh,
-- collision-checked session name and only appends to files it created. The
-- current buffer is the only vulnerable tail. Rotation needs no delete or
-- rename primitive; when a boundary is crossed, the old path is simply closed
-- forever and a new one is created. cacheFileExists and getFileWriter both root
-- at cacheDir/Lua (LuaManager.java:4617-4623, 5523-5555).
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
-- files. Those files and every numbered ring segment from the superseded
-- retention design stay on disk as immutable history. This writer never opens
-- them, so restoring permanent retention cannot destroy the evidence that
-- predates it.
--
-- Layout (under <cacheDir>/Lua/). Every player owns ONE directory per season
-- (<SafeName>.<SteamID>, see RDIdentity) holding their permanent record and
-- their derived-state index side by side:
--   RFTD/season/<SeasonName>/chronicle/p/<Name.SID>/events.jsonl.log  permanent
--   RFTD/season/<SeasonName>/chronicle/p/<Name.SID>/index.json.txt    rewritten
--   RFTD/season/<SeasonName>/chronicle/world.jsonl.log                server scope
--   RFTD/forensic/<stream>/head.txt          rewritten current-path pointer
--   RFTD/forensic/<stream>/<UTC-date>/
--     <UTC-window>_<session-ms>_<part>.<stream>.jsonl.log     immutable
--     e.g. guardian/2026-08-16/2026-08-16_12-00-00Z_
--          1786896000123_000.guardian.jsonl.log
-- Old 000.<stream>.jsonl.log ring files remain beside these dated folders.
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
require "RDFile"

RDLog = RDLog or {}

local DIR = RDShared.DIR

-- ---------------------------------------------------------------------------
-- Config (sandbox-tunable; read lazily so SandboxVars is ready)
-- ---------------------------------------------------------------------------

local function cfgNum(key, default)
    local v = SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore[key]
    if type(v) == "number" and v > 0 then return v end
    return default
end

local HEAD_SYNC_LINES = 500

-- ---------------------------------------------------------------------------
-- THE ARCHIVE CLOCK
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
-- The time window remains derived rather than accumulated:
--
--     bucket = floor(epochSeconds / periodSeconds)
--
-- Nothing must carry across a restart. Each process has a fresh session token,
-- collision-checked against the cache before its first append. Two processes in
-- the same four-hour window therefore create two immutable parts rather than
-- reopening one another's files or depending on counters that died with them.
--
-- Boundaries are ABSOLUTE, not relative to boot: with the 4 h default they
-- land on 00:00, 04:00, 08:00, ... UTC, so segments line up across streams and
-- across servers instead of drifting with each restart.
--
-- head.txt is advisory bookkeeping only: it names the current archive path and
-- its approximate counters. Recovery never trusts it and evidence never depends
-- on it. It may be stale by <=500 lines after a force-kill.
local function periodSec()
    local h = cfgNum("ForensicSegmentHours", 4)
    if h < 1 then h = 1 elseif h > 24 then h = 24 end
    return math.floor(h * 3600)
end

-- nil when the clock is unavailable. A stream already writing keeps its path;
-- a new stream uses an "undated" session path. When the clock recovers, the
-- dated boundary starts normally. No clock state can cause data destruction.
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

-- The MECHANISM moved to RDFile (2026-08-25) - these locals were the
-- canonical copy twelve other files had re-derived, and exposing them is what
-- retired the family. What stays here is RDLog's own POLICY on a refusal:
-- the CRITICAL per-extension shout and writeFailures(), which the forensic
-- consumers read. RDFile keeps its own floor-level count; the two answer
-- different questions ("is the suite dropping writes anywhere" vs "is the
-- FORENSIC ARCHIVE dropping records"), so neither replaces the other.
local function appendLine(path, line)
    if not RDFile.appendLine(path, line) then reportRefused(path); return false end
    return true
end

local function appendMany(path, lines)
    if not RDFile.appendMany(path, lines) then reportRefused(path); return false end
    return true
end

local function rewrite(path, content)
    if not RDFile.rewrite(path, content) then reportRefused(path); return false end
    return true
end

-- No guard - and the "reads throw, writes don't" asymmetry this comment used
-- to document is DEAD, corrected 2026-08-19. The BufferedReader that
-- getFileReader hands back is an EXPOSED class (LuaManager.java:1651), and
-- every exposed method body routes through MethodCaller, which swallows the
-- IOException, prints its stack trace to the console, and returns nil
-- (MethodCaller.java:33-56). So readLine on a truncated file or one removed
-- mid-read cannot raise into Lua any more than the writer can: it reads as
-- early EOF. Reads and writes have the SAME answer here - nil - and the old
-- guard was inert.
--
-- The recovery is unchanged because it never depended on catching anything: a
-- head line we cannot read is indistinguishable from one that is not there,
-- and both mean "rebuild it". (Mechanism in RDFile; the read-vs-write lane
-- doctrine above travelled into that file's header.)
local function readFirstLine(path)
    return RDFile.readFirstLine(path)
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
    if type(subj) ~= "table" and type(subj) ~= "userdata" then return nil end
    if subj.getUsername then
        local name = subj:getUsername()
        if name then return tostring(name) end
    end
    return nil
end

local function lifeIdOf(subj)
    if type(subj) ~= "table" and type(subj) ~= "userdata" then return nil end
    if not subj.getModData then return nil end
    local md = subj:getModData()
    local id = md and md.RFTD_LifeId
    if id then return tostring(id) end
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
-- FORENSIC immutable archive
-- ---------------------------------------------------------------------------

local streams = {}
local sessionId = string.format("%.0f", RDShared.nowMs() or 0)

local function headPath(name)
    return DIR .. "forensic/" .. name .. "/head.txt"
end

-- Kahlua registers os.date directly (OsLib.java:44-50, 87-103), including
-- Lua's leading "!" UTC form (:109-121). Naming from the bucket's START keeps
-- every stream aligned and makes a copied file understandable without its
-- parent directory.
local function windowNames(bucket)
    if not bucket then return "undated", "undated" end
    local start = bucket * periodSec()
    return os.date("!%Y-%m-%d", start), os.date("!%Y-%m-%d_%H-%M-%SZ", start)
end

local function archivePath(name, day, stamp, run, part)
    return DIR .. "forensic/" .. name .. "/" .. day .. "/"
        .. stamp .. "_" .. run .. "_" .. string.format("%03d", part)
        .. "." .. name .. RDShared.EXT_STREAM
end

local function writeHead(st, name)
    -- v2<TAB>path<TAB>lines<TAB>bytes<TAB>bucket<TAB>part. This file is an
    -- operational pointer, never evidence and never recovery state.
    rewrite(headPath(name), table.concat({
        "v2", st.path or "", tostring(st.lines), tostring(st.bytes),
        tostring(st.bucket or 0), tostring(st.part or 0),
    }, "\t") .. "\n")
    st.headDirty = 0
    st.headWritten = true
end

local function startWindow(st, name, bucket)
    local day, stamp = windowNames(bucket)
    local collision = 0
    local run = sessionId
    local path = archivePath(name, day, stamp, run, 0)
    while cacheFileExists(path) do
        collision = collision + 1
        run = sessionId .. "-" .. tostring(collision)
        path = archivePath(name, day, stamp, run, 0)
    end
    st.bucket, st.day, st.stamp, st.run = bucket, day, stamp, run
    st.part, st.path = 0, path
    st.lines, st.bytes, st.headDirty = 0, 0, 0
    st.headWritten = false
end

local function rollPart(st, name)
    local part = st.part + 1
    local path = archivePath(name, st.day, st.stamp, st.run, part)
    while cacheFileExists(path) do
        part = part + 1
        path = archivePath(name, st.day, st.stamp, st.run, part)
    end
    st.part, st.path = part, path
    st.lines, st.bytes, st.headDirty = 0, 0, 0
    st.headWritten = false
end

local function stream(name)
    name = safePath(name):gsub("/", "_")
    local st = streams[name]
    if st then return st, name end
    st = { buf = {}, lastMs = 0 }
    startWindow(st, name, bucketNow())
    streams[name] = st
    return st, name
end

-- Time starts a new window; line/byte thresholds start another immutable part
-- in that window. A batch larger than a threshold is written whole to an empty
-- part, so a configuration limit can make a file larger but can never discard
-- evidence. `#s` is the encoded byte count in Lua 5.1/Kahlua; reading a file to
-- measure it would be O(segment) work on the tick thread.
local function flushStream(st, name)
    if #st.buf == 0 then return end
    local segLn = cfgNum("ForensicSegmentLines", 20000)
    local segBy = cfgNum("ForensicSegmentKB", 2048) * 1024
    local b = bucketNow()
    if b and st.bucket ~= b then startWindow(st, name, b) end

    local added = 0
    for i = 1, #st.buf do added = added + #st.buf[i] + 1 end
    if st.lines > 0
       and (st.lines + #st.buf > segLn or st.bytes + added > segBy) then
        rollPart(st, name)
    end

    local count = #st.buf
    local wrote = appendMany(st.path, st.buf)
    st.buf = {}
    if not wrote then return end

    st.lines     = st.lines + count
    st.bytes     = st.bytes + added
    st.headDirty = st.headDirty + count
    st.lastMs    = RDShared.nowMs()
    if not st.headWritten or st.headDirty >= HEAD_SYNC_LINES then
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
-- convention); producers own their enable/rate policy while this boundary owns
-- durable, immutable segmentation.
-- modId names the PRODUCING mod, the envelope's "m". Chronicle gets it free from
-- RDEvents.get(evt) because that enum is closed and knows who registered each
-- event; forensic events are deliberately outside it, so the producer has to say.
-- It was hardcoded "?" here, which meant every forensic record in the family - not
-- just Guardian's - shipped an empty attribution field. Optional so an unconverted
-- caller degrades to the old behaviour rather than erroring.
-- A stream bound to one module, which is how a satellite is meant to hold this.
--
--     local forensic = RDLog.channel("kits", "RFTDDungeonMaster")
--     forensic("DM.KIT_CLAIMED", player, { id = "reward" })
--
-- The stream name and the module id are fixed once instead of repeated at every
-- call site, where they are exactly the two arguments a copy-paste gets wrong -
-- and a wrong modId is invisible, because it only shows up as an empty
-- attribution field in a record nobody reads until they need it.
--
-- The returned function is nil-safe about RDLog itself so a SHARED file can
-- hold one: RDLog is server-only, and Limes' LMSync is loaded on both sides.
--
-- Promoted 2026-08-23 from identical wrappers in LMSync and DMKits_Server.
function RDLog.channel(streamName, modId)
    return function(evt, subj, payload)
        if RDLog and RDLog.forensic then
            RDLog.forensic(streamName, evt, subj, payload, modId)
        end
    end
end

function RDLog.forensic(streamName, evt, subj, payload, modId)
    push(streamName, envelope(evt, modId or "?", subj, payload))

    -- Fingerprint tally, same removable-file idiom as the rest of the family.
    -- The archive records every event; RDTally answers which handful account for
    -- the current boot's volume without scanning permanent history. It gets
    -- the payload already in hand here rather than re-deriving it from a second
    -- listener, which is the whole reason this call lives inside this function.
    -- Delete RDTally.lua and this is a nil check.
    if RDTally then
        -- a tally fault must never disturb the forensic push it rides on
        pcall(RDTally.note, streamName, evt, payload)
    end
end

-- Escape hatch for consolidating pre-Core writers incrementally: reroute an
-- existing logger's already-formatted line into an archive stream in one call,
-- keeping its current format. Reformatting to envelopes is a later,
-- separately verifiable step.
function RDLog.legacyLine(streamName, str)
    push(streamName, tostring(str))
end

-- Drain every stream buffer to disk. Called on the 1s tick throttle, every
-- minute, before any chronicle write, and by anything about to read the archive.
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
-- reader roots. The canary lives under health/, outside every evidence stream;
-- it is truncate-mode so it never grows and doubles as a boot marker. No file
-- under forensic/<stream>/<date>/ is ever used for this destructive probe.
-- ---------------------------------------------------------------------------

function RDLog.selfTest()
    local path  = DIR .. "health/write-canary.log"
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
    -- No guard: Event.trigger isolates listeners (Event.java:53-63), so a
    -- selfTest I/O fault cannot mark boot as failed on its own.
    Events.OnServerStarted.Add(function() RDLog.selfTest() end)
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
