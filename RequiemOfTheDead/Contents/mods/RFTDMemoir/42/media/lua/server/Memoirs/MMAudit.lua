-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMAudit.lua - Memoir write/read audit trail (server-only, removable).
-- Why: memoir tickets can't be reconstructed from player memory, and the season
-- deserves a record. Every write/read ATTEMPT (refusals included) becomes a
-- SCHEMA'D record (JSONL) so the log is machine-consumable three ways:
--   * a player-facing progression sheet (parse events.jsonl, plot snapshots)
--   * oversight/forensics (full snapshot on every write and successful read)
--   * disaster recovery (snap in the record IS MMSnapshotCodec's snapshot table -
--     feed it back through applyToCharacter to rebuild a character after a wipe
--     or DB corruption; restore command lands as a Players-tab row action)
-- MMServer calls MMAudit.log(...) behind `if MMAudit then` guards, so deleting
-- the Memoirs/ folder disables auditing with no other edit.
--
-- Output (under the server cachedir, Lua/):
--   Memoirs/<SafeName>/events.jsonl.log  append-only history, one JSON obj/line
--   Memoirs/<SafeName>/latest.json.txt   the RECOVERY POINT: newest WRITE,
--                                    overwritten. Restores deliberately do NOT move
--                                    it (see the note at the write site); derived
--                                    convenience, rebuildable from the last WRITE
--                                    in events.jsonl.log
--   Memoirs/_all.log                 slim human pipe timeline (no heavy payloads):
--                                    <epochSec>|<gameDay>|<EVENT>|user=<name>|k=v...
--
-- The compound ".jsonl.log" / ".json.txt" names follow RDShared's convention:
-- since 42.20 getFileWriter refuses any extension outside
-- ("ini","cfg","txt","log","json") and returns nil - which killed ".jsonl",
-- though ".json" itself is allowed (LuaManager.java:1045; RDShared's header
-- owns the correction). This silently destroyed both files
-- for a day - writeLine's `if not w then return end` meant no error surfaced
-- anywhere - and _all.log was the only survivor because it already ended ".log".
-- The full rule, the traps, and why append-capable getFileWriter is the only
-- viable route live in RDShared (EXT_STREAM / EXT_DOC), which is the single place
-- to change if TIS moves the allowlist again. Pre-42.20 ".jsonl"/".json" files are
-- still READABLE (reads are ungated) - MMRestore falls back to them rather than
-- migrating, since Lua cannot rename or delete.
--
-- Nested dirs are ENGINE-GUARANTEED: getFileWriter runs File.mkdirs() on the
-- full parent chain, catches open/create I/O failures, and returns nil on refusal
-- (LuaManager.java:5523-5555). There is deliberately no flat write fallback: if
-- a transient failure moved one user to a flat file, MMRestore's nested-first
-- compatibility read could keep selecting an older nested recovery point.
-- Historical flat files remain readable there; all new writes have one canonical
-- location. Paths are refused for ".." or a disallowed extension, and safeName
-- cannot emit dots.
--
-- getFileWriter is the ONLY server-side I/O that works in B42 (raw io.open is
-- silently blocked); open-append-close per line, so a hard-killed server loses
-- nothing already logged.
--
-- JSON: hand-rolled encoder - safe because we control every shape (strings,
-- numbers, bools, string-keyed maps, string arrays). Object keys sorted, sets
-- flattened to sorted lists, so identical states encode identically (diffable).

if not isServer() then return end

-- Explicit, because EXT_STREAM/EXT_DOC are read at file scope below and the client
-- walks every mod's lua tiers ALPHABETICALLY, so "MMAudit.lua" can run before
-- Core's "RDShared.lua". Cross-mod require works and the walk skips already-required
-- files. Safe under the isServer() guard above, which has already returned on the
-- client. Memoir's mod.info already declares require=RFTDCore, so this adds no new
-- dependency - it just stops the one constant that must not drift from being copied.
require "RDShared"
require "RDFile"
require "MMRoster"

MMAudit = MMAudit or {}

MMAudit.SCHEMA_V = 1

local DIR = "Memoirs/"

local F_EVENTS = "events" .. RDShared.EXT_STREAM   -- append-only
local F_LATEST = "latest" .. RDShared.EXT_DOC      -- rewritten in place

-- ─────────────────────────────────────────────────────────────────────────
-- Small helpers
-- ─────────────────────────────────────────────────────────────────────────

