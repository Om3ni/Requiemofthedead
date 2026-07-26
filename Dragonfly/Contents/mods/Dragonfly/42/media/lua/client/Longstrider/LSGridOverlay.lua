-- LSGridOverlay - draws/edits the set of Longstrider tour regions on the map.
--
-- Every tour is one coloured rectangle (world coords). All are drawn at once;
-- the SELECTED one shows resize handles + the cell lattice and can be reshaped
-- by dragging a handle or Shift-dragging its body. A plain click selects the
-- tour under the cursor. Map pan/zoom keeps working except while a drag is
-- consuming the mouse.
--
-- Decoupled from storage: the tab feeds it the tour list + selection and wires
-- onSelect / onRegionEdited back to LSTours. Hook/transform mechanics are the
-- proven ones from PhunZones2's ui_map_overlay.lua.

if isServer() then return end

local OC = {
    lattice    = { r = 0.90, g = 0.85, b = 0.55, a = 0.35 },
    handle     = { r = 0.98, g = 0.98, b = 0.98, a = 1.00 },
    visited    = { r = 0.20, g = 0.80, b = 0.35, a = 0.30 },  -- populated cell
    current    = { r = 0.98, g = 0.92, b = 0.25, a = 0.60 },  -- active stop
}

local HANDLE_R     = 5
local HANDLE_HIT_R = 9
local MIN_CELL_PX  = 4
local FONT         = UIFont.Small
local FONT_HGT     = getTextManager():getFontHeight(FONT)

LSGridOverlay = {}
LSGridOverlay.__index = LSGridOverlay

function LSGridOverlay:new(lsmap)
    local o = setmetatable({}, self)
    o.lsmap      = lsmap
    o.tours      = {}      -- reference to LSTours.list (array of tour tables)
    o.selectedId = nil
    o.cellSize   = 50
    o.gridOn     = true
    o.maxCells   = 400     -- resize past this many cells is refused (handle sticks)
    o.locked     = false   -- true during a tour: no edit, pan still works
    o.runner     = nil     -- { cells = { {x1,y1,x2,y2}... }, current = idx } or nil

    o._handleDrag = false
    o._handleIdx  = nil
    o._handleOrig = nil
    o._bodyDrag   = false
    o._bodyOrig   = nil
    o._bodyStartW = nil
    o._dragTour   = nil

    o.onSelect       = nil  -- function(id)
    o.onRegionEdited = nil  -- function(id)

    o._hooked = false
    o:hookNow()
    return o
end

-- ---------------------------------------------------------------------------
-- Public API (called from the tab)
-- ---------------------------------------------------------------------------

function LSGridOverlay:setTours(list)     self.tours = list or {} end
function LSGridOverlay:setSelectedId(id)  self.selectedId = id end
function LSGridOverlay:setCellSize(n)     self.cellSize = math.max(1, math.floor(n or 50)) end
function LSGridOverlay:setGridOn(b)       self.gridOn = b and true or false end
function LSGridOverlay:setMaxCells(n)     self.maxCells = tonumber(n) or 0 end

-- Cell count a region would produce at the current cell size.
function LSGridOverlay:_cellCount(r)
    local cs = self.cellSize
    local cols = math.max(1, math.ceil((r[3] - r[1]) / cs))
    local rows = math.max(1, math.ceil((r[4] - r[2]) / cs))
    return cols * rows
end

function LSGridOverlay:_overCap(r)
    return self.maxCells and self.maxCells > 0 and self:_cellCount(r) > self.maxCells
end
function LSGridOverlay:setLocked(b)       self.locked = b and true or false end
function LSGridOverlay:setRunner(t)       self.runner = t end

function LSGridOverlay:_selectedTour()
    for _, t in ipairs(self.tours) do
        if t.id == self.selectedId then return t end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Hooking (forward to originals only when we are NOT consuming the drag)
