-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFLog - in-memory event buffer for the admin console surface.
--
-- Sources we accept:
--   "Admin"      - actions audited by DFServer (broadcast to all admins)
--   "Error"      - errors scraped from getLuaDebuggerErrors() by DFErrorPoller
--   "ClientCmd"  - the RDCmdRelay feed
--   "Tripwire"   - a client did something that should not have been possible
--   "Mod:<name>" - free-form lines pushed by a consumer mod
--
-- Levels: "info" / "warn" / "error" / "audit" / "tripwire". The Console tab and
-- the bottom strip both subscribe and render from the same buffer.
--
-- AN ENTRY IS AN EVENT, NOT A LINE (2026-08-08). The old shape was one string
-- per entry, and DFErrorPoller flattened multi-line stack traces into it with
-- newlines replaced by " | " and a 240-char truncation. That was done for the
-- bottom strip, which draws with drawText and has no newline awareness - every
-- line of a trace would otherwise render at the same Y.
--
-- Fixing a RENDERER by destroying the DATA cost us the console too: a four-
-- fragment stack trace arrived as four unrelated 240-char smears. So an entry
-- now carries BOTH:
--
--   text   - one line, what the strip draws
--   detail - the full multi-line payload, what the console's detail pane draws
--
-- Callers that only have a line keep passing `text` alone and nothing changes.
--
-- TWO DEDUP MODES, and the difference matters:
--
--   No `key`  - collapse only against the PREVIOUS entry from the same source.
--               RDCmdConsole depends on this: a client spamming one command
--               becomes "xN", but two clients alternating stay distinguishable.
--
--   With `key` - collapse against every live entry sharing that fingerprint,
--               wherever it sits in the buffer. Errors alternating A-B-A-B used
--               to make four entries; now they make two with counts. This is
--               what makes "how many unique errors" a question the buffer can
--               answer, and it is the shape a forensic fingerprint index wants.
--
-- The index is pruned on eviction. A fingerprint map that outlives its entries
-- is a slow leak AND a correctness bug - a key whose entry has been evicted
-- would bump a count on a row nobody can see.
--
-- Cross-admin sync: server audits broadcast via DFCore.audit, every client
-- receives, only admins see the panel so the buffer is benign for everyone.

if isServer() then return end

DFLog = DFLog or {
    entries   = {},
    index     = {},   -- fingerprint -> entry, for keyed dedup. Pruned on evict.
    capacity  = 500,
    listeners = {},
}

-- Older sessions may have a DFLog table from before `index` existed.
DFLog.index = DFLog.index or {}

-- ---------------------------------------------------------------------------
-- Clocks
-- ---------------------------------------------------------------------------
--
-- TWO STAMPS PER ENTRY, because they answer different questions and neither
-- substitutes for the other:
--
--   time  - "HH:MM:SS", what the console shows. Compact enough for a row.
--   stamp - "YYYY-MM-DD HH:MM:SS", what a copied report carries. A bug report
--           pasted into Discord three days later needs the date, and a trace
--           that says only "19:42:03" cannot be lined up against a server log.
--
-- Both are LOCAL wall clock via Calendar, deliberately not os.date: os is a
-- Kahlua-provided library rather than an engine global, and this file must not
-- fail to load on a build where it is absent or shaped differently. Calendar is
-- the same class errorMagnifier and every other surface here already uses.
local function calFields()
    local ok, c = pcall(function() return Calendar.getInstance() end)
    if not ok or not c then return nil end
    local f
    ok = pcall(function()
        f = {
            y   = c:get(Calendar.YEAR),
            mo  = c:get(Calendar.MONTH) + 1,   -- Calendar.MONTH is 0-based
            d   = c:get(Calendar.DAY_OF_MONTH),
            h   = c:get(Calendar.HOUR_OF_DAY),
            mi  = c:get(Calendar.MINUTE),
            s   = c:get(Calendar.SECOND),
        }
    end)
    if not ok then return nil end
    return f
end

local function nowString()
    local f = calFields()
    if not f then return "--:--:--" end
    return string.format("%02d:%02d:%02d", f.h, f.mi, f.s)
end

