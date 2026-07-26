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

function RDJson.encode(v)
    if v == nil then return "null" end
    local t = type(v)
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return fmtNum(v) end
    if t == "table" then
        if isArray(v) then
            local out = {}
            for i, item in ipairs(v) do out[i] = RDJson.encode(item) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = {}
        for _, k in ipairs(keys) do
            out[#out + 1] = '"' .. escape(k) .. '":' .. RDJson.encode(v[k])
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return '"' .. escape(v) .. '"'
end

return RDJson