-- ---------------------------------------------------------------------------
-- ===== LS-DERIVED BEGIN ====================================================
-- SOURCE: PhunZones2 (UburGeek) - ui_map_overlay.lua : _hookMapWidget.
-- The "wrap the map widget's mouse/render and forward to the originals only
-- when not consuming the drag" technique is a close paraphrase of theirs.
-- RE-AUTHOR before Workshop publish.
-- ===========================================================================
function LSGridOverlay:hookNow()
    -- Reset accumulated absolute mouse position on every (re)attach. A cached map
    -- re-parented into a rebuilt tab would otherwise carry stale deltas. Must run
    -- BEFORE the _hooked guard, or it never fires on rebuild (LSTab calls hookNow
    -- each build, but the guard early-returns once wrapped).
    self._mouseX, self._mouseY = nil, nil
    if self._hooked then return end
    local mapWidget = self.lsmap and self.lsmap.map
    if not mapWidget then return end
    local overlay = self

    local origRender = mapWidget.render
    mapWidget.render = function(s)
        if origRender then origRender(s) end
        overlay:_render(s)
    end

    local origDown = mapWidget.onMouseDown
    mapWidget.onMouseDown = function(s, x, y)
        overlay._mouseX, overlay._mouseY = x, y
        overlay:_onMouseDown(s, x, y)
        if not overlay:_consuming() and origDown then origDown(s, x, y) end
    end

    local origMove = mapWidget.onMouseMove
    mapWidget.onMouseMove = function(s, dx, dy)
        overlay._mouseX = (overlay._mouseX or 0) + dx
        overlay._mouseY = (overlay._mouseY or 0) + dy
        overlay:_onMouseMove(s, overlay._mouseX, overlay._mouseY)
        if not overlay:_consuming() and origMove then origMove(s, dx, dy) end
    end

    local origMoveCap = mapWidget.onMouseMoveWhileCapture
    mapWidget.onMouseMoveWhileCapture = function(s, dx, dy)
        overlay._mouseX = (overlay._mouseX or 0) + dx
        overlay._mouseY = (overlay._mouseY or 0) + dy
        overlay:_onMouseMove(s, overlay._mouseX, overlay._mouseY)
        if not overlay:_consuming() and origMoveCap then origMoveCap(s, dx, dy) end
    end

    local origUp = mapWidget.onMouseUp
    mapWidget.onMouseUp = function(s, x, y)
        overlay._mouseX, overlay._mouseY = x, y
        local consumed = overlay:_onMouseUp(s, x, y)
        if not consumed and origUp then origUp(s, x, y) end
    end

    self._hooked = true
end
-- ===== LS-DERIVED END (PhunZones2 ui_map_overlay.lua : _hookMapWidget) ======

function LSGridOverlay:_consuming()
    return self._handleDrag or self._bodyDrag
end

-- ---------------------------------------------------------------------------
-- Coordinate helpers
-- ---------------------------------------------------------------------------

function LSGridOverlay:_api()
    return self.lsmap and self.lsmap.map and self.lsmap.map.mapAPI
end

function LSGridOverlay:_wToS(wx, wy)
    local api = self:_api()
    if not api then return 0, 0 end
    return api:worldToUIX(wx, wy), api:worldToUIY(wx, wy)
end

function LSGridOverlay:_sToW(sx, sy)
    local api = self:_api()
    if not api then return 0, 0 end
    return api:uiToWorldX(sx, sy), api:uiToWorldY(sx, sy)
end

-- Screen-space AABB of a world region { x1,y1,x2,y2 }.
function LSGridOverlay:_regionScreenRect(r)
    local x1s, y1s = self:_wToS(r[1], r[2])
    local x2s, y2s = self:_wToS(r[3], r[4])
    if x1s > x2s then x1s, x2s = x2s, x1s end
    if y1s > y2s then y1s, y2s = y2s, y1s end
    return math.floor(x1s), math.floor(y1s), math.ceil(x2s), math.ceil(y2s)
end

-- ---------------------------------------------------------------------------
-- Handles
--
-- Table-driven resize model: each handle is an edge anchor that declares which
-- world edges it pins. _handlePoints / _hitTestHandle / _applyHandle all derive
-- from ANCHORS - there is no positional index switch anywhere.
-- ---------------------------------------------------------------------------

-- xEdge/yEdge: "min", "max", "mid" (a screen-only midpoint) or nil (free axis).
local ANCHORS = {
    { id = "TL", xEdge = "min", yEdge = "min" },
    { id = "TC", xEdge = "mid", yEdge = "min" },
    { id = "TR", xEdge = "max", yEdge = "min" },
    { id = "ML", xEdge = "min", yEdge = "mid" },
    { id = "MR", xEdge = "max", yEdge = "mid" },
    { id = "BL", xEdge = "min", yEdge = "max" },
    { id = "BC", xEdge = "mid", yEdge = "max" },
    { id = "BR", xEdge = "max", yEdge = "max" },
}

local function edgePos(minv, maxv, edge)
    if edge == "min" then return minv
    elseif edge == "max" then return maxv
    elseif edge == "mid" then return math.floor((minv + maxv) / 2) end
    return nil
end

function LSGridOverlay:_handlePoints(x1, y1, x2, y2)
    local pts = {}
    for _, a in ipairs(ANCHORS) do
        pts[#pts + 1] = {
            id = a.id,
            sx = edgePos(x1, x2, a.xEdge),
            sy = edgePos(y1, y2, a.yEdge),
        }
    end
    return pts
end

function LSGridOverlay:_hitTestHandle(sx, sy, x1, y1, x2, y2)
    for i, h in ipairs(self:_handlePoints(x1, y1, x2, y2)) do
        if math.abs(sx - h.sx) <= HANDLE_HIT_R and math.abs(sy - h.sy) <= HANDLE_HIT_R then
            return i
        end
    end
    return nil