local function nowStamp()
    local f = calFields()
    if not f then return "--------- --:--:--" end
    return string.format("%04d-%02d-%02d %02d:%02d:%02d", f.y, f.mo, f.d, f.h, f.mi, f.s)
end

-- ---------------------------------------------------------------------------
-- Context header - what a copied report needs to be actionable
-- ---------------------------------------------------------------------------
--
-- Borrowed from errorMagnifier's getZomboidSettingsHeader, and it is the single
-- cheapest thing here: a pasted trace with no build, no mode and no checksum
-- state costs a round trip to establish facts the reporter already had.
-- Every probe in this header is best-effort: a field that cannot be read
-- degrades to an absent line, never to a report that fails to build.
function DFLog.contextHeader()
    local lines = { "=== Requiem of the Dead - console report ===" }

    local v
    if pcall(function() v = getCore():getVersion() end) and v then
        local steam = false
        pcall(function() steam = getSteamModeActive() == true end)
        lines[#lines + 1] = "Version: " .. tostring(v) .. (steam and " (Steam)" or "")
    end

    local mp = false
    pcall(function() mp = isClient() == true end)
    lines[#lines + 1] = "Mode: " .. (mp and "MULTIPLAYER" or "SINGLE PLAYER")

    -- ORIGIN IS NOT MODE, AND READING ONE AS THE OTHER COSTS REAL HOURS. A
    -- report that says only "MULTIPLAYER" invites the reader to assume it spans
    -- the session - client AND server. It cannot. On 2026-08-09 an investigation
    -- spent an afternoon testing "these are being thrown server-side by stale
    -- mod copies on the box" against a capture that was incapable of containing
    -- a server-side throw. Nothing in the header said so. Now it does.
    --
    -- WHY it cannot, from the 42.20.2 decompile - the mechanism, not the gates:
    -- getLuaDebuggerErrors() returns `new ArrayList<>(KahluaThread.m_errors_list)`
    -- (LuaManager.java:6432) and that list is STATIC (KahluaThread.java:99), so
    -- there is exactly one per JVM. A dedicated server is a different JVM, hence
    -- a different list. The `if isServer() then return end` lines at the top of
    -- this file, DFErrorPoller and DFReports are NOT what makes this true and
    -- must not be cited as if they were: GameServer.java:1386 loads the client
    -- directory as LoadDirBase("client", true) - onlyChecksum - and
    -- LuaManager.java:1208 skips RunLua in that mode, so client files never
    -- execute on a dedi at all. Those guards are belt-and-braces.
    --
    -- SINGLE PLAYER INVERTS IT. SP runs shared -> client -> server into one VM
    -- (GameLoadingState.enter():154), so one static ring holds both halves and
    -- "server-side" errors DO appear. Same report, opposite coverage.
    --
    -- The pointer matters as much as the caveat: server throws are not lost,
    -- they are elsewhere. flushErrorMessage() calls DebugType.General.error()
    -- BEFORE the ring add (KahluaThread.java:915), and DebugLog.java:233 picks
    -- the log name as `GameServer.server ? "DebugLog-server" : "DebugLog"`. So
    -- the server's copy is sitting in its own Logs directory. (The printed Java
    -- throwable is the one fragment debugException() does not route there -
    -- match on the message and the Lua trace, not the Java one.)
    if mp then
        lines[#lines + 1] = "Origin: CLIENT VM only - a server-VM throw cannot appear in this report."
        lines[#lines + 1] = "        Server-side traces live in the server's Logs/*_DebugLog-server.txt."
    else
        lines[#lines + 1] = "Origin: LOCAL VM - in SP client and server logic share one VM, so both appear."
    end

    if mp then
        local ck
        if pcall(function() ck = getServerOptions():getBoolean("DoLuaChecksum") end) and ck ~= nil then
            lines[#lines + 1] = "Lua Checksum: " .. tostring(ck)
        end
    end

    lines[#lines + 1] = "Captured: " .. nowStamp()

    -- MODS THE ENGINE HAS SEEN THROW, straight from its own bookkeeping.
    --
    -- PauseBuggedModList is a vanilla Lua global (ISPauseModListUI.lua:2) that the
    -- ENGINE writes into: LuaClosure.DebugInfo.generateModName and
    -- LuaClosure.toString2 both do `tab.rawset(mod.getName(), true)` whenever a
    -- stack trace touches modded code. Vanilla uses it to paint [ERRORS] beside a
    -- mod in the pause menu's list.
    --
    -- It is worth more than the tags we scrape: it is authoritative, it is
    -- maintained whether or not our poller was running, and it survives errors
    -- that happened before this buffer existed. Keyed by DISPLAY NAME, matching
    -- the attribution in DFErrorPoller.
    local bugged = {}
    pcall(function()
        if type(PauseBuggedModList) == "table" then
            for name in pairs(PauseBuggedModList) do bugged[#bugged + 1] = tostring(name) end
        end
    end)
    -- Scoped by the same wall as everything else above: PauseBuggedModList is
    -- written by the engine of THIS VM, so in MP a server-only offender never
    -- lands in it. Say which VM's bookkeeping this is, for the same reason the
    -- Origin line exists.
    if #bugged > 0 then
        table.sort(bugged)
        lines[#lines + 1] = "Mods the engine has seen throw"
            .. (mp and " (client VM)" or "") .. ": " .. table.concat(bugged, ", ")
    end

    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Buffer
-- ---------------------------------------------------------------------------

local function notify(entry, kind)
    -- foreign listeners; a subscriber fault must not break the log push
    for _, fn in ipairs(DFLog.listeners) do
        pcall(fn, entry, kind)
    end
end

-- Evict from the front, pruning the fingerprint index with it.
local function evict()
    while #DFLog.entries > DFLog.capacity do
        local gone = table.remove(DFLog.entries, 1)
        if gone and gone.key and DFLog.index[gone.key] == gone then
            DFLog.index[gone.key] = nil
        end
    end
end

-- Push a new entry.
--
-- Accepted fields: source, level, text, detail, key.
--   text   - required. One line; the strip and the list row draw this.
--   detail - optional multi-line payload for the console's detail pane.
--   key    - optional fingerprint enabling buffer-wide dedup (see header).
function DFLog.push(entry)
    if not entry or not entry.text then return end
    entry.source = entry.source or "Admin"
    entry.level  = entry.level  or "info"
    entry.time   = entry.time   or nowString()
    entry.stamp  = entry.stamp  or nowStamp()
    entry.first  = entry.time
    entry.count  = 1

    -- Keyed: collapse against any live entry with the same fingerprint.
    if entry.key then
        local hit = DFLog.index[entry.key]
        if hit then
            hit.count = (hit.count or 1) + 1
            hit.time  = entry.time
            hit.stamp = entry.stamp
            notify(hit, "update")
            return hit
        end
        DFLog.index[entry.key] = entry
    else
        -- Unkeyed: collapse only against the immediately preceding entry from
        -- the same source. RDCmdConsole's header explains why it wants this.
        local last = DFLog.entries[#DFLog.entries]
        if last and last.source == entry.source and last.text == entry.text
            and last.detail == entry.detail then
            last.count = (last.count or 1) + 1
            last.time  = entry.time
            last.stamp = entry.stamp
            notify(last, "update")
            return last
        end
    end

    DFLog.entries[#DFLog.entries + 1] = entry
    evict()
    notify(entry, "push")
    return entry
end

function DFLog.clear()
    DFLog.entries = {}
    DFLog.index   = {}
    notify(nil, "clear")
end

function DFLog.subscribe(fn)
    if type(fn) == "function" then
        DFLog.listeners[#DFLog.listeners + 1] = fn
    end
end

function DFLog.unsubscribe(fn)
    for i, existing in ipairs(DFLog.listeners) do
        if existing == fn then
            table.remove(DFLog.listeners, i)
            return
        end
    end
end

-- Filter by source prefix ("Admin", "Error", "Mod") or exact match.
-- Returns a shallow copy; safe to iterate while new entries arrive.
function DFLog.snapshot(filter)
    local out = {}
    for _, e in ipairs(DFLog.entries) do
        if not filter or filter == "" or filter == "all"
            or e.source == filter
            or string.sub(e.source, 1, #filter) == filter then
            out[#out + 1] = e
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- ONE LINE, for the bottom strip and for a list row. When an entry carries a
-- multi-line detail the count of hidden lines is stated rather than implied -
-- a truncated trace that looks complete is worse than one that says it is not.
function DFLog.headline(e)
    if not e then return "" end
    local count = (e.count and e.count > 1) and (" x" .. tostring(e.count)) or ""
    local more  = ""
    if e.detail then
        local n = 0
        for _ in string.gmatch(e.detail, "\n") do n = n + 1 end
        if n > 0 then more = "  (+" .. tostring(n) .. " more)" end
    end
    return string.format("[%s] [%s] %s%s%s",
        tostring(e.time or "--:--:--"),
        tostring(e.source or "?"),
        tostring(e.text or ""),
        more, count)
end

-- Backwards-compatible alias. Existing callers (the strip, copyAll) used this
-- name when a line was all an entry had.
DFLog.formatLine = DFLog.headline

-- THE FULL PAYLOAD, for the detail pane and for a copy. detail is authoritative
-- when present; text is its first line and would otherwise be duplicated.
function DFLog.detailText(e)
    if not e then return "" end
    return e.detail or e.text or ""
end

-- One entry, formatted for a bug report: context header, identity line, then
-- the untouched payload. Fenced so it survives a paste into Discord.
function DFLog.formatReport(e)
    if not e then return "" end
    local parts = { "```", DFLog.contextHeader() }
    parts[#parts + 1] = string.format("[%s] [%s]%s%s",
        tostring(e.stamp or e.time or "?"),
        tostring(e.source or "?"),
        (e.count and e.count > 1) and ("  x" .. tostring(e.count)) or "",
        (e.first and e.count and e.count > 1) and ("  first seen " .. tostring(e.first)) or "")
    parts[#parts + 1] = DFLog.detailText(e)
    parts[#parts + 1] = "```"
    return table.concat(parts, "\n")
end

local function toClipboard(text, okMsg)
    -- Clipboard is a static on a class that may be absent on some builds;
    -- failure is surfaced through DFFeedback below
    local ok = pcall(function() Clipboard.setClipboard(text) end)
    if not DFFeedback then return ok end
    if ok then DFFeedback.good(okMsg) else DFFeedback.bad("Clipboard copy failed.") end
    return ok
end

function DFLog.copyEntryToClipboard(e)
    if not e then return end
    local text = DFLog.formatReport(e)
    toClipboard(text, "Copied entry with build context.")
    return text
end

-- COPY ALL is the "here is everything, please help" action, so it is the one that
-- carries mod diagnostics. Per-entry copy deliberately does not: DFReports state
-- can run to thousands of characters, and stapling it to every single-trace copy
-- would bury the trace the reader actually asked for.
--
-- Guarded on the global rather than required, so deleting DFReports.lua removes
-- the section with no edit here.
function DFLog.copyAllToClipboard(filter)
    local snap  = DFLog.snapshot(filter)
    local parts = { "```", DFLog.contextHeader() }
    for i, e in ipairs(snap) do
        parts[#parts + 1] = string.format("=== #%d  [%s] [%s]%s ===",
            i, tostring(e.stamp or e.time or "?"), tostring(e.source or "?"),
            (e.count and e.count > 1) and ("  x" .. tostring(e.count)) or "")
        parts[#parts + 1] = DFLog.detailText(e)
        parts[#parts + 1] = ""
    end

    local reports = nil
    if DFReports and DFReports.collect then
        -- a collector fault costs its section, not the whole copy
        pcall(function() reports = DFReports.collect() end)
    end
    if reports then
        parts[#parts + 1] = reports
        parts[#parts + 1] = ""
    end

    parts[#parts + 1] = "```"
    local text = table.concat(parts, "\n")
    toClipboard(text, string.format("Copied %d entries with build context.", #snap))
    return text
end

-- Receive cross-admin broadcast pushes from the server.
local function onServerCommand(module, command, args)
    if module ~= "RFTDDragonfly" then return end   -- literal: DFCore lives in Dragonfly, which is optional now that this buffer is Core infrastructure; audits only flow when the panel mod is present
    if command ~= "LogBroadcast" or not args then return end
    DFLog.push(args)
end
Events.OnServerCommand.Add(onServerCommand)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
