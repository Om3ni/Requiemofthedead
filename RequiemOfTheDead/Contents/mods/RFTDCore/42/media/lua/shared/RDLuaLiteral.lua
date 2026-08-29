-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDLuaLiteral.lua - restricted Lua-literal parser: the data half of Lua,
-- with the code half physically absent.
--
-- Parses `return { ... }` (the `return` optional) where the grammar is tables,
-- strings, numbers, booleans and nil - recursive descent, depth-capped, no
-- metatables, no code execution. `--` line comments are tolerated (the only
-- comment form in the data this was written for); anything outside the grammar
-- is a parse error with a line number, not a surprise.
--
-- PROMOTED FROM LMImport 2026-08-26, on the second consumer (CLAUDE.md sect. 5):
--   * LMImport - PhunZones custom-layer imports. Admin-droppable text must
--     never execute as code on the server; the parser was born there for that
--     reason, and its policy header still tells that story.
--   * LSTours  - Longstrider's hand-editable client-local tour file, until
--     this promotion the suite's last live loadstring caller.
-- The engine forced the timing: 42.20.4-b0bbce05d5 removed `loadstring` AND
-- `loadstream` from the Lua environment - LuaCompiler.register is deleted and
-- its call is gone from J2SEPlatform.setupEnvironment (J2SEPlatform.java:53-67
-- in the 42.20.3 tree; the 42.20.4 tree ends the method at setupLibraryText).
-- Eval-on-data was already the family's forbidden move; now the primitive does
-- not exist. This file is the one way the family reads a Lua literal back.
--
-- Engine-free on purpose, stock Lua 5.1 only, so behavioural suites parse real
-- fixtures through the real code path (same contract as LMCore and RDJson).

RDLuaLiteral = RDLuaLiteral or {}

local MAX_DEPTH = 32

local function lineOf(text, pos)
    local _, n = text:sub(1, pos):gsub("\n", "")
    return n + 1
end

-- Skip whitespace and -- line comments (the only comment form tolerated;
-- block comments do not appear in the data this parses).
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

-- Parse `return { ... }` (the `return` optional).
-- Returns table or nil, "line N: why".
function RDLuaLiteral.parse(text)
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

return RDLuaLiteral

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