end

-- Which tour's region contains screen point (sx,sy)? Prefers the selected one.
function LSGridOverlay:_hitTestTour(sx, sy)
    local function inside(t)
        if not t or not t.region then return false end
        local x1, y1, x2, y2 = self:_regionScreenRect(t.region)
        return sx >= x1 and sx <= x2 and sy >= y1 and sy <= y2
    end
    local sel = self:_selectedTour()
    if inside(sel) then return sel.id end
    for _, t in ipairs(self.tours) do
        if t.id ~= self.selectedId and inside(t) then return t.id end
    end
    return nil
end

function LSGridOverlay:_applyHandle(wx, wy)
    local t = self._dragTour
    if not t then return end
    local a = ANCHORS[self._handleIdx]
    if not a then return end
    local o = self._handleOrig
    local nx1, ny1, nx2, ny2 = o[1], o[2], o[3], o[4]

    -- The dragged handle's pinned edges follow the cursor; the others hold.
    -- "mid" edges are screen-only midpoints, so they pin nothing in world space.
    if     a.xEdge == "min" then nx1 = wx
    elseif a.xEdge == "max" then nx2 = wx end
    if     a.yEdge == "min" then ny1 = wy
    elseif a.yEdge == "max" then ny2 = wy end

    if nx1 > nx2 - 1 then nx1 = nx2 - 1 end
    if ny1 > ny2 - 1 then ny1 = ny2 - 1 end

    local cand = { math.floor(nx1), math.floor(ny1), math.floor(nx2), math.floor(ny2) }
    -- Refuse a resize that would push the region past the cell cap, so the
    -- handle "sticks" at the limit instead of growing further.
    if self:_overCap(cand) then return end
    t.region = cand
end

function LSGridOverlay:_applyBody(wx, wy)
    local t = self._dragTour
    if not t then return end
    local o = self._bodyOrig
    local dx, dy = wx - self._bodyStartW[1], wy - self._bodyStartW[2]
    t.region = { math.floor(o[1] + dx), math.floor(o[2] + dy),
                 math.floor(o[3] + dx), math.floor(o[4] + dy) }
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

function LSGridOverlay:_onMouseDown(widget, x, y)
    if not self.locked then
        local t = self:_selectedTour()
        if t and t.region then
            local x1, y1, x2, y2 = self:_regionScreenRect(t.region)
            local hIdx = self:_hitTestHandle(x, y, x1, y1, x2, y2)
            if hIdx then
                self._handleDrag = true
                self._handleIdx  = hIdx
                self._handleOrig = { t.region[1], t.region[2], t.region[3], t.region[4] }
                self._dragTour   = t
                widget:setCapture(true)
                return
            end
            if x >= x1 and x <= x2 and y >= y1 and y <= y2
               and (isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT)) then
                self._bodyDrag   = true
                self._bodyOrig   = { t.region[1], t.region[2], t.region[3], t.region[4] }
                local wx, wy = self:_sToW(x, y)
                self._bodyStartW = { wx, wy }
                self._dragTour   = t
                widget:setCapture(true)
                return
            end
        end
    end
    self._clickStartX, self._clickStartY = x, y
end

function LSGridOverlay:_onMouseMove(widget, x, y)
    if self._handleDrag then
        local wx, wy = self:_sToW(x, y)
        self:_applyHandle(wx, wy)
    elseif self._bodyDrag then
        local wx, wy = self:_sToW(x, y)
        self:_applyBody(wx, wy)
    end
end

function LSGridOverlay:_onMouseUp(widget, x, y)
    if self._handleDrag or self._bodyDrag then
        widget:setCapture(false)
        local t = self._dragTour
        self._handleDrag, self._handleIdx, self._handleOrig = false, nil, nil
        self._bodyDrag, self._bodyOrig, self._bodyStartW = false, nil, nil
        self._dragTour = nil
        if t and self.onRegionEdited then self.onRegionEdited(t.id) end
        return true
    end

    -- Plain click: select the tour under the cursor (if it barely moved).
    local dx = self._clickStartX and math.abs(x - self._clickStartX) or 999
    local dy = self._clickStartY and math.abs(y - self._clickStartY) or 999
    self._clickStartX, self._clickStartY = nil, nil
    if dx <= 4 and dy <= 4 and not self.locked then
        local id = self:_hitTestTour(x, y)
        if id and id ~= self.selectedId and self.onSelect then
            self.onSelect(id)
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function LSGridOverlay:_render(widget)
    if not self:_api() then return end
    widget:setStencilRect(0, 0, widget.width, widget.height)

    if self.runner then self:_renderRunnerCells(widget) end

    for _, t in ipairs(self.tours) do
        self:_renderTour(widget, t, t.id == self.selectedId)
    end

    local sel = self:_selectedTour()
    if sel and self.gridOn then self:_renderLattice(widget, sel.region) end

    if not self.locked and #self.tours == 0 then
        self:_renderHint(widget, 'Click "Add" (left panel) to drop a tour region here')
    end

    widget:clearStencilRect()
