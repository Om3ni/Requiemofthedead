-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RDFile.lua - the one open/write/close, stated once.
--
-- WHY (2026-08-25, owner-approved consolidation). Thirteen files hand-rolled
-- the same getFileWriter open/write/close - each differing just enough (a
-- directory prefix, a truncate flag, a per-mod failure counter) that
-- check-helpers could not see them as copies, which is exactly the shape of a
-- rule re-derived thirteen times instead of stated once. The mechanism now
-- lives here; what stays at each call site is POLICY - which path, which
-- extension convention (RDShared.EXT_*), and what that caller does when a
-- write reports false.
--
-- THE ENGINE FACTS the mechanism rests on, so no caller re-derives them:
--
--   * getFileWriter returns NIL - never throws - for a refused extension
--     (the ALLOWED_FILE_EXTENSIONS set, LuaManager.java:1045, gate :5526),
--     a relative-path escape, or a failed open (:5523-5555). That nil is the
--     only refusal signal there is.
--   * LuaFileWriter.write/close delegate to PrintWriter, which records I/O
--     errors on an internal flag rather than raising them
--     (LuaManager.java:9850-9868). A write that "succeeded" is a write the
--     JVM accepted, not a byte on disk; there is nothing more to check from
--     Lua, which is why the return value is about the OPEN.
--   * Reads have the SAME answer: the BufferedReader getFileReader hands
--     back is an exposed class (LuaManager.java:1651), so readLine on a
--     truncated or vanished file reads as early EOF through MethodCaller's
--     swallow (MethodCaller.java:33-56) - never a throw. The old "reads
--     throw, writes don't" doctrine is dead (corrected 2026-08-19).
--   * Truncate (append=false) is the only "delete" Lua has - there is no
--     rename or remove primitive.
--
-- OBSERVABILITY. Every refused open is counted, and the first refusal per
-- path prints once - a silent write layer is how the 42.20 allowlist change
-- destroyed two archives for a day without a line anywhere. Callers that keep
-- their own failure counters (RDLog's forensic ring, LMPersist's import
-- report) read the boolean; the shared counter is the floor under everyone.
-- =============================================

RDFile = RDFile or {}

RDFile.stats = { refused = 0 }
local refusedPaths = {}

local function reportRefused(path)
    RDFile.stats.refused = RDFile.stats.refused + 1
    if not refusedPaths[path] then
        refusedPaths[path] = true
        print("[RDFile] write REFUSED for '" .. tostring(path)
            .. "' - extension outside the allowlist, or the open failed. "
            .. "See RDShared's EXT_* header.")
    end
end

-- Append one line (a newline is added). Returns true when the open succeeded.
function RDFile.appendLine(path, line)
    local w = getFileWriter(path, true, true)
    if not w then reportRefused(path); return false end
    w:write(line .. "\n")
    w:close()
    return true
end

-- Append many lines under ONE open - the batch shape. A caller holding rows
-- in a loop wants this, not appendLine per row: one open per line is one
-- filesystem round trip per line.
function RDFile.appendMany(path, lines)
    local w = getFileWriter(path, true, true)
    if not w then reportRefused(path); return false end
    for i = 1, #lines do w:write(lines[i] .. "\n") end
    w:close()
    return true
end

-- Replace the whole file (truncate + write). `content` is written verbatim -
-- add your own trailing newline if the format wants one.
function RDFile.rewrite(path, content)
    local w = getFileWriter(path, true, false)
    if not w then reportRefused(path); return false end
    w:write(content)
    w:close()
    return true
end

-- Replace the whole file from a list of lines (newline after each).
function RDFile.rewriteLines(path, lines)
    local w = getFileWriter(path, true, false)
    if not w then reportRefused(path); return false end
    for i = 1, #lines do w:write(lines[i] .. "\n") end
    w:close()
    return true
end

-- Replace the whole file using writeln - the PLATFORM line separator
-- (System.lineSeparator via LuaFileWriter.writeln, LuaManager.java:9850) -
-- for files a human opens in Notepad: the prefs family. A bare LF renders
-- as one long line in default Windows tooling; BufferedReader.readLine
-- strips either on the way back, so the choice is about the human, not the
-- parser. Machine formats (jsonl, ledgers) keep the plain rewriteLines.
function RDFile.rewriteDoc(path, lines)
    local w = getFileWriter(path, true, false)
    if not w then reportRefused(path); return false end
    for i = 1, #lines do w:writeln(lines[i]) end
    w:close()
    return true
end

-- First line of a file, or nil when absent/unreadable - the two are
-- indistinguishable from Lua and every caller treats them the same.
function RDFile.readFirstLine(path)
    local r = getFileReader(path, false)
    if not r then return nil end
    local line = r:readLine()
    r:close()
    return line
end

-- Every line of a file, or nil when it cannot be opened (an EMPTY table means
-- an empty file - callers that care about the difference get to see it).
-- A truncated file simply ends early; that is the engine's answer, not ours.
function RDFile.readLines(path)
    local r = getFileReader(path, false)
    if not r then return nil end
    local out = {}
    local line = r:readLine()
    while line ~= nil do
        out[#out + 1] = line
        line = r:readLine()
    end
    r:close()
    return out
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
