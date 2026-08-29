-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMIni - the .ini dialect: text <-> raw zones. Pure, shared, engine-free.
--
-- WHY THIS MOVED OUT OF LMPersist (2026-08-05). The parser and the serializer
-- were already written as a pure pair, and LMPersist's own header said so - but
-- they sat behind that file's `if not isServer() then return end`, so the CLIENT
-- had no way to read the format the server writes. The consequence was a
-- one-way door: the importer speaks PhunZones and only PhunZones, so an admin
-- could paste somebody else's export and have it accepted, but could not paste
-- back the file Limes itself had just written. Exporting a store you cannot
-- re-import is not a store, it is a leak.
--
-- Nothing else changed. LMPersist still owns the FILE - the jail, the journal,
-- the boot order, the backups - and delegates the string handling here.
--
-- THE GRAMMAR IS A CONTRACT, not an implementation detail. Sections match
-- [%w_%-%.]+ and keys match [%w_]+; anything else is dropped on the way back in
-- with no error, which is why LMEdit refuses to create such a name in the first
-- place (see LMEdit.NAME_PATTERN, and the test that reads this file to check
-- the two have not drifted).

require "RDJson"

LMIni = LMIni or {}

LMIni.HEADER = "; RFTDLimes zone store. Hand-editable; the server rewrites it on every\n"
            .. "; zone edit (sorted sections and keys - keep diffs clean, not comments:\n"
            .. "; lines starting with ; or # survive a reload but NOT the next rewrite).\n"

local function autoType(s)
    if s == "true"  then return true  end
    if s == "false" then return false end
    local n = tonumber(s)
    if n ~= nil then return n end
    return s
end

