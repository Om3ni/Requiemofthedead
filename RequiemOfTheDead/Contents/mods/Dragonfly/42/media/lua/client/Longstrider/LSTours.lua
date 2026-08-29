-- SPDX-License-Identifier: GPL-3.0-or-later
-- LSTours - multi-tour data model + client-local persistence for Longstrider.
--
-- A "tour" is one named, coloured rectangular region the admin wants to
-- populate. The whole set is defined up front, shown on the map in distinct
-- colours, and run either one-at-a-time (Run Selected) or back-to-back
-- (Run All). The set persists per-admin to a client-local file so the plan
-- survives a relog. Shared Cell size / Dwell live here too.
--
-- This is pure client state (no server side). Modelled on PhunZones2's zone
-- list, simplified to one rect per tour.

if isServer() then return end

require "RDFile"
require "RDLuaLiteral"

LSTours = LSTours or {}

LSTours.list       = LSTours.list or {}      -- array of tour tables (see add())
LSTours.selectedId = LSTours.selectedId or nil
LSTours.cellSize   = LSTours.cellSize or 50
LSTours.dwellMs    = LSTours.dwellMs or 2500
-- Fixed safety cap (in cells), NOT a persisted preference: there is no UI to
-- change it yet, so it intentionally resets to this default every session and is
-- left out of serialize()/load(). If we expose a field later, persist it then.
LSTours.maxCells   = LSTours.maxCells or 400
if LSTours.gridOn == nil then LSTours.gridOn = true end
LSTours._nextId    = LSTours._nextId or 1
LSTours._loaded    = LSTours._loaded or false

require "DFFile"   -- the mod-wide file-read boundary

local FILE = "Longstrider_tours.txt"

-- Distinct, map-readable colours, assigned round-robin as tours are added.
local PALETTE = {
    { 0.95, 0.55, 0.10 }, -- orange
    { 0.30, 0.70, 0.95 }, -- blue
    { 0.45, 0.85, 0.35 }, -- green
    { 0.92, 0.40, 0.85 }, -- magenta
    { 0.95, 0.85, 0.25 }, -- yellow
    { 0.60, 0.50, 0.95 }, -- purple
    { 0.95, 0.40, 0.35 }, -- red
    { 0.25, 0.85, 0.80 }, -- teal
}

-- Order-independent region: accept any two opposite corners and return a floored
-- { minX, minY, maxX, maxY }. Shared by add(), setRegion() and load() so a
-- right-to-left / bottom-to-top gesture (or a hand-edited file) can never store
-- an inverted, negative-size rect.
-- Every entry must be a real number: normalizeRegion runs math.min/max over
-- all four, and a hand-edited file can put anything in them.
local function validRegion(r)
    if type(r) ~= "table" or #r ~= 4 then return false end
    for i = 1, 4 do
        if type(r[i]) ~= "number" then return false end
    end
    return true
end

local function normalizeRegion(r)
    return {
        math.floor(math.min(r[1], r[3])), math.floor(math.min(r[2], r[4])),
        math.floor(math.max(r[1], r[3])), math.floor(math.max(r[2], r[4])),
    }
end

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------

function LSTours.get(id)
    for _, t in ipairs(LSTours.list) do
        if t.id == id then return t end
    end
    return nil
end

function LSTours.getSelected()
    return LSTours.get(LSTours.selectedId)
end

function LSTours.select(id)
    LSTours.selectedId = id
end

function LSTours.count()
    return #LSTours.list
end

-- ---------------------------------------------------------------------------
-- Mutators (each persists)
-- ---------------------------------------------------------------------------

