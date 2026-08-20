-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQReflectLog - append-only writer for the truth-vs-seen reflection trace
-- (see client/RQReflect.lua for what gets traced and why).
--
-- Own plumbing instead of RQDirgeLog on purpose:
--   1. RQDirgeLog's master switch ships OFF and gates ~96 chatty call sites;
--      reflection has to run on ordinary players' clients, so its default
--      must be ON without re-enabling all of that.
--   2. getFileWriter is the only file API that works on BOTH sides in B42
--      (client sandbox silently blocks java.io and io.open).
--
-- Files land in Zomboid/Lua/:
--   Dirge_Reflect_CL.txt  on each client
--   Dirge_Reflect_SV.txt  on the server
-- Open-append-close per batch: a hard crash never loses written lines.
--
-- Every line is stamped with epoch ms AND a derived UTC clock. UTC, not
-- local time, so a client line and a server line from different machines
-- (and Discord timestamps, converted once) compare directly.

RQReflectLog = RQReflectLog or {}

local FILE = "Dirge_Reflect_" .. (isServer() and "SV" or "CL") .. ".txt"
local sessionMarked = false

local function stamp()
    local ms  = (getTimestampMs and getTimestampMs()) or 0
    local sec = math.floor(ms / 1000) % 86400
    local h   = math.floor(sec / 3600)
    local m   = math.floor((sec % 3600) / 60)
    local s   = sec % 60
    return "[" .. tostring(ms) .. "|" ..
        string.format("%02.0f:%02.0f:%02.0f", h, m, s) .. "z] "
end

function RQReflectLog.writeAll(lines)
    if not lines or #lines == 0 then return end
    -- getFileWriter logs open failures and returns nil. LuaFileWriter delegates
    -- write/close to PrintWriter, which records I/O failure internally rather
    -- than throwing it back through Lua; an exception guard here could only
    -- hide a programming error. LuaManager.java:5523-5556, 9850-9868.
    local writer = getFileWriter(FILE, true, true)
    if not writer then return end
    if not sessionMarked then
        sessionMarked = true
        writer:write("=== Dirge reflect session start " .. stamp() .. "===\n")
    end
    local ts = stamp()
    for i = 1, #lines do writer:write(ts .. lines[i] .. "\n") end
    writer:close()
end

function RQReflectLog.write(line)
    RQReflectLog.writeAll({ line })
end

Events.OnGameStart.Add(function() sessionMarked = false end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