end

function LSGridOverlay:_renderTour(widget, t, isSel)
    if not t.region then return end
    local x1, y1, x2, y2 = self:_regionScreenRect(t.region)
    local w, h = x2 - x1, y2 - y1
    if w < 2 or h < 2 then return end

    local c = t.color
    local fillA   = isSel and 0.22 or 0.12
    local borderA = isSel and 1.0  or 0.7
    widget:drawRect(x1, y1, w, h, fillA, c[1], c[2], c[3])
    widget:drawRectBorder(x1, y1, w, h, borderA, c[1], c[2], c[3])
    if isSel then
        widget:drawRectBorder(x1 + 1, y1 + 1, w - 2, h - 2, 0.5, c[1], c[2], c[3])
        for _, hd in ipairs(self:_handlePoints(x1, y1, x2, y2)) do
            widget:drawRect(hd.sx - HANDLE_R, hd.sy - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2, 0.9, 0.06, 0.06, 0.08)
            widget:drawRectBorder(hd.sx - HANDLE_R, hd.sy - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2,
                OC.handle.a, OC.handle.r, OC.handle.g, OC.handle.b)
        end
    end

    -- Name pill at the top-left of the rect.
    local label = t.name or ("Tour " .. tostring(t.id))
    local lw = getTextManager():MeasureStringX(FONT, label)
    local lx, ly = x1 + 3, y1 + 3
    widget:drawRect(lx - 2, ly - 1, lw + 6, FONT_HGT + 2, 0.8, 0.05, 0.05, 0.08)
    widget:drawText(label, lx + 1, ly, c[1], c[2], c[3], isSel and 1.0 or 0.85, FONT)
end

function LSGridOverlay:_renderLattice(widget, r)
    local cs = self.cellSize
    if not r or cs < 1 then return end
    local x1, y1, x2, y2 = self:_regionScreenRect(r)
    -- Cell pixel width at the current zoom; skip the lattice if it's too fine to
    -- read. _wToS returns (sx, sy) and we want only the X here, so capture the
    -- second value into an explicit discard rather than relying on truncation.
    local ax, _ = self:_wToS(r[1], r[2])
    local bx, _ = self:_wToS(r[1] + cs, r[2])
    if math.abs(bx - ax) < MIN_CELL_PX then return end

    local col = OC.lattice
    local wx = r[1] + cs
    while wx < r[3] do
        local sx = math.floor((self:_wToS(wx, r[2])))
        widget:drawRect(sx, y1, 1, y2 - y1, col.a, col.r, col.g, col.b)
        wx = wx + cs
    end
    local wy = r[2] + cs
    while wy < r[4] do
        local _, sy = self:_wToS(r[1], wy)
        sy = math.floor(sy)
        widget:drawRect(x1, sy, x2 - x1, 1, col.a, col.r, col.g, col.b)
        wy = wy + cs
    end
end

function LSGridOverlay:_renderRunnerCells(widget)
    local t = self.runner
    if not t or not t.cells then return end
    for i, c in ipairs(t.cells) do
        local col
        if i == t.current then col = OC.current
        elseif t.current and i < t.current then col = OC.visited end
        if col then
            local x1s, y1s = self:_wToS(c[1], c[2])
            local x2s, y2s = self:_wToS(c[3], c[4])
            if x1s > x2s then x1s, x2s = x2s, x1s end
            if y1s > y2s then y1s, y2s = y2s, y1s end
            local w, h = math.ceil(x2s - x1s), math.ceil(y2s - y1s)
            if w >= 2 and h >= 2 then
                widget:drawRect(math.floor(x1s), math.floor(y1s), w, h, col.a, col.r, col.g, col.b)
            end
        end
    end
end

function LSGridOverlay:_renderHint(widget, msg)
    local tw = getTextManager():MeasureStringX(FONT, msg)
    local px = math.floor((widget.width - tw) / 2)
    local py = math.floor(widget.height / 2 - FONT_HGT / 2)
    widget:drawRect(px - 10, py - 6, tw + 20, FONT_HGT + 12, 0.78, 0.05, 0.05, 0.08)
    widget:drawRectBorder(px - 10, py - 6, tw + 20, FONT_HGT + 12, 0.85, 0.90, 0.55, 0.10)
    widget:drawText(msg, px, py, 0.95, 0.85, 0.55, 1.0, FONT)
end

-- Dragonfly Longstrider v0.3.0
return LSGridOverlay
