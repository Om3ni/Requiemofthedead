-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDClientPrefs - a flat key=value preference file, once, for any mod that
-- wants one.
--
-- WHY THIS EXISTS. RFTDLastRites/LRPrefs.lua and RFTDOddsAndEnds/OEPrefs.lua
-- were the same 97-line file twice, differing in the module name and the
-- filename and nothing else - OEPrefs' own header said so out loud ("Mirrors
-- RFTDLastRites/LRPrefs.lua exactly"). Two copies of a serializer is two places
-- for a format to drift, and a preference format that drifts loses settings
-- silently: the reader simply does not recognise the line and the default
-- stands. Promoted 2026-08-19 with both call surfaces unchanged.
--
-- WHY DFPrefs IS NOT A THIRD CONSUMER, since it is the obvious candidate and
-- folding it in would be wrong. DFPrefs shares the MECHANISM (a .txt of
-- key=value read back through getFileReader) but not the POLICY: it seeds a
-- fixed DEFAULTS table before reading, refuses any key not in it, stores only
-- integers, clamps opacity to a floor a person can still find the window at,
-- and writes with writeln instead of an explicit CRLF. Making this store carry
-- all of that would give it a defaults mode, a key allowlist, a numeric format
-- and a clamp hook - four switches to make one call site look like another,
-- which is CLAUDE.md sect. 11's "erases real differences between call sites"
-- exactly. DFPrefs keeps its own loader and this stays a plain store.
--
-- CLOSURES, NOT METHODS, so `LRPrefs.get(k, default)` keeps working with a dot.
-- A metatable instance would have needed a colon at fourteen call sites across
-- two mods, and a promotion whose whole point is that nothing else changes
-- should not start by rewriting every caller.

if isServer() then return end

require "RDFile"

RDClientPrefs = RDClientPrefs or {}

-- Format: one "key=value" per line, value "true" / "false" / a number.
--
-- Deliberately narrow. B42 exposes no io.open (only getFileReader and
-- getFileWriter), so this is hand-rolled, and hand-rolled parsers earn their
-- keep by refusing to grow: booleans and numbers are all a cosmetic toggle or a
-- pixel offset has ever needed, and anything richer belongs in RDJson.
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

-- Create a store bound to one file.
--
-- The name must end .txt: getFileWriter checks a CASE-SENSITIVE lowercase
-- allowlist of ini|cfg|txt|log|json and returns nil for anything else, silently
-- (LuaManager.java:1045, the contains() at :5526). Callers pass the whole
-- filename rather than a mod id
-- because the two existing files are already named and renaming one would
-- discard every preference a player has set.
function RDClientPrefs.store(filename)
    -- Loud, not defaulted. A store with no file is a store whose writes go
    -- nowhere, and finding that out at save() time means the settings were
    -- already lost.
    if type(filename) ~= "string" or filename == "" then
        error("RDClientPrefs.store: filename is required")
    end

    local cache = nil   -- nil until first load(); always a table afterwards
    local prefs = {}

    function prefs.load()
        cache = {}
        -- Bare, and this is the read lane rather than an omission.
        -- BufferedReader is an exposed class (LuaManager.java:1651), so a fault
        -- inside readLine is swallowed by MethodCaller and comes back as nil
        -- (MethodCaller.java:33-56) - which this loop already treats as end of
        -- file. A truncated read therefore keeps whatever parsed before it and
        -- lets the caller's defaults cover the rest, which is the recovery a
        -- guard here would have claimed to add.
        local r = getFileReader(filename, false)   -- false = don't create
        if not r then return cache end
        while true do
            local line = r:readLine()
            if line == nil then break end
            if line ~= "" then deserialize(line, cache) end
        end
        r:close()
        return cache
    end

    function prefs.save()
        if not cache then return end
        -- create = true, append = false: the file is a complete snapshot every
        -- time. Appending would grow it forever with stale lines that the
        -- reader then applies in order, so the last write would win by accident
        -- rather than by intent.
        --
        -- Mechanism in RDFile (2026-08-25). The literal \r\n stays: it is the
        -- byte format every existing player prefs file already carries, so
        -- the conversion preserves it exactly rather than trading it for the
        -- platform separator. In-memory state is kept either way.
        local parts = {}
        for k, v in pairs(cache) do
            local s = serializeValue(v)
            if s then parts[#parts + 1] = k .. "=" .. s .. "\r\n" end
        end
        RDFile.rewrite(filename, table.concat(parts))
    end

    -- get(key, default): the stored value, or `default` if unset.
    function prefs.get(key, default)
        if not cache then prefs.load() end
        local v = cache[key]
        if v == nil then return default end
        return v
    end

    -- set(key, value): updates the cache and persists immediately. Cheap - the
    -- file is a handful of lines and writes only happen on a settings change.
    function prefs.set(key, value)
        if not cache then prefs.load() end
        cache[key] = value
        prefs.save()
    end

    -- Load once at startup so the first get() never races a file read mid-frame.
    Events.OnGameStart.Add(function() prefs.load() end)

    return prefs
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
