-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFErrorPoller - taps getLuaDebuggerErrors() and pushes new lines to DFLog.
--
-- Polls on OnTickEvenPaused so errors surface even when the game is paused or
-- in a menu. Dedup is by hash of the raw string; identical errors don't spam
-- the buffer (DFLog.push handles repeat counting).
--
-- If an error line carries a ((MOD:modid)) attribution tag, the source becomes
-- "Mod:<id>"; otherwise it's just "Error".

if isServer() then return end

DFErrorPoller = DFErrorPoller or { seen = {}, seenCount = 0, lastSize = 0, lastTail = nil, tick = 0 }

local function extractModTag(text)
    local tag = string.match(tostring(text or ""), "%(%(MOD:([^)]+)%)%)")
    if tag and tag ~= "" then return "Mod:" .. tag end
    return "Error"
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

-- Collapse multi-line stack traces into a single readable line so the log
-- strip (which uses drawText without newline-awareness) doesn't render
-- every line at the same Y coordinate. We keep the most informative head
-- (first non-empty line + first "Caused by" if present) and drop the
-- repeating Java frames - those are still in the server console log if
-- anyone needs the full trace.
local function normalize(text)
    if not text then return "" end
    local clean = string.gsub(tostring(text), "[\r\n]+", " | ")
    clean = string.gsub(clean, "%s+", " ")
    if #clean > 240 then clean = string.sub(clean, 1, 237) .. "..." end
    return clean
end

-- THE BUG THIS REPLACES, because it looked reasonable and was silently fatal:
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
-- Two identical consecutive errors read as no change, which is fine - `seen`
-- would have suppressed the second anyway.
--
-- Throttled because getLuaDebuggerErrors() returns `new ArrayList<>(...)`, a fresh
-- 40-element copy on every call; at OnTickEvenPaused rates that is pure GC churn
-- for something nobody needs frame-accurate.
local POLL_INTERVAL = 10
local SEEN_LIMIT    = 200

local function poll()
    if not DFLog then return end

    DFErrorPoller.tick = (DFErrorPoller.tick or 0) + 1
    if DFErrorPoller.tick % POLL_INTERVAL ~= 0 then return end

    local errors
    local ok = pcall(function() errors = getLuaDebuggerErrors() end)
    if not ok or not errors then return end

    local size = 0
    pcall(function() size = errors:size() end)
    if size <= 0 then return end

    local tail
    pcall(function() tail = tostring(errors:get(size - 1)) end)
    if size == DFErrorPoller.lastSize and tail == DFErrorPoller.lastTail then return end
    DFErrorPoller.lastSize = size
    DFErrorPoller.lastTail = tail

    -- `seen` only ever needs to cover the 40 entries the ring can hold; letting it
    -- grow unbounded across a long session is a slow leak. Resetting risks
    -- re-pushing at most those 40.
    if DFErrorPoller.seenCount and DFErrorPoller.seenCount > SEEN_LIMIT then
        DFErrorPoller.seen = {}
        DFErrorPoller.seenCount = 0
    end

    for i = 0, size - 1 do
        local entry
        pcall(function() entry = errors:get(i) end)
        if entry then
            local raw  = tostring(entry)
            local hash = #raw .. ":" .. string.sub(raw, 1, 80)
            if not DFErrorPoller.seen[hash] then
                DFErrorPoller.seen[hash] = true
                DFErrorPoller.seenCount = (DFErrorPoller.seenCount or 0) + 1
                DFLog.push{
                    source = extractModTag(raw),
                    level  = levelFor(raw),
                    text   = normalize(raw),
                }
            end
        end
    end
end

Events.OnTickEvenPaused.Add(poll)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
