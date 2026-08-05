-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDJson.lua - deterministic JSON encoder for Core's JSONL streams.
--
-- Descended from MMAudit.jsonEncode with its three inherited defects fixed:
--
--   1. fmtNum rounded EVERYTHING to 2 decimals (including XP totals). Here:
--      integers render %.0f, floats %.6f with trailing zeros trimmed. Neither
--      path can emit scientific notation, which was the original (correct)
--      motivation for the %.2f - Kahlua tostring() on a large double yields
--      "1.78E9", which is not JSON.
--   2. isArray returned true for EMPTY tables, so empty maps encoded as [].
--      Here an empty table encodes as {}; pass RDJson.EMPTY_ARR for the rare
--      genuine empty array.
--   3. jsonEscape covered 5 characters, so a raw control byte in a username
--      produced an invalid line. Here the named escapes are handled first and
--      every remaining control byte goes through a precomputed \u00XX table -
--      table-replacement gsub, no function callback needed.
--
-- Object keys are sorted, so identical states encode identically (diffable).
-- NaN and +/-inf encode as null: no valid JSON token exists for them and a
-- reader choking on "nan" mid-season is worse than a null.
--
-- KNOWN LIMITATION - six-decimal floor. fmtNum renders non-integers %.6f, so
-- any magnitude below 5e-7 (not 1e-6: %.6f rounds to nearest, so 9e-7 still
-- survives as 0.000001) collapses to "0" and is indistinguishable from a
-- genuine zero. More generally, anything needing a seventh fractional digit is
-- truncated: 0.123456789 renders "0.123457". This is deliberate - the whole
-- reason fmtNum exists is that Kahlua's tostring() emits "1.78E9" for large
-- doubles, which is not JSON, and a fixed-width render is the cheap way to
-- guarantee that never happens. Nothing the family logs today (coordinates,
-- XP totals, sandbox percentages) approaches the floor. If a consumer ever
-- does, widen the format here rather than special-casing at the call site.
--
-- ENCODER BOUNDS. encode() walks caller-supplied tables, and not every caller
-- pre-flattens: Core's own client-command path is safe because RDGuardian
-- serializes args before they arrive, but a satellite dispatcher that hands a
-- raw client args table to RDLog.forensic reaches this function directly. So
-- the walk is bounded three ways - depth, a node budget, and a path-scoped
-- cycle guard - on the same reasoning (and with the same shape) as
-- RDGuardian.serializeArgs. The limits here are looser than Guardian's because
-- this encodes real records rather than a debug string: they must never
-- truncate a legitimate chronicle payload, only a pathological one. Every
-- bound emits a valid JSON string, so a truncated record still parses -
-- tools/validate_jsonl.py stays meaningful.

RDJson = RDJson or {}

-- Sentinel: encodes as [] (an empty Lua table encodes as {}).
RDJson.EMPTY_ARR = setmetatable({}, { __RDJson_empty_array = true })

local CTRL = {}   -- control byte -> \u00XX, for everything without a named escape
for i = 1, 31 do
    CTRL[string.char(i)] = string.format("\\u%04x", i)
end

local function escape(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
         :gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
         :gsub("\b", "\\b"):gsub("\f", "\\f")
    s = s:gsub("[\1-\31]", CTRL)
    return s
end
RDJson.escape = escape

local function fmtNum(n)
    if n ~= n then return "null" end                      -- NaN
    if n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 9007199254740992 then
        return string.format("%.0f", n)
    end
    local s = string.format("%.6f", n)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end
RDJson.fmtNum = fmtNum

local function isArray(v)
    if getmetatable(v) == getmetatable(RDJson.EMPTY_ARR) then return true end
    local n = 0
    for k in pairs(v) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n > 0 and n == #v
end

-- Set so that no LEGITIMATE record can reach them, not to be tight. encode()
-- cannot tell a chronicle caller from a forensic one, and on the chronicle
-- path a truncated record is permanent data loss - strictly worse than the
-- pathological payload the bound exists to stop. The widest real producer is a
-- Memoir snapshot (perks + traits + several hundred known recipes), around
-- 1,500 nodes and three deep; these leave better than a 10x margin over that
-- while still hard-bounding a malicious one. RDGuardian's 4/400 is far tighter
-- because it builds a debug string, where truncating is free.
RDJson.MAX_DEPTH = 12
RDJson.MAX_NODES = 20000

-- `seen` is PATH-scoped (cleared on the way back up), not global to the walk:
-- the same table appearing twice as siblings is a DAG, not a cycle, and must
-- encode both times. RDJson.EMPTY_ARR is a shared sentinel that hits this case
-- constantly.
local function enc(v, depth, seen, budget)
    if v == nil then return "null" end

    -- Counted for EVERY value, not just tables: depth alone bounds a deeply
    -- nested payload but not a single table with a million scalar keys, which
    -- is the cheaper attack of the two to send.
    budget.n = budget.n - 1
    if budget.n < 0 then return '"<truncated>"' end

    local t = type(v)
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return fmtNum(v) end
    if t ~= "table" then return '"' .. escape(v) .. '"' end

    if depth <= 0 then return '"<max-depth>"' end
    if seen[v] then return '"<cycle>"' end
    seen[v] = true

    local out
    if isArray(v) then
        local a = {}
        for i, item in ipairs(v) do a[i] = enc(item, depth - 1, seen, budget) end
        out = "[" .. table.concat(a, ",") .. "]"
    else
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local a = {}
        for _, k in ipairs(keys) do
            a[#a + 1] = '"' .. escape(k) .. '":' .. enc(v[k], depth - 1, seen, budget)
        end
        out = "{" .. table.concat(a, ",") .. "}"
    end

    seen[v] = nil
    return out
end

function RDJson.encode(v)
    return enc(v, RDJson.MAX_DEPTH, {}, { n = RDJson.MAX_NODES })
end

return RDJson

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
