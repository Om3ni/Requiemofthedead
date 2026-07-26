-- MMAudit.lua — Memoir write/read audit trail (server-only, removable).
-- Why: memoir tickets can't be reconstructed from player memory, and the season
-- deserves a record. Every write/read ATTEMPT (refusals included) becomes a
-- SCHEMA'D record (JSONL) so the log is machine-consumable three ways:
--   * a player-facing progression sheet (parse events.jsonl, plot snapshots)
--   * oversight/forensics (full snapshot on every write and successful read)
--   * disaster recovery (snap in the record IS MMSnapshotCodec's snapshot table —
--     feed it back through applyToCharacter to rebuild a character after a wipe
--     or DB corruption; restore command lands as a Players-tab row action)
-- MMServer calls MMAudit.log(...) behind `if MMAudit then` guards, so deleting
-- the Memoirs/ folder disables auditing with no other edit.
--
-- Output (under the server cachedir, Lua/):
--   Memoirs/<SafeName>/events.jsonl  append-only full history, one JSON obj/line
--   Memoirs/<SafeName>/latest.json   newest snapshot-bearing record (overwritten;
--                                    derived convenience — rebuildable from the
--                                    last events.jsonl line; restore reads this)
--   Memoirs/_all.log                 slim human pipe timeline (no heavy payloads):
--                                    <epochSec>|<gameDay>|<EVENT>|user=<name>|k=v...
-- Nested dirs are ENGINE-GUARANTEED: getFileWriter runs File.mkdirs() on the
-- full parent chain (LuaManager.getFileWriter, verified in the 42.19 decompile),
-- and only ".." paths are refused (safeName can't emit dots). The flat fallback
-- below is retained as free insurance only — it should never fire.
--
-- getFileWriter is the ONLY server-side I/O that works in B42 (raw io.open is
-- silently blocked); open-append-close per line, so a hard-killed server loses
-- nothing already logged.
--
-- JSON: hand-rolled encoder — safe because we control every shape (strings,
-- numbers, bools, string-keyed maps, string arrays). Object keys sorted, sets
-- flattened to sorted lists, so identical states encode identically (diffable).

if not isServer() then return end

MMAudit = MMAudit or {}

MMAudit.SCHEMA_V = 1

local DIR = "Memoirs/"

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
-- the horde night?") answer without converting real-world timestamps
local function gameDayNum()
    local ok, d = pcall(function() return getGameTime():getWorldAgeHours() / 24.0 end)
    if ok and type(d) == "number" then return d end
    return nil
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
-- Writers: per-player folder layout with automatic flat fallback
-- ─────────────────────────────────────────────────────────────────────────

local layoutByUser = {}   -- safeName -> "nested" | "flat"

local function openWriter(path, append)
    local w
    pcall(function() w = getFileWriter(DIR .. path, true, append) end)
    return w
end

-- Open <safe>/<base> (preferred) or <safe>.<base> (fallback when the engine
-- won't create the nested directory). The first success is remembered so we
-- don't probe on every event.
local function userWriter(safe, base, append)
    if layoutByUser[safe] ~= "flat" then
        local w = openWriter(safe .. "/" .. base, append)
        if w then layoutByUser[safe] = "nested"; return w end
        if not layoutByUser[safe] then
            MMwarn("MMAudit: nested folder open failed for '" .. safe
                .. "' — using flat Memoirs/" .. safe .. ".<file> instead")
        end
        layoutByUser[safe] = "flat"
    end
    return openWriter(safe .. "." .. base, append)
end

local function writeLine(w, line)
    if not w then return end
    pcall(function() w:write(line .. "\n"); w:close() end)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Character samplers (used by MMServer for before/after proof)
-- ─────────────────────────────────────────────────────────────────────────

function MMAudit.perkLevels(player)
    local out = {}
    pcall(function()
        for i = 0, PerkFactory.PerkList:size() - 1 do
            local perk = PerkFactory.PerkList:get(i)
            local t = perk:getType()
            if t ~= PerkFactory.Perks.None and t ~= PerkFactory.Perks.MAX then
                out[perk:getId()] = player:getPerkLevel(t)
            end
        end
    end)
    return out
end

function MMAudit.perkXP(player)
    local out = {}
    pcall(function()
        for i = 0, PerkFactory.PerkList:size() - 1 do
            local perk = PerkFactory.PerkList:get(i)
            local t = perk:getType()
            if t ~= PerkFactory.Perks.None and t ~= PerkFactory.Perks.MAX then
                out[perk:getId()] = player:getXp():getXP(t) or 0
            end
        end
    end)
    return out
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
--         caller bug — envelope wins nothing, don't reuse its names.
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
    writeLine(userWriter(safe, "events.jsonl", true), jsonLine)

    -- 2) latest.json — overwritten whenever this event carries a snapshot; the
    -- one-file answer to "what does this player have right now" (restore + web)
    if rec.snap then
        writeLine(userWriter(safe, "latest.json", false), jsonLine)
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
    writeLine(openWriter("_all.log", true), table.concat(parts, "|"))
end

-- ─────────────────────────────────────────────────────────────────────────
-- Delayed post-read recheck (READ_RECHECK, ~2 min after READ_OK).
-- Why: the client MIRROR-applies the restore locally, and the additive overwrite
-- model is not idempotent — if the server's XP sync lands on the client before its
-- mirror runs, the restore double-adds CLIENT-side, invisible at apply time. The
-- server only sees it once client XP syncs back up. So we snapshot per-perk XP
-- right after the server apply and re-sample ~2 min later: large POSITIVE drift =
-- suspected double-add; large NEGATIVE drift = mirror failed / apply lost. Small
-- drift is just play. Caveat: client->server XP sync cadence is not guaranteed
-- inside the window — "drift=none" is weak evidence, a big drift is strong.
-- ─────────────────────────────────────────────────────────────────────────
local RECHECK_DELAY_S = 120
local pendingRechecks = {}   -- list of { user, itemId, due, xp = {perkId -> xp} }

local function findOnlineByUsername(name)
    local found
    pcall(function()
        local players = getOnlinePlayers()
        if not players then return end
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and p:getUsername() == name then found = p; break end
        end
    end)
    return found
end

local function runRecheck(entry)
    local p = findOnlineByUsername(entry.user)
    if not p then
        MMAudit.log(entry.user, "READ_RECHECK", { itemId = entry.itemId, result = "offline" })
        return
    end
    local cur = MMAudit.perkXP(p)
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
function MMAudit.scheduleRecheck(player, itemId)
    local user = (MMname and MMname(player)) or "?"
    pendingRechecks[#pendingRechecks + 1] = {
        user   = user,
        itemId = itemId,
        due    = ((getTimestamp and getTimestamp()) or 0) + RECHECK_DELAY_S,
        xp     = MMAudit.perkXP(player),
    }
end

return MMAudit
