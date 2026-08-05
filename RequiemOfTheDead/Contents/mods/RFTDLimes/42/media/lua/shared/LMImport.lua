-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMImport.lua - one-way PhunZones custom-layer importer (both sides, §9).
--
-- Consumes the TEXT of a persisted PhunZones custom layer -
-- `return { version = 2, data = { ZoneName = {...}, ... } }` - and produces
-- LMCore raw zones. Runs from an admin command or the first-boot candidate
-- probe in LMPersist, writes the .ini, and is then done forever: Limes never
-- speaks a PhunZones format at runtime, and nothing in this file is called on
-- any per-tick or per-player path.
--
-- WHY A HAND-ROLLED PARSER and not loadstring: the input is a Lua literal, but
-- executing admin-droppable text as code on the server is a class of mistake,
-- not a convenience - and Kahlua's loadstring is not part of the family's
-- verified surface. The grammar actually present in the data (fixtures:
-- docs/dirge-phunzones.md, ~120 zones) is tables, strings, numbers, booleans
-- and nil, so that is the entire grammar parsed here: recursive descent,
-- depth-capped, no metatables, no code execution. Anything outside the grammar
-- is a parse error with a line number, not a surprise.
--
-- PROVENANCE (§2): this file translates DATA out of PhunZones' persisted
-- format. It contains no code derived from PhunZones; the format was read from
-- the live export, the mechanism is original.
--
-- Engine-free on purpose, same contract as LMCore: stock Lua 5.1 only, so the
-- behavioural suite parses the real fixture through the real code path.

LMImport = LMImport or {}

-- ---------------------------------------------------------------------------
-- Restricted Lua-literal parser
-- ---------------------------------------------------------------------------

local MAX_DEPTH = 32

local function lineOf(text, pos)
    local _, n = text:sub(1, pos):gsub("\n", "")
    return n + 1
end

-- Skip whitespace and -- line comments (the only comment form tolerated;
-- block comments do not appear in PhunZones output).
local function skipWs(text, pos)
    while true do
        local _, e = text:find("^[ \t\r\n]+", pos)
        if e then pos = e + 1 end
        local _, e2 = text:find("^%-%-[^\n]*", pos)
        if e2 then pos = e2 + 1 end
        if not e and not e2 then return pos end
    end
end

local parseValue

