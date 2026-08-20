-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFErrorPoller - taps getLuaDebuggerErrors() and pushes new EVENTS to DFLog.
--
-- Polls on OnTickEvenPaused so errors surface even when the game is paused or
-- in a menu.
--
-- ===========================================================================
-- ONE ERROR IS NOT ONE RING ENTRY. This is the whole reason this file exists in
-- its current shape, and it is a property of the engine, not a guess.
--
-- getLuaDebuggerErrors() returns a copy of KahluaThread.m_errors_list. That list
-- is appended to from exactly three places (verified in the 42.20.2 decompile):
--
--   flushErrorMessage()          KahluaThread.java:913  - one add of whatever
--                                startErrorMessage()/append built
--   debugException(Throwable)    KahluaThread.java:945  - one add of a printed
--                                Java stack trace
--   doStacktraceProper(frame)    KahluaThread.java:923  - builds "dumping Lua
--                                stack trace\n..." and calls flushErrorMessage
--
-- And they are called in SEQUENCE for a single logical error:
--
--   :677-678, :865-866   debugException(ex)  THEN  doStacktraceProper(frame)
--   :1097-1101           flushErrorMessage() THEN  doStacktraceProper()
--                        then `throw new RuntimeException(...)` - which is
--                        caught upstream at :677 and runs that pair too
--
-- So indexing a nil emits FOUR adjacent entries for one mistake:
--
--   1  "attempted index: foo of non-table: nil"      (flushErrorMessage)
--   2  "dumping Lua stack trace ..."                 (doStacktraceProper)
--   3  "java.lang.RuntimeException: attempted index: foo of non-table: nil ..."
--                                                    (debugException)
--   4  "dumping Lua stack trace ..."                 (doStacktraceProper)
--
-- The old code pushed each of those as its own DFLog line, each flattened to a
-- single 240-char string. One `nil.foo` therefore arrived in the console as four
-- unrelated smears with the actual message truncated away. That is the bug this
-- rewrite fixes.
--
-- REASSEMBLY RULES, derived from the call sites above rather than pattern-
-- matched hopefully:
--
--   * A Lua trace ("dumping Lua stack trace") is a CONTINUATION - it is always
--     emitted immediately after the thing it describes. It joins the open event
--     when that event's last fragment is a message or a Java trace. When the
--     last fragment is ALREADY a Lua trace, a second one means a new error
--     (:1131 emits a standalone trace before its assert), so we start a new
--     event instead of gluing unrelated errors together.
--
--   * A Java trace joins the open event only when its exception message is
--     quoted by that event's head - which is exactly the :1102 case, where the
--     RuntimeException repeats the "attempted index:" text verbatim. Otherwise
--     it starts its own event. Deliberately strict: a wrongly SPLIT event still
--     shows the operator everything, a wrongly MERGED one attributes a trace to
--     the wrong error.
--
--   * Anything else is a head, and always starts a new event.
--
-- Fragments of one error are all emitted inside a single Java call stack, so
-- they cannot straddle a poll boundary. The ring is reassembled whole on each
-- poll and events are deduplicated by fingerprint.
-- ===========================================================================
--
-- If an error carries a ((MOD:modid)) attribution tag the source becomes
-- "Mod:<id>"; otherwise it is "Error". An event that names a file living in
-- media/lua/server/ is additionally tagged [SERVER-FOLDER] - see the folder
-- origin section below for what that means and why it is worth saying.

if isServer() then return end

DFErrorPoller = DFErrorPoller or { seen = {}, seenCount = 0, lastSize = 0, lastTail = nil, tick = 0 }

local POLL_INTERVAL = 10
local SEEN_LIMIT    = 200
local HEADLINE_MAX  = 200    -- one-line summary cap; the full text survives in `detail`
local FINGERPRINT   = 200    -- chars of assembled text that decide event identity

-- ---------------------------------------------------------------------------
-- Classification
-- ---------------------------------------------------------------------------

