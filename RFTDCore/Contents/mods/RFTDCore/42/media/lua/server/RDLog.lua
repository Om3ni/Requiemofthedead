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
--              the traffic is continuous and replaceable.
--
-- Durability model: there is NO shutdown hook on this server - the restart
-- scripts force-kill java and SaveWorldEveryMinutes=0, so nothing may depend
-- on a graceful exit. Chronicle lines are durable per line. Forensic loses at
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
-- Layout (under <cacheDir>/Lua/):
--   RFTD/season/<SeasonId>/chronicle/p/<slug>.jsonl   permanent, per player
--   RFTD/season/<SeasonId>/chronicle/world.jsonl      permanent, server scope
--   RFTD/season/<SeasonId>/index/p/<slug>.json        derived state, rewritten
--   RFTD/forensic/<stream>/head.txt                   "<segment> <lines>"
--   RFTD/forensic/<stream>/000.jsonl .. NNN.jsonl     ring segments
--
-- Envelope (one JSON object per line, keys sorted by RDJson):
--   {"v":2,"t":<epoch>,"d":<gameDay>,"s":"<seasonId>","e":"<NS.EVENT>",
--    "m":"<producing mod>","u":"<user>","l":"<lifeId|null>","x":{...payload}}
--
-- Payload nests under "x" so caller keys can never clash with the envelope.

if not isServer() then return end

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
        return DIR .. "season/" .. seasonId .. "/chronicle/world.jsonl"
    end
    local user = usernameOf(subj) or "unknown"
    local slug = RDIdentity.slugFor(user)
    return DIR .. "season/" .. seasonId .. "/chronicle/p/" .. slug .. ".jsonl"
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
    local user = usernameOf(subj)
    if not user then return end
    RDSeasonServer.ensure()
    local slug = RDIdentity.slugFor(user)
    local path = DIR .. "season/" .. RDSeasonServer.current() .. "/index/p/" .. slug .. ".json"
    rewrite(path, RDJson.encode(tbl or {}) .. "\n")
end

-- ---------------------------------------------------------------------------
-- FORENSIC ring
-- ---------------------------------------------------------------------------

local streams = {}   -- name -> { seg, lines, buf, lastMs, headDirty, loaded }

local function segPath(name, seg)
    return DIR .. "forensic/" .. name .. "/" .. string.format("%03d", seg) .. ".jsonl"
end

local function headPath(name)
    return DIR .. "forensic/" .. name .. "/head.txt"
end

local function writeHead(st, name)
    rewrite(headPath(name), tostring(st.seg) .. " " .. tostring(st.lines) .. "\n")
    st.headDirty = 0
end

local function stream(name)
    name = safePath(name)
    local st = streams[name]
    if st then return st, name end
    st = { seg = 0, lines = 0, buf = {}, lastMs = 0, headDirty = 0 }
    local head = readFirstLine(headPath(name))
    if head then
        local seg, lines = head:match("^(%d+)%s+(%d+)")
        if seg then
            st.seg   = tonumber(seg) or 0
            st.lines = tonumber(lines) or 0
        end
    end
    streams[name] = st
    return st, name
end

local function flushStream(st, name)
    if #st.buf == 0 then return end
    local ring  = cfgNum("ForensicRingSegments", 8)
    local segLn = cfgNum("ForensicSegmentLines", 20000)

    appendMany(segPath(name, st.seg), st.buf)
    st.lines     = st.lines + #st.buf
    st.headDirty = st.headDirty + #st.buf
    st.buf       = {}
    st.lastMs    = RDShared.nowMs()

    if st.lines >= segLn then
        st.seg   = (st.seg + 1) % ring
        st.lines = 0
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
function RDLog.forensic(streamName, evt, subj, payload)
    push(streamName, envelope(evt, "?", subj, payload))
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
