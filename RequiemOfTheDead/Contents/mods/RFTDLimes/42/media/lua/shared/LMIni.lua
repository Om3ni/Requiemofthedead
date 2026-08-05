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
        if z.inherits then
            out[#out + 1] = "inherits = " .. tostring(z.inherits) .. "\n"
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