-- region = { x1, y1, x2, y2 } world coords. Returns the new tour.
function LSTours.add(region)
    local id = LSTours._nextId
    LSTours._nextId = id + 1
    local c = PALETTE[((id - 1) % #PALETTE) + 1]
    local t = {
        id     = id,
        name   = "Tour " .. id,
        color  = { c[1], c[2], c[3] },
        region = normalizeRegion(region),
    }
    LSTours.list[#LSTours.list + 1] = t
    LSTours.selectedId = id
    LSTours.save()
    return t
end

function LSTours.remove(id)
    for i, t in ipairs(LSTours.list) do
        if t.id == id then
            table.remove(LSTours.list, i)
            if LSTours.selectedId == id then
                local nxt = LSTours.list[i] or LSTours.list[i - 1]
                LSTours.selectedId = nxt and nxt.id or nil
            end
            LSTours.save()
            return true
        end
    end
    return false
end

function LSTours.clearAll()
    LSTours.list = {}
    LSTours.selectedId = nil
    LSTours.save()
end

function LSTours.rename(id, name)
    local t = LSTours.get(id)
    if not t then return end
    name = tostring(name or ""):gsub("^%s*(.-)%s*$", "%1")
    if name == "" then return end
    t.name = name
    LSTours.save()
end

-- Returns the normalised region so callers don't have to re-read t.region
-- (avoids relying on live-reference identity into LSTours.list).
function LSTours.setRegion(id, region)
    local t = LSTours.get(id)
    if not t then return nil end
    t.region = normalizeRegion(region)
    LSTours.save()
    return t.region
end

function LSTours.setCellSize(n) LSTours.cellSize = math.max(1, math.floor(n or 50)); LSTours.save() end
function LSTours.setDwellMs(n)  LSTours.dwellMs  = math.max(250, math.floor(n or 2500)); LSTours.save() end
function LSTours.setGridOn(b)   LSTours.gridOn   = b and true or false; LSTours.save() end

-- ---------------------------------------------------------------------------
-- Persistence (client-local file; failures are non-fatal)
-- ---------------------------------------------------------------------------

function LSTours.serialize()
    local p = { "return {\n" }
    p[#p + 1] = string.format("  cellSize=%d, dwellMs=%d, gridOn=%s, nextId=%d,\n",
        LSTours.cellSize, LSTours.dwellMs, tostring(LSTours.gridOn), LSTours._nextId)
    p[#p + 1] = string.format("  selectedId=%s,\n", tostring(LSTours.selectedId or "nil"))
    p[#p + 1] = "  tours={\n"
    for _, t in ipairs(LSTours.list) do
        p[#p + 1] = string.format(
            "    {id=%d, name=%q, color={%g,%g,%g}, region={%d,%d,%d,%d}},\n",
            t.id, t.name, t.color[1], t.color[2], t.color[3],
            t.region[1], t.region[2], t.region[3], t.region[4])
    end
    p[#p + 1] = "  },\n}\n"
    return table.concat(p)
end

-- ---------------------------------------------------------------------------
-- Save. Mechanism in RDFile (2026-08-25); its header carries the engine
-- facts the block here used to re-derive. serialize() walks LSTours' own
-- validated list, so a format fault there is a programming error and must
-- surface - which is why the call is bare around it.
-- ---------------------------------------------------------------------------
function LSTours.save()
    return RDFile.rewrite(FILE, LSTours.serialize())
end

-- ---------------------------------------------------------------------------
-- Load. The file is USER-EDITABLE, so its text is untrusted - and untrusted
-- text is never executed: RDLuaLiteral.parse reads the literal back with no
-- code path at all. (This was the suite's last loadstring caller; 42.20.4
-- removed the global outright, so the old sandbox - setfenv + pcall around an
-- executed chunk - is not just unnecessary now, it is impossible.) Each tour
-- record is still validated below before it is accepted.
-- ---------------------------------------------------------------------------
function LSTours.load()
    if LSTours._loaded then return end
    LSTours._loaded = true

    -- Truncation cannot be seen at the read layer - a BufferedReader fault
    -- presents as early EOF there (see DFFile.readLines) - so the integrity
    -- gate is below: a partial Lua literal does not parse. The `complete`
    -- flag this used to honour was always true.
    local lines = DFFile.readLines(FILE)
    if not lines then return end

    local src = table.concat(lines, "\n")
    -- A blank file is a non-event (nothing saved yet), not corruption - stay
    -- quiet rather than reporting a parse error on emptiness.
    if src:match("^%s*$") then return end

    -- The operator who hand-edited the file is the one who needs to be told,
    -- with the line number - the pre-parser boundary discarded the error
    -- silently.
    local data, perr = RDLuaLiteral.parse(src)
    if not data then
        print("[Longstrider] tour file does not parse ("
              .. tostring(perr) .. "); keeping the empty list")
        return
    end

    LSTours.cellSize = tonumber(data.cellSize) or LSTours.cellSize
    LSTours.dwellMs  = tonumber(data.dwellMs)  or LSTours.dwellMs
    LSTours.gridOn   = (data.gridOn ~= false)
    LSTours._nextId  = tonumber(data.nextId) or 1
    LSTours.list = {}

    local skipped = 0
    for _, t in ipairs(data.tours or {}) do
        -- Every field the accept path touches is type-checked here, not
        -- guarded downstream. normalizeRegion does math.min on r[1]..r[4], so a
        -- hand-edited region={1,"x",3,4} used to throw mid-loop - and the old
        -- blanket swallowed it, leaving a PARTIALLY populated list with
        -- _loaded already true, so the rest of the operator's tours vanished
        -- for the session with nothing said. One bad tour now costs only
        -- itself.
        if type(t) == "table" and type(t.color) == "table" and validRegion(t.region) then
            LSTours.list[#LSTours.list + 1] = {
                id     = tonumber(t.id) or LSTours._nextId,
                name   = tostring(t.name or ("Tour " .. tostring(t.id))),
                color  = { tonumber(t.color[1]) or 1, tonumber(t.color[2]) or 1, tonumber(t.color[3]) or 1 },
                region = normalizeRegion(t.region),
            }
        else
            skipped = skipped + 1
        end
    end
    if skipped > 0 then
        print("[Longstrider] skipped " .. tostring(skipped) .. " malformed tour(s); kept "
              .. tostring(#LSTours.list))
    end

    LSTours.selectedId = tonumber(data.selectedId) or (LSTours.list[1] and LSTours.list[1].id)
end

-- Read once per session. Reset _loaded first so a stale global surviving a soft
-- reload can't make load() skip the file; the in-session guard still prevents
-- redundant re-reads from repeated LSTab builds.
Events.OnGameStart.Add(function()
    LSTours._loaded = false
    LSTours.load()
end)

-- Dragonfly Longstrider v0.3.0
return LSTours

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
