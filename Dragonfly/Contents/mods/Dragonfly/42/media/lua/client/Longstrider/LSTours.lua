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

function LSTours.save()
    pcall(function()
        local w = getFileWriter(FILE, true, false)
        if not w then return end
        w:write(LSTours.serialize())
        w:close()
    end)
end

function LSTours.load()
    if LSTours._loaded then return end
    LSTours._loaded = true
    pcall(function()
        local r = getFileReader(FILE, false)
        if not r then return end
        local lines, line = {}, r:readLine()
        while line do lines[#lines + 1] = line; line = r:readLine() end
        r:close()
        local src = table.concat(lines, "\n")
        if not src:find("return", 1, true) then return end
        local fn = loadstring(src)
        if not fn then return end
        setfenv(fn, {})
        local ok, data = pcall(fn)
        if not ok or type(data) ~= "table" then return end

        LSTours.cellSize = tonumber(data.cellSize) or LSTours.cellSize
        LSTours.dwellMs  = tonumber(data.dwellMs)  or LSTours.dwellMs
        LSTours.gridOn   = (data.gridOn ~= false)
        LSTours._nextId  = tonumber(data.nextId) or 1
        LSTours.list = {}
        for _, t in ipairs(data.tours or {}) do
            if type(t) == "table" and t.region and #t.region == 4 and t.color then
                LSTours.list[#LSTours.list + 1] = {
                    id     = tonumber(t.id) or LSTours._nextId,
                    name   = tostring(t.name or ("Tour " .. tostring(t.id))),
                    color  = { t.color[1] or 1, t.color[2] or 1, t.color[3] or 1 },
                    region = normalizeRegion(t.region),
                }
            end
        end
        LSTours.selectedId = tonumber(data.selectedId) or (LSTours.list[1] and LSTours.list[1].id)
    end)
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