local function parseString(text, pos)
    local quote = text:sub(pos, pos)
    local out, i = {}, pos + 1
    while i <= #text do
        local c = text:sub(i, i)
        if c == "\\" then
            local n = text:sub(i + 1, i + 1)
            if     n == "n"  then out[#out + 1] = "\n"
            elseif n == "t"  then out[#out + 1] = "\t"
            elseif n == "r"  then out[#out + 1] = "\r"
            elseif n == "\\" then out[#out + 1] = "\\"
            elseif n == quote then out[#out + 1] = quote
            else out[#out + 1] = n end
            i = i + 2
        elseif c == quote then
            return table.concat(out), i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil, pos, "unterminated string"
end

local function parseTable(text, pos, depth)
    if depth > MAX_DEPTH then return nil, pos, "table nesting exceeds " .. MAX_DEPTH end
    local out, arrayN = {}, 0
    pos = pos + 1                                   -- past "{"
    while true do
        pos = skipWs(text, pos)
        local c = text:sub(pos, pos)
        if c == "" then return nil, pos, "unterminated table" end
        if c == "}" then return out, pos + 1 end

        local key = nil
        if c == "[" then                            -- [expr] = value
            local k, np, err = parseValue(text, pos + 1, depth + 1)
            if err then return nil, np, err end
            np = skipWs(text, np)
            if text:sub(np, np) ~= "]" then return nil, np, "expected ]" end
            np = skipWs(text, np + 1)
            if text:sub(np, np) ~= "=" then return nil, np, "expected = after ]" end
            key, pos = k, np + 1
        else
            local name, e = text:match("^([%a_][%w_]*)()%s*=", pos)
            if name and name ~= "true" and name ~= "false" and name ~= "nil" then
                key = name
                pos = text:find("=", e, true) + 1
            end
        end

        local v, np, err = parseValue(text, pos, depth + 1)
        if err then return nil, np, err end
        pos = np
        if key ~= nil then
            out[key] = v
        else
            arrayN = arrayN + 1
            out[arrayN] = v
        end

        pos = skipWs(text, pos)
        local sep = text:sub(pos, pos)
        if sep == "," or sep == ";" then
            pos = pos + 1
        elseif sep ~= "}" and sep ~= "" then
            return nil, pos, "expected , ; or }"
        end
    end
end

parseValue = function(text, pos, depth)
    pos = skipWs(text, pos)
    local c = text:sub(pos, pos)
    if c == "{" then
        return parseTable(text, pos, depth)
    elseif c == '"' or c == "'" then
        local s, np, err = parseString(text, pos)
        if err then return nil, np, err end
        return s, np
    elseif text:find("^true", pos) then
        return true, pos + 4
    elseif text:find("^false", pos) then
        return false, pos + 5
    elseif text:find("^nil", pos) then
        return nil, pos + 3
    else
        local num, e = text:match("^(%-?%d+%.?%d*)()", pos)
        if num then return tonumber(num), e end
        return nil, pos, "unexpected character '" .. c .. "'"
    end
end

-- Parse `return { ... }` (the `return` optional). Exposed for the tests.
-- Returns table or nil, "line N: why".
function LMImport.parseLua(text)
    if type(text) ~= "string" then return nil, "no text" end
    local pos = skipWs(text, 1)
    local _, e = text:find("^return", pos)
    if e then pos = e + 1 end
    local v, np, err = parseValue(text, pos, 1)
    if err then return nil, "line " .. lineOf(text, np) .. ": " .. err end
    if type(v) ~= "table" then return nil, "top level is not a table" end
    np = skipWs(text, np)
    if np <= #text then return nil, "line " .. lineOf(text, np) .. ": trailing content" end
    return v
end

-- ---------------------------------------------------------------------------
-- The mapping (§9). Key vocabulary as counted in the live dataset.
-- ---------------------------------------------------------------------------

-- PhunZones key -> Limes field, coerced to number ("" = unset, omitted).
local NUM_KEYS = {
    difficulty            = "tier",
    order                 = "order",
    minSprinterRisk       = "minSprinterRisk",
    maxSprinterRisk       = "maxSprinterRisk",
    dirgeSpawnChance      = "dirgeSpawnChance",
    dirgeScreamerWeight   = "dirgeScreamerWeight",
    dirgeJuggernautWeight = "dirgeJuggernautWeight",
    dirgeEMPWeight        = "dirgeEMPWeight",
    dirgeGluttonWeight    = "dirgeGluttonWeight",
    dirgeScavengerWeight  = "dirgeScavengerWeight",
    dirgeScreamerSpacing  = "dirgeScreamerSpacing",
    dirgeJuggernautSpacing = "dirgeJuggernautSpacing",
    dirgeEMPSpacing       = "dirgeEMPSpacing",
    dirgeGluttonSpacing   = "dirgeGluttonSpacing",
    dirgeScavengerSpacing = "dirgeScavengerSpacing",
}

local BOOL_KEYS = {
    nobuilding = true, nodestruction = true, nopickup = true, noplacing = true,
    noscrap = true, nosafehouse = true, nofire = true, noplayers = true,
    noannounce = true, disabled = true,
}

local STR_KEYS = { title = true, subtitle = true, lewtkey = true, zeds = true }

local function toBool(v)
    if v == true  or v == "true"  or v == 1 or v == "1" then return true  end
    if v == false or v == "false" or v == 0 or v == "0" then return false end
    return nil
end

-- text -> ok, { zones = {name -> raw zone}, warnings = {...}, count = n } | err
function LMImport.parsePhunZones(text)
    local parsed, perr = LMImport.parseLua(text)
    if not parsed then return false, "parse failed: " .. tostring(perr) end
    local data = parsed.data
    if type(data) ~= "table" then return false, "no data table in export" end

    local warnings = {}
    if parsed.version ~= 2 then
        warnings[#warnings + 1] = "export version is " .. tostring(parsed.version)
            .. ", expected 2 - importing anyway"
    end

    local zones, count = {}, 0
    for name, src in pairs(data) do
        name = tostring(name)
        if type(src) ~= "table" then
            warnings[#warnings + 1] = name .. ": not a table, skipped"
        elseif not name:match("^[%w_%-%.]+$") then
            warnings[#warnings + 1] = name .. ": name unusable as an .ini section, skipped"
        else
            local rects, fields = {}, {}
            for i, p in ipairs(src.points or {}) do
                local x1, y1, x2, y2 = tonumber(p and p[1]), tonumber(p and p[2]),
                                       tonumber(p and p[3]), tonumber(p and p[4])
                if x1 and y1 and x2 and y2 then
                    rects[#rects + 1] = { x1, y1, x2, y2 }
                else
                    warnings[#warnings + 1] = name .. ": points[" .. i .. "] is not four numbers, skipped"
                end
            end

            for k, v in pairs(src) do
                if k == "points" or k == "inherits" then
                    -- handled outside the field map
                elseif NUM_KEYS[k] then
                    if v ~= "" then
                        local n = tonumber(v)
                        if n ~= nil then
                            fields[NUM_KEYS[k]] = n
                        else
                            warnings[#warnings + 1] = name .. "." .. k .. " = '"
                                .. tostring(v) .. "' is not a number, omitted"
                        end
                    end
                elseif BOOL_KEYS[k] then
                    local b = toBool(v)
                    if b ~= nil then
                        fields[k] = b
                    elseif v ~= "" then
                        warnings[#warnings + 1] = name .. "." .. k .. " = '"
                            .. tostring(v) .. "' is not a boolean, omitted"
                    end
                elseif STR_KEYS[k] then
                    fields[k] = tostring(v)
                    if k == "zeds" and v ~= "remove" and v ~= "none" then
                        warnings[#warnings + 1] = name .. ".zeds = '" .. tostring(v)
                            .. "' (expected remove|none), kept as-is"
                    end
                elseif type(v) == "table" then
                    -- The .ini is flat; a nested unknown cannot survive the
                    -- round trip, so "preserved verbatim" is impossible - drop
                    -- loudly rather than pretend.
                    warnings[#warnings + 1] = name .. "." .. tostring(k)
                        .. ": unknown table-valued key cannot be preserved in the .ini, dropped"
                else
                    fields[k] = v
                    warnings[#warnings + 1] = name .. "." .. tostring(k)
                        .. ": unknown key, preserved verbatim"
                end
            end

            local inh = src.inherits
            if inh ~= nil and inh ~= "" then inh = tostring(inh) else inh = nil end
            zones[name] = { inherits = inh, rects = rects, fields = fields }
            count = count + 1
        end
    end

    -- Inheritance targets stay by-name (§9: kept, not flattened); a dangling
    -- parent surfaces here at import rather than as a resolver warning later.
    for name, z in pairs(zones) do
        if z.inherits and not zones[z.inherits] then
            warnings[#warnings + 1] = name .. " inherits '" .. z.inherits
                .. "', which is not in this import"
        end
    end

    table.sort(warnings)
    return true, { zones = zones, warnings = warnings, count = count }
end

return LMImport

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