local function isLuaTrace(s)
    return string.find(s, "dumping Lua stack trace", 1, true) ~= nil
end

-- A printed Java throwable starts with a fully-qualified class name. Matching
-- the SHAPE (dotted package path then Exception/Error/Throwable) rather than a
-- list of class names, so an exception type we have never seen still classifies.
local function isJavaTrace(s)
    local head = string.match(s, "^%s*([^\r\n]*)") or ""
    if string.find(head, "^%s*at ") then return true end
    if string.match(head, "^%s*[%w_%.%$]+%.[%w_%$]*Exception") then return true end
    if string.match(head, "^%s*[%w_%.%$]+%.[%w_%$]*Error[:%s]") then return true end
    if string.match(head, "^%s*[%w_%.%$]+%.[%w_%$]*Throwable") then return true end
    return false
end

-- The message half of a Java throwable line: everything after the first ": ".
-- Used only to decide whether a trace belongs to the open event, so a short or
-- absent message returns nil and the trace becomes its own event.
local function javaMessage(s)
    local head = string.match(s, "^%s*([^\r\n]*)") or ""
    local msg  = string.match(head, "^[^:]+:%s*(.+)$")
    if msg and #msg >= 12 then return msg end
    return nil
end

local KIND_HEAD, KIND_LUA, KIND_JAVA = 1, 2, 3

local function classify(s)
    if isLuaTrace(s)  then return KIND_LUA  end
    if isJavaTrace(s) then return KIND_JAVA end
    return KIND_HEAD
end

-- ---------------------------------------------------------------------------
-- Reassembly
-- ---------------------------------------------------------------------------

