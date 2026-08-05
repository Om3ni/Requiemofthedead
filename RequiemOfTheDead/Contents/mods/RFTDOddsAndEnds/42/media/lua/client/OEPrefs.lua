-- SPDX-License-Identifier: GPL-3.0-or-later
-- OEPrefs.lua  (client)
--
-- Tiny persistence layer for *client-side cosmetic preferences* - the player-
-- facing toggles O&E modules put on the vanilla Client panel (today:
-- Bookmark's "Welcome Message"). Outcome-affecting config is sandbox
-- options and never lives here.
-- Mirrors RFTDLastRites/LRPrefs.lua exactly - same format, same rationale.
--
-- B42 only exposes getFileWriter/getFileReader for Lua file I/O (io.open is
-- silently blocked), so we persist a flat key=value file. Values are limited to
-- booleans and numbers - all this UI needs - which keeps the (de)serializer
-- trivial and robust. The file lives in the per-user Zomboid dir, so prefs are
-- per-install (not per-save, not synced) - exactly right for cosmetic prefs.

OEPrefs = OEPrefs or {}

local FILE = "RFTDOddsAndEnds_clientprefs.txt"

-- In-memory cache. nil until first load(); always a table afterwards.
local cache = nil

-- ── (de)serialize ─────────────────────────────────────────
-- Format: one "key=value" per line. value is "true"/"false" or a number.
local function deserialize(line, store)
    local eq = string.find(line, "=", 1, true)
    if not eq then return end
    local key = string.sub(line, 1, eq - 1)
    local val = string.sub(line, eq + 1)
    if key == "" then return end
    if val == "true" then
        store[key] = true
    elseif val == "false" then
        store[key] = false
    else
        local n = tonumber(val)
        if n ~= nil then store[key] = n end
    end
end

local function serializeValue(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then return tostring(v) end
    return nil  -- unsupported types are skipped, never written
end

-- ── load / save ───────────────────────────────────────────
function OEPrefs.load()
    cache = {}
    local r = getFileReader(FILE, false)  -- false = don't create if missing
    if not r then return cache end
    while true do
        local line = r:readLine()
        if line == nil then break end
        if line ~= "" then deserialize(line, cache) end
    end
    r:close()
    return cache
end

function OEPrefs.save()
    if not cache then return end
    local w = getFileWriter(FILE, true, false)  -- create, don't append
    if not w then return end
    for k, v in pairs(cache) do
        local s = serializeValue(v)
        if s then w:write(k .. "=" .. s .. "\r\n") end
    end
    w:close()
end

-- ── accessors ─────────────────────────────────────────────
-- get(key, default): returns the stored value, or `default` if unset.
function OEPrefs.get(key, default)
    if not cache then OEPrefs.load() end
    local v = cache[key]
    if v == nil then return default end
    return v
end

-- set(key, value): updates the cache and persists immediately. Cheap - the
-- file is a handful of lines and writes only happen on a settings change.
function OEPrefs.set(key, value)
    if not cache then OEPrefs.load() end
    cache[key] = value
    OEPrefs.save()
end

-- Load once at startup so the first get() never races a file read mid-frame.
Events.OnGameStart.Add(function() OEPrefs.load() end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
