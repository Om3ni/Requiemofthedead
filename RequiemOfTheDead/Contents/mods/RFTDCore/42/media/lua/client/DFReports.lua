-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFReports - mods volunteer their own diagnostic state for bug reports
-- (client only).
--
-- A mod registers a function that returns whatever it thinks a reader would need
-- to understand its behaviour. Nothing is collected until somebody copies a
-- console report, so a registered report costs one table entry until the moment
-- it is useful.
--
-- ===========================================================================
-- WHY THIS EXISTS: the family had exactly one instance of it, pointed at the
-- wrong place. RFTDHusbandry shipped HBErrorMagnifier.lua, which registered its
-- keep-alive counters as a debug report with the THIRD-PARTY Error Magnifier
-- mod - so our diagnostics only reached a reader if that mod happened to be
-- installed, and they landed in its window rather than ours. That file was
-- deleted when the console moved into Core; this is where the idea belongs.
--
-- The value is not the registry, it is what ends up on the clipboard. A stack
-- trace tells you what broke. A stack trace plus "the keep-alive last ticked
-- 40 minutes ago" tells you why.
-- ===========================================================================
--
-- A REPORT MUST NOT BE ABLE TO BREAK A COPY. Every report function runs inside a
-- pcall and a failure is recorded in its own slot as text - a mod whose
-- diagnostics throw still lets every other mod's through, and the failure itself
-- is worth reading. Serialization is bounded in depth and node count for the
-- same reason it is in RDGuardian: report state is arbitrary, may hold Java
-- objects or cycles, and a clipboard action must never stall the client.
--
-- Deleting this file removes the feature with no other edit: DFLog checks for
-- the global and skips the section when it is absent.

if isServer() then return end

DFReports = DFReports or { providers = {} }

local MAX_DEPTH = 4
local MAX_NODES = 300
local MAX_CHARS = 4000

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

-- fn returns a table, a string, or anything tostring-able.
function DFReports.register(id, fn, displayName)
    if type(id) ~= "string" or id == "" then
        print("[RFTDCore] DFReports.register refused: id must be a non-empty string")
        return false
    end
    if type(fn) ~= "function" then
        print("[RFTDCore] DFReports.register refused for " .. id .. ": fn must be a function")
        return false
    end
    DFReports.providers[id] = { fn = fn, name = displayName or id }
    return true
end

function DFReports.unregister(id)
    if DFReports.providers[id] then
        DFReports.providers[id] = nil
        return true
    end
    return false
end

function DFReports.count()
    local n = 0
    for _ in pairs(DFReports.providers) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
--
-- Keys are SORTED, so two copies of the same state produce the same text and a
-- reader can diff them. pairs() order is unspecified and would make every report
-- gratuitously different from the last.
local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function render(value, indent, nodes, out)
    nodes.n = nodes.n + 1
    if nodes.n > MAX_NODES then
        out[#out + 1] = string.rep("  ", indent) .. "... (report truncated at "
            .. MAX_NODES .. " values)"
        return false
    end

    if type(value) ~= "table" then
        out[#out + 1] = string.rep("  ", indent) .. tostring(value)
        return true
    end

    if indent >= MAX_DEPTH then
        out[#out + 1] = string.rep("  ", indent) .. "{...}"
        return true
    end

    for _, k in ipairs(sortedKeys(value)) do
        local v = value[k]
        local pad = string.rep("  ", indent)
        if type(v) == "table" then
            out[#out + 1] = pad .. tostring(k) .. ":"
            if not render(v, indent + 1, nodes, out) then return false end
        else
            out[#out + 1] = pad .. tostring(k) .. " = " .. tostring(v)
        end
    end
    return true
end

-- Collect every registered report. Returns nil when nothing is registered, so
-- callers can omit the section entirely rather than print an empty heading.
function DFReports.collect()
    if DFReports.count() == 0 then return nil end

    local out = { "=== Mod diagnostics ===" }

    for _, id in ipairs(sortedKeys(DFReports.providers)) do
        local p = DFReports.providers[id]
        out[#out + 1] = ""
        out[#out + 1] = "--- " .. tostring(p.name) .. " [" .. id .. "] ---"

        local ok, result = pcall(p.fn)
        if not ok then
            -- A throwing report is itself a finding; say so where it will be read.
            out[#out + 1] = "  (report function failed: " .. tostring(result) .. ")"
        elseif result == nil then
            out[#out + 1] = "  (report returned nothing)"
        else
            local body = {}
            pcall(function() render(result, 1, { n = 0 }, body) end)
            if #body == 0 then
                out[#out + 1] = "  (report produced no readable values)"
            else
                for _, line in ipairs(body) do out[#out + 1] = line end
            end
        end
    end

    local text = table.concat(out, "\n")
    if #text > MAX_CHARS then
        text = string.sub(text, 1, MAX_CHARS) .. "\n... (diagnostics truncated)"
    end
    return text
end

return DFReports

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