-- Group an ordered list of raw ring entries into logical events.
-- Returns an array of assembled multi-line strings.
local function reassemble(raw)
    local events = {}
    local cur, curKinds = nil, nil

    local function close()
        if cur then events[#events + 1] = table.concat(cur, "\n") end
        cur, curKinds = nil, nil
    end

    local function open(s, kind)
        close()
        cur, curKinds = { s }, { kind }
    end

    for _, s in ipairs(raw) do
        local kind = classify(s)

        if kind == KIND_LUA then
            local lastKind = curKinds and curKinds[#curKinds]
            if cur and lastKind ~= KIND_LUA then
                cur[#cur + 1] = s
                curKinds[#curKinds + 1] = kind
            else
                open(s, kind)
            end

        elseif kind == KIND_JAVA then
            local msg = javaMessage(s)
            if cur and msg and string.find(cur[1], msg, 1, true) then
                cur[#cur + 1] = s
                curKinds[#curKinds + 1] = kind
            else
                open(s, kind)
            end

        else
            open(s, kind)
        end
    end

    close()
    return events
end

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------

-- Tabs to spaces so the detail pane's fixed advance lines up, and the engine's
-- 61-dash rules dropped - they are frame decoration around a message that is
-- about to be framed by the UI anyway.
local function tidy(s)
    s = string.gsub(tostring(s or ""), "\r\n", "\n")
    s = string.gsub(s, "\r", "\n")
    s = string.gsub(s, "\t", "    ")
    s = string.gsub(s, "\n%-%-%-%-%-+\n", "\n")
    s = string.gsub(s, "^%-%-%-%-%-+\n", "")
    s = string.gsub(s, "\n%-%-%-%-%-+$", "")
    s = string.gsub(s, "\n\n\n+", "\n\n")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

-- First non-empty line, capped. This is what the strip and the list row show;
-- the console's detail pane renders the whole thing.
local function headlineOf(s)
    for line in string.gmatch(s, "[^\n]+") do
        local t = string.gsub(line, "^%s+", "")
        t = string.gsub(t, "%s+$", "")
        if t ~= "" then
            if #t > HEADLINE_MAX then t = string.sub(t, 1, HEADLINE_MAX - 3) .. "..." end
            return t
        end
    end
    return "(empty error)"
end

-- Identity of an event. Whitespace-collapsed prefix, so the same fault from the
-- same call site collapses even when a trailing frame differs, while two
-- genuinely different faults stay apart.
local function fingerprintOf(s)
    local flat = string.gsub(s, "%s+", " ")
    return string.sub(flat, 1, FINGERPRINT)
end

-- THE TAG IS SINGLE-PARENTHESISED, AND IT IS A DISPLAY NAME. Both facts were
-- wrong here until 2026-08-08, and the consequence was total: this matched
-- `((MOD:x))` with DOUBLED parentheses, which the engine never writes, so the
-- pattern never fired and every error in the console was sourced "Error". Mod
-- attribution looked implemented and was dead.
--
-- What the engine actually emits, both verified in the 42.20.2 decompile:
--
--   "(MOD:<name>)"      LuaClosure.DebugInfo.generateModName (:167). This becomes
--                       the StackTraceElement's declaring class, so it appears on
--                       every trace line that ran modded code.
--   "| MOD: <name>"     LuaClosure.toString2 (:59), the other trace formatter.
--                       No parentheses; runs to end of line.
--
-- In BOTH cases the value is `mod.getName()` - the mod's DISPLAY NAME, not its
-- id. So this yields "Mod:Requiem of the Dead: Dragonfly", not "Mod:Dragonfly".
-- Do not "fix" that by assuming an id; nothing in the trace carries one.
--
-- The single-paren pattern also matches the doubled legacy form as a side effect
-- (it finds the inner pair), so an older build that did write `((MOD:x))` still
-- attributes correctly with no second pattern.
local function extractModTag(text)
    local t = tostring(text or "")

    local tag = string.match(t, "%(MOD:([^)]+)%)")
    if not tag then tag = string.match(t, "|%s*MOD:%s*([^\r\n|]+)") end

    if tag then
        tag = string.gsub(tag, "^%s+", "")
        tag = string.gsub(tag, "%s+$", "")
        if tag ~= "" then return "Mod:" .. tag end
    end
    return "Error"
end

-- ---------------------------------------------------------------------------
-- Folder origin - "this trace ran server/ code inside a client"
-- ---------------------------------------------------------------------------
--
-- WHAT THIS DETECTS, and what it deliberately does not. It does NOT recover
-- server-VM errors; nothing client-side can (DFLog.contextHeader carries the
-- mechanism). It detects the INVERSE, which is a real and silent bug class:
--
-- THE ENGINE LOADS media/lua/server/ INTO CLIENTS TOO. GameLoadingState.enter()
-- calls LuaManager.LoadDirBase("server") with no GameClient.client guard
-- (:154, verified in the 42.20.2 decompile). That is precisely why every server
-- file in this family opens with `if not isServer() then return end` - RDLog:87,
-- RDLife:48, RDGuardian:75, RDMeter:49, RDCmdRelay:39. Those gates are load-
-- bearing, not symmetry. A server file that forgets one runs inside every
-- client, and when it throws, the trace arrives here looking like an ordinary
-- client error with nothing to distinguish it.
--
-- THE FOLDER IS NOT IN THE TRACE, so it has to come from somewhere else. A
-- frame renders as
--     Lua((MOD:Some Mod)).someFunc(SomeFile.lua:42)
-- because StackTraceElement's file is Prototype.file, and the compiler sets
-- that to the BASENAME: LuaManager.java:1335 takes the substring after the last
-- slash into FuncState.currentFile, and FuncState.java:1066 copies it to
-- f.file. The full path does exist - Prototype.filename, LuaManager.java:1336 /
-- FuncState.java:1067, reachable from Lua as getFilenameOfCallframe /
-- getFilenameOfClosure (LuaManager.java:5945, :5953) - but both need a live
-- callframe or closure, and those are long gone by the time an error is a
-- string in the ring. Scraping cannot get at it.
--
-- So the map is built from the OTHER end: getLoadedLuaCount() / getLoadedLua(i)
-- walk LuaManager.loaded (:3769, :3774), an ArrayList of every path this VM has
-- actually run - absolute and forward-slashed (:1332, :1373). Basename -> which
-- folder, derived at runtime, for every mod installed. No hand-maintained list
-- to rot, and third-party offenders are caught as readily as our own.
--
-- AMBIGUITY IS SILENCE. Two mods may ship the same basename in different
-- folders. Any name seen anywhere outside server/ is struck out of the set, so
-- a collision yields no tag rather than a confident wrong one.
--
-- MP ONLY. In singleplayer server/ code running in this VM is not a defect, it
-- is how SP works - every server file would trip the check and the tag would be
-- pure noise. Gated on isClient().
--
-- Built LAZILY, on the first error event rather than at boot: it is one pass
-- over every loaded Lua file, which on a heavily modded server is thousands of
-- entries, and there is no reason to spend that on a session that never throws.

local folderMP        = nil   -- nil = undecided; false disables the whole check
local folderServer    = nil   -- basename -> true, seen ONLY under media/lua/server/
local folderElsewhere = nil   -- basename -> true, seen anywhere else
local folderCount     = -1    -- getLoadedLuaCount() the map was built from

-- This poller reads stable engine-owned snapshots. A poller defect must surface
-- through the normal event path; silently turning it into "no data" would hide
-- the very observability failure this module exists to expose.
local function folderMapReady()
    if folderMP == nil then
        folderMP = isClient() == true
    end
    if not folderMP then return false end

    -- No guard: getLoadedLuaCount (LuaManager:3769) is loaded.size() on a static
    -- list. The type check below still covers an empty or absent registry.
    local count = getLoadedLuaCount()
    if type(count) ~= "number" or count <= 0 then return false end
    -- reloadLuaFile can append, so rebuild when the count moves.
    if folderServer and count == folderCount then return true end

    local srv, other = {}, {}
    for i = 0, count - 1 do
        -- reloadLuaFile removes and reloads synchronously (LuaManager.java:3521-3529).
        -- This loop cannot yield, so its captured loaded.size() bounds every index.
        local path = getLoadedLua(i)
        if path then
            path = string.lower(string.gsub(tostring(path), "\\", "/"))
            local base = string.match(path, "([^/]+)$")
            if base then
                if string.find(path, "/media/lua/server/", 1, true) then
                    srv[base] = true
                else
                    other[base] = true
                end
            end
        end
    end

    folderServer, folderElsewhere, folderCount = srv, other, count
    return true
end

-- Server-folder basenames named anywhere in an assembled event, sorted and
-- de-duplicated. Returns nil when there are none, so callers can skip cheaply.
--
-- Matches any "<name>.lua" token rather than only the "(File.lua:42)" frame
-- shape: the engine has a second trace formatter (LuaClosure.toString2, which
-- writes "-- file: X line # n") and an event may carry either. A name only
-- counts once it survives the server/-and-nowhere-else test, so the loose scan
-- costs nothing in precision.
local function serverFolderFilesIn(text)
    if not folderMapReady() then return nil end

    local hits, seen = nil, {}
    for name in string.gmatch(text, "[%w_%-%.]+%.lua") do
        local key = string.lower(name)
        if folderServer[key] and not folderElsewhere[key] and not seen[key] then
            seen[key] = true
            hits = hits or {}
            hits[#hits + 1] = name
        end
    end
    if hits then table.sort(hits) end
    return hits
end

local function levelFor(text)
    local t = tostring(text or "")
    if string.find(t, "ERROR", 1, true) or string.find(t, "Exception", 1, true)
        or string.find(t, "java.lang.", 1, true) then
        return "error"
    end
    if string.find(t, "WARN", 1, true) then return "warn" end
    return "info"
end

-- ---------------------------------------------------------------------------
-- Poll
-- ---------------------------------------------------------------------------
--
-- THE BUG THIS GATE REPLACES, because it looked reasonable and was silently fatal:
-- the old gate was `if size == lastSize then return end`. getLuaDebuggerErrors
-- reads KahluaThread.m_errors_list, which is a RING CAPPED AT 40
-- (KahluaThread.java:916 - `while (m_errors_list.size() >= 40) remove(0)`), so
-- once a session has produced 40 errors the size is pinned at 40 forever and that
-- gate returns early on every subsequent tick. Errors were captured until the
-- buffer saturated and then never again - "sometimes it dumps a stack trace,
-- sometimes it doesn't".
--
-- Detect change by the TAIL entry instead: a new error always appends there.
-- One Java call per poll instead of forty, and it stays correct once size pins.
-- Two identical consecutive errors read as no change, which is fine - the
-- fingerprint set would have suppressed the second anyway.
--
-- Throttled because getLuaDebuggerErrors() returns `new ArrayList<>(...)`, a fresh
-- 40-element copy on every call; at OnTickEvenPaused rates that is pure GC churn
-- for something nobody needs frame-accurate.

local function poll()
    if not DFLog then return end

    DFErrorPoller.tick = (DFErrorPoller.tick or 0) + 1
    if DFErrorPoller.tick % POLL_INTERVAL ~= 0 then return end

    -- No guard: getLuaDebuggerErrors (LuaManager:6432) copies KahluaThread's
    -- static m_errors_list into a fresh ArrayList - there is no receiver to be nil.
    local errors = getLuaDebuggerErrors()
    if not errors then return end

    local size = errors:size()
    if size <= 0 then return end

    local tail = tostring(errors:get(size - 1))
    if size == DFErrorPoller.lastSize and tail == DFErrorPoller.lastTail then return end
    DFErrorPoller.lastSize = size
    DFErrorPoller.lastTail = tail

    -- `seen` only ever needs to cover the events the 40-entry ring can hold; letting
    -- it grow unbounded across a long session is a slow leak. Resetting risks
    -- re-pushing at most what the ring currently holds.
    if DFErrorPoller.seenCount and DFErrorPoller.seenCount > SEEN_LIMIT then
        DFErrorPoller.seen = {}
        DFErrorPoller.seenCount = 0
    end

    -- Snapshot the ring, then reassemble fragments into events BEFORE dedup -
    -- deduplicating fragments would defeat the grouping.
    local raw = {}
    for i = 0, size - 1 do
        local entry = errors:get(i)
        if entry then raw[#raw + 1] = tidy(entry) end
    end
    if #raw == 0 then return end

    for _, event in ipairs(reassemble(raw)) do
        if event ~= "" then
            local key = fingerprintOf(event)
            if not DFErrorPoller.seen[key] then
                DFErrorPoller.seen[key] = true
                DFErrorPoller.seenCount = (DFErrorPoller.seenCount or 0) + 1

                -- Fingerprint and dedup stay on the UNTAGGED event, so turning
                -- this check on or off can never split one error into two rows.
                local text, detail = headlineOf(event), event
                local srvFiles = serverFolderFilesIn(event)
                if srvFiles then
                    text   = "[SERVER-FOLDER] " .. text
                    detail = "!! This trace names code from media/lua/server/ - "
                        .. table.concat(srvFiles, ", ")
                        .. "\n!! and it threw in the CLIENT VM. The engine loads server/"
                        .. " into clients too, so a file missing its\n"
                        .. "!! `if not isServer() then return end` gate executes here."
                        .. " Check that gate before reading further.\n\n"
                        .. event
                end

                DFLog.push{
                    source = extractModTag(event),
                    level  = levelFor(event),
                    text   = text,
                    detail = detail,
                    key    = "err:" .. key,
                }
            end
        end
    end
end

Events.OnTickEvenPaused.Add(poll)

-- Exposed for the console's "Test error" button, which needs to prove the whole
-- chain is alive, and for anything else that wants a forced re-scan.
function DFErrorPoller.pollNow()
    DFErrorPoller.tick = POLL_INTERVAL - 1
    poll()
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