-- filesystem-safe per-player file/dir name (usernames may hold anything)
local function safeName(name)
    name = tostring(name or "unknown")
    return (name:gsub("[^%w%-_]", "_"))
end

-- %.2f then trim keeps Kahlua doubles out of scientific notation (tostring on a
-- large number can yield "1.78E9", which is useless in a log and invalid-ish JSON)
local function fmtNum(n)
    return (string.format("%.2f", n):gsub("%.00$", ""))
end

local function isArray(v)
    local n = 0
    for k in pairs(v) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #v
end

-- in-game world age in days (number), so gameplay questions ("was that before
-- the horde night?") answer without converting real-world timestamps.
--
-- No guard. getGameTime() can never return null - GameTime.instance is
-- assigned in the static initializer (GameTime.java:74), its only reassignment
-- engine-wide is setInstance(new GameTime()) (GameLoadingState.java:304), and
-- nothing ever passes null. getWorldAgeHours is primitive arithmetic on two
-- primitive fields with initialized defaults (GameTime.java:829-833, fields
-- :81-82) - before a world loads it returns 2.0, it does not throw.
local function gameDayNum()
    return getGameTime():getWorldAgeHours() / 24.0
end

-- ─────────────────────────────────────────────────────────────────────────
-- Serializers: compact Lua-ish (pipe line) and JSON (schema records)
-- ─────────────────────────────────────────────────────────────────────────

local function serialize(v)
    local t = type(v)
    if t == "number" then return fmtNum(v) end
    if t ~= "table" then return tostring(v) end
    if isArray(v) then
        local out = {}
        for i, item in ipairs(v) do out[i] = serialize(item) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = k .. "=" .. serialize(v[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
end

local function jsonEscape(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    return s
end

local function jsonEncode(v)
    if v == nil then return "null" end
    local t = type(v)
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return fmtNum(v) end
    if t == "table" then
        if isArray(v) then
            local out = {}
            for i, item in ipairs(v) do out[i] = jsonEncode(item) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = {}
        for _, k in ipairs(keys) do
            out[#out + 1] = '"' .. jsonEscape(k) .. '":' .. jsonEncode(v[k])
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return '"' .. jsonEscape(v) .. '"'
end

-- Snapshot normalized for the record: recipes set -> sorted list, traits sorted
-- (identical builds always encode identically), owner dropped (user is on the
-- envelope; no need to double-log the steamID into every record).
local function normalizeSnap(snap)
    if type(snap) ~= "table" then return nil end
    local copy = {}
    for k, v in pairs(snap) do
        if k == "recipes" then
            local list = {}
            for name in pairs(v or {}) do list[#list + 1] = tostring(name) end
            table.sort(list)
            copy.recipes = list
        elseif k == "traits" then
            local list = {}
            for _, name in ipairs(v or {}) do list[#list + 1] = tostring(name) end
            table.sort(list)
            copy.traits = list
        elseif k ~= "owner" then
            copy[k] = v
        end
    end
    return copy
end

-- ─────────────────────────────────────────────────────────────────────────
-- Writers: one record/snapshot/timeline sink per operation
-- ─────────────────────────────────────────────────────────────────────────

local writeFailCount = 0
local writeFailSaid = {}   -- bounded to the three sink names below

local function reportWriteFailure(sink, path)
    writeFailCount = writeFailCount + 1
    if writeFailSaid[sink] then return end
    writeFailSaid[sink] = true
    MMwarn("MMAudit: " .. sink .. " sink unavailable at '" .. DIR .. path
        .. "' - this session's failure count is available from MMAudit.writeFailures()")
end

function MMAudit.writeFailures()
    return writeFailCount
end

-- Mechanism in RDFile (2026-08-25); the per-SINK failure accounting stays
-- here - "which archive is dropping records" is this module's question, and
-- RDFile's floor counter cannot answer it. The whole record is one sink
-- result: callers can preserve gameplay while the failure stays visible.
local function writeLine(sink, path, append, line)
    local ok
    if append then
        ok = RDFile.appendLine(DIR .. path, line)
    else
        ok = RDFile.rewrite(DIR .. path, line .. "\n")
    end
    if not ok then
        reportWriteFailure(sink, path)
        return false
    end
    return true
end

-- ─────────────────────────────────────────────────────────────────────────
-- Character sampler (used by MMServer/MMRestore for before/after proof)
-- ─────────────────────────────────────────────────────────────────────────

-- One pass produces one indivisible observation. The old level/XP guards each
-- returned whatever prefix had been filled before a fault, indistinguishable
-- from a real character with fewer skills. On a valid IsoPlayer these are direct
-- reads: getXp returns the field, getPerkLevel returns the matching level or 0,
-- XP.getXP returns the map value or 0, and Perk.getId/getType return fields
-- (IsoGameCharacter.java:2435-2437, 4478-4483, 9374-9380, 15643-15647;
-- PerkFactory.java:175-176, 203-204). Missing required state is reported before
-- the walk; no partial table can enter the forensic record.
function MMAudit.sampleProgression(player)
    if not player then return { ok = false, error = "player unavailable" } end
    local xp = player:getXp()
    if not xp then return { ok = false, error = "player XP unavailable" } end

    local levels, totals = {}, {}
    for i = 0, PerkFactory.PerkList:size() - 1 do
        local perk = PerkFactory.PerkList:get(i)
        local t = perk:getType()
        if t ~= PerkFactory.Perks.None and t ~= PerkFactory.Perks.MAX then
            local id = perk:getId()
            levels[id] = player:getPerkLevel(t)
            totals[id] = xp:getXP(t) or 0
        end
    end
    return { ok = true, levels = levels, xp = totals }
end

-- Keep the audit schema's established level/XP fields while making unavailable
-- observations explicit. Errors stay visible in JSON and the slim timeline.
function MMAudit.attachProgression(data, before, after)
    data = data or {}
    if before then
        if before.ok then data.lvlsBefore = before.levels
        else data.sampleBeforeError = before.error or "unknown" end
    end
    if after then
        if after.ok then
            data.lvlsAfter = after.levels
            data.postXP = after.xp
        else
            data.sampleAfterError = after.error or "unknown"
        end
    end
    return data
end

-- "Nimble:2>5,Strength:5>7" for every perk whose level changed; "none" if nothing
function MMAudit.levelDiff(pre, post)
    local parts = {}
    for id, after in pairs(post or {}) do
        local before = (pre or {})[id] or 0
        if before ~= after then parts[#parts + 1] = id .. ":" .. tostring(before) .. ">" .. tostring(after) end
    end
    table.sort(parts)
    if #parts == 0 then return "none" end
    return table.concat(parts, ",")
end

-- ─────────────────────────────────────────────────────────────────────────
-- The logger
-- ─────────────────────────────────────────────────────────────────────────

-- Heavy payloads live in the JSONL records only; the pipe timeline stays slim
-- and human-readable (READ_OK gets a derived compact level diff instead).
local PIPE_SKIP = { snap = true, postXP = true, lvlsBefore = true, lvlsAfter = true }

-- events: WRITE / WRITE_NOITEM / WRITE_OWNER / READ_OK / READ_NOITEM / READ_EMPTY /
--         READ_OWNER / READ_FADED / READ_SAMELIFE / READ_RECALLED / READ_APPLYFAIL /
--         READ_RECHECK / RESTORE_OK / RESTORE_FAIL (MMRestore)
-- player: the IsoPlayer, or a plain username string (for events logged when the
--         player object is gone, e.g. an offline recheck)
-- data:   plain table; values may be scalars or tables (snap, lvls maps, drift...).
--         Merged into the JSON envelope {v,t,day,event,user}; key clashes are a
--         caller bug - envelope wins nothing, don't reuse its names.
function MMAudit.log(player, event, data)
    data = data or {}
    local user
    if type(player) == "string" then user = player
    else user = (MMname and MMname(player)) or "?" end
    local safe = safeName(user)
    local now = (getTimestamp and getTimestamp()) or 0
    local day = gameDayNum()

    -- 1) JSONL record (full fidelity)
    local rec = { v = MMAudit.SCHEMA_V, t = now, day = day, event = event, user = user }
    for k, v in pairs(data) do rec[k] = v end
    if rec.snap then rec.snap = normalizeSnap(rec.snap) end
    local jsonLine = jsonEncode(rec)
    local result = {
        history = writeLine("history", safe .. "/" .. F_EVENTS, true, jsonLine),
    }

    -- 2) latest.json - THE RECOVERY POINT: the player's last voluntary save.
    --
    -- WRITE only, and the "only" is the whole point. This used to fire for any
    -- snapshot-bearing event, which meant every admin RESTORE_OK overwrote the
    -- recovery point with itself. The snapshot inside stayed correct, but the
    -- ENVELOPE then described the restore rather than the write, so:
    --   * "how stale is this archive" answered with the restore's timestamp.
    --     Observed live 2026-07-28: latest.json reading day 18.52 while holding
    --     a snapshot written on day 3.19.
    --   * archiveT chained restore -> restore -> restore instead of naming the
    --     write it ultimately came from.
    -- That matters because the whole player-facing rule is "your last written
    -- memoir is your restore path", and this file is what answers when that was.
    --
    -- Restores still append to events.jsonl above, snapshot and all - that record
    -- is worth keeping and is where a restore's provenance belongs. They just no
    -- longer move the point MMRestore.readLatest recovers from.
    if rec.snap and event == "WRITE" then
        result.recovery = writeLine("recovery", safe .. "/" .. F_LATEST, false, jsonLine)
    end

    -- 3) slim pipe timeline
    local parts = {
        tostring(now),
        day and string.format("%.2f", day) or "?",
        tostring(event),
        "user=" .. user,
    }
    if data.lvlsBefore and data.lvlsAfter then
        parts[#parts + 1] = "lvls=" .. MMAudit.levelDiff(data.lvlsBefore, data.lvlsAfter)
    end
    local keys = {}
    for k in pairs(data) do if not PIPE_SKIP[k] then keys[#keys + 1] = tostring(k) end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = data[k]
        parts[#parts + 1] = k .. "=" .. (type(v) == "table" and serialize(v)
            or (type(v) == "number" and fmtNum(v) or tostring(v)))
    end
    result.timeline = writeLine("timeline", "_all.log", true, table.concat(parts, "|"))
    return result
end

-- ─────────────────────────────────────────────────────────────────────────
-- Delayed post-read recheck (READ_RECHECK, ~2 min after READ_OK).
-- Why: the client MIRROR-applies the restore locally, and the additive overwrite
-- model is not idempotent - if the server's XP sync lands on the client before its
-- mirror runs, the restore double-adds CLIENT-side, invisible at apply time. The
-- server only sees it once client XP syncs back up. So we snapshot per-perk XP
-- right after the server apply and re-sample ~2 min later: large POSITIVE drift =
-- suspected double-add; large NEGATIVE drift = mirror failed / apply lost. Small
-- drift is just play. Caveat: client->server XP sync cadence is not guaranteed
-- inside the window - "drift=none" is weak evidence, a big drift is strong.
-- ─────────────────────────────────────────────────────────────────────────
local RECHECK_DELAY_S = 120
local pendingRechecks = {}   -- list of { user, itemId, due, xp = {perkId -> xp} }

local function runRecheck(entry)
    local p = MMRoster.findOnline(entry.user)
    if not p then
        MMAudit.log(entry.user, "READ_RECHECK", { itemId = entry.itemId, result = "offline" })
        return
    end
    local sample = MMAudit.sampleProgression(p)
    if not sample.ok then
        MMAudit.log(p, "READ_RECHECK", { itemId = entry.itemId,
            result = "sample_unavailable", sampleError = sample.error })
        return
    end
    local cur = sample.xp
    local drift, n = {}, 0
    for id, xp in pairs(cur) do
        local d = xp - (entry.xp[id] or 0)
        if d >= 1 or d <= -1 then drift[id] = d; n = n + 1 end
    end
    MMAudit.log(p, "READ_RECHECK", {
        itemId = entry.itemId,
        drift  = (n > 0) and drift or "none",
    })
end

local function onEveryMinute()
    if #pendingRechecks == 0 then return end
    local now = (getTimestamp and getTimestamp()) or 0
    local keep = {}
    for _, entry in ipairs(pendingRechecks) do
        if now >= entry.due then runRecheck(entry) else keep[#keep + 1] = entry end
    end
    pendingRechecks = keep
end
Events.EveryOneMinute.Add(onEveryMinute)

-- Called by MMServer right after a successful apply (post-apply XP as baseline).
function MMAudit.scheduleRecheck(player, itemId, baseline)
    local user = (MMname and MMname(player)) or "?"
    baseline = baseline or MMAudit.sampleProgression(player)
    if not baseline.ok then
        MMAudit.log(player or user, "READ_RECHECK", { itemId = itemId,
            result = "baseline_unavailable", sampleError = baseline.error })
        return false
    end
    pendingRechecks[#pendingRechecks + 1] = {
        user   = user,
        itemId = itemId,
        due    = ((getTimestamp and getTimestamp()) or 0) + RECHECK_DELAY_S,
        xp     = baseline.xp,
    }
    return true
end

return MMAudit

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