local function encodeValue(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number"  then return RDJson.fmtNum(v) end
    -- One line per key is the grammar; a value cannot carry the line breaks.
    return (tostring(v):gsub("[\r\n]", " "))
end

-- Does this text look like our .ini rather than a PhunZones export?
--
-- The first line that is neither blank nor a comment decides. An .ini opens
-- with a [Section]; a PhunZones export opens with `return {` or a bare `{`.
-- Deliberately a POSITIVE test for our own format: anything unrecognised falls
-- through to the PhunZones path, which is the one with the detailed parse
-- errors, so an admin pasting something malformed still gets told why rather
-- than being told it is not an .ini.
function LMIni.looksLikeIni(text)
    for line in tostring(text or ""):gmatch("([^\n]*)\n?") do
        line = line:gsub("\r$", "")
        if not (line:match("^%s*$") or line:match("^%s*[;#]")) then
            return line:match("^%s*%[[%w_%-%.]+%]%s*$") ~= nil
        end
    end
    return false
end

-- text -> rawZones, warnings
function LMIni.parse(text)
    local zones, warnings = {}, {}
    local cur, curName = nil, nil
    local lineNo = 0
    for line in tostring(text or ""):gmatch("([^\n]*)\n?") do
        lineNo = lineNo + 1
        line = line:gsub("\r$", "")
        local section = line:match("^%s*%[([%w_%-%.]+)%]%s*$")
        if section then
            if zones[section] then
                warnings[#warnings + 1] = "line " .. lineNo .. ": duplicate section ["
                    .. section .. "], merging"
                cur = zones[section]
            else
                cur = { inherits = nil, rects = {}, fields = {} }
                zones[section] = cur
            end
            curName = section
        elseif line:match("^%s*$") or line:match("^%s*[;#]") then
            -- blank or comment
        else
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if not key then
                warnings[#warnings + 1] = "line " .. lineNo .. ": unparseable, skipped: " .. line
            elseif not cur then
                warnings[#warnings + 1] = "line " .. lineNo .. ": '" .. key
                    .. "' before any [section], skipped"
            elseif key == "inherits" then
                if value ~= "" then cur.inherits = value end
            elseif key == "kind" then
                -- STRUCTURAL: the record-kind marker. "zone" and "" normalise
                -- to absent (absent = zone is the migration story); anything
                -- else is preserved verbatim so validate() can NAME an unknown
                -- kind instead of this parser silently discarding it.
                if value ~= "" and value ~= "zone" then cur.kind = value end
            elseif key == "tier" then
                -- STRUCTURAL: the tier slot, a record NAME - never autoTyped,
                -- because a store written before the slot existed says
                -- `tier = 5` and that must survive as the STRING "5" for the
                -- migration to map, not become a number the resolver cannot
                -- look up as a key.
                if value ~= "" then cur.tier = value end
            elseif key:match("^moon_") then
                -- The tier moon overlay, encoded flat: `moon_phases` is the
                -- gate, every other `moon_<key>` is an overlay dial. Flat
                -- keys rather than a sub-section keep "one section = one
                -- record" true for duplicate detection, sorting and identity;
                -- the JSON schema nests the same data as moon.{phases,fields}.
                -- Fields may not START with moon_ (LMEdit.keyProblem refuses
                -- them), so the prefix is unambiguous on the way back in.
                cur.moon = cur.moon or { fields = {} }
                if key == "moon_phases" then
                    if value ~= "" then cur.moon.phases = value end
                else
                    cur.moon.fields[key:sub(6)] = autoType(value)
                end
            elseif key == "profiles" then
                -- STRUCTURAL, like rects, and it must be: through the field
                -- fall-through this would land as one string - and worse,
                -- autoType would turn a single numeric-looking profile name
                -- into a NUMBER, silently. Comma-separated; zone names cannot
                -- contain a comma (the section grammar above is the proof), so
                -- the split is unambiguous. An empty value stays absent (rule
                -- 5: cleared means absent, not present-empty).
                for pname in value:gmatch("[^,]+") do
                    pname = pname:match("^%s*(.-)%s*$")
                    if pname ~= "" then
                        cur.profiles = cur.profiles or {}
                        cur.profiles[#cur.profiles + 1] = pname
                    end
                end
            elseif key == "rects" then
                for rect in value:gmatch("[^;]+") do
                    local x1, y1, x2, y2 = rect:match("^%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*$")
                    if x1 then
                        cur.rects[#cur.rects + 1] =
                            { tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2) }
                    else
                        warnings[#warnings + 1] = "line " .. lineNo .. ": [" .. tostring(curName)
                            .. "] bad rect '" .. rect .. "', skipped"
                    end
                end
            else
                cur.fields[key] = autoType(value)
            end
        end
    end
    return zones, warnings
end

-- rawZones -> deterministic text
function LMIni.serialize(rawZones)
    local names = {}
    for name in pairs(rawZones or {}) do names[#names + 1] = name end
    table.sort(names)

    local out = { LMIni.HEADER }
    for i = 1, #names do
        local name = names[i]
        local z = rawZones[name]
        out[#out + 1] = "\n[" .. name .. "]\n"
        if z.kind and z.kind ~= "zone" then
            out[#out + 1] = "kind = " .. tostring(z.kind) .. "\n"
        end
        if z.inherits then
            out[#out + 1] = "inherits = " .. tostring(z.inherits) .. "\n"
        end
        if z.tier then
            out[#out + 1] = "tier = " .. tostring(z.tier) .. "\n"
        end
        if z.profiles and #z.profiles > 0 then
            out[#out + 1] = "profiles = " .. table.concat(z.profiles, ",") .. "\n"
        end
        if z.rects and #z.rects > 0 then
            local parts = {}
            for j = 1, #z.rects do
                local r = z.rects[j]
                parts[j] = RDJson.fmtNum(r[1]) .. "," .. RDJson.fmtNum(r[2]) .. ","
                        .. RDJson.fmtNum(r[3]) .. "," .. RDJson.fmtNum(r[4])
            end
            out[#out + 1] = "rects = " .. table.concat(parts, " ; ") .. "\n"
        end
        if z.moon then
            if z.moon.phases and z.moon.phases ~= "" then
                out[#out + 1] = "moon_phases = " .. encodeValue(z.moon.phases) .. "\n"
            end
            local mkeys = {}
            for k in pairs(z.moon.fields or {}) do mkeys[#mkeys + 1] = k end
            table.sort(mkeys)
            for j = 1, #mkeys do
                out[#out + 1] = "moon_" .. mkeys[j] .. " = "
                    .. encodeValue(z.moon.fields[mkeys[j]]) .. "\n"
            end
        end
        local keys = {}
        for k in pairs(z.fields or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        for j = 1, #keys do
            out[#out + 1] = keys[j] .. " = " .. encodeValue(z.fields[keys[j]]) .. "\n"
        end
    end
    return table.concat(out)
end

return LMIni

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
