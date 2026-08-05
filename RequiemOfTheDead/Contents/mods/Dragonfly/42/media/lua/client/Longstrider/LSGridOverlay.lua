-- SPDX-License-Identifier: GPL-3.0-or-later
-- LSGridOverlay - draws/edits the set of Longstrider tour regions on the map.
--
-- Every tour is one coloured rectangle (world coords). All are drawn at once;
-- the SELECTED one shows resize handles + the cell lattice and can be reshaped
-- by dragging a handle or Shift-dragging its body. A plain click selects the
-- tour under the cursor. Map pan/zoom keeps working except while a drag is
-- consuming the mouse.
--
-- Decoupled from storage: the tab feeds it the tour list + selection and wires
-- onSelect / onRegionEdited back to LSTours. The hook and transform mechanics
-- were re-authored 2026-08-04 (LM-EDIT-1) against the engine's own map API; see
-- hookNow and docs/limes-design.md §2.

if isServer() then return end

local OC = {
    lattice    = { r = 0.90, g = 0.85, b = 0.55, a = 0.35 },
    handle     = { r = 0.98, g = 0.98, b = 0.98, a = 1.00 },
    visited    = { r = 0.20, g = 0.80, b = 0.35, a = 0.30 },  -- populated cell
    current    = { r = 0.98, g = 0.92, b = 0.25, a = 0.60 },  -- active stop
    overCap    = { r = 0.98, g = 0.45, b = 0.20, a = 1.00 },  -- too many cells to run
}

local HANDLE_R     = 5
local HANDLE_HIT_R = 9
local MIN_CELL_PX  = 4
-- Smallest span, in world tiles, a drag may leave on either axis. Dragging a
-- corner clean past its opposite edge used to bottom out at 1 tile, producing a
-- region you can neither see nor grab a handle on again (one such - 5068x1 -
-- was found in a live tours file).
local MIN_SPAN     = 10
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

-- Cell count a region would produce at the current cell size. Delegated to
-- LSTour so the tab's readout, the run's preflight and this overlay's warning
-- can never quote three different numbers for the same rectangle.
function LSGridOverlay:_cellCount(r)
    return LSTour.cellCountOf(r, self.cellSize)
end

-- Over the cap = "this cannot be RUN", not "this cannot be DRAWN". See
-- _applyHandle for why that distinction had to be made explicit.
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
-- Take over one method on the widget, handing the replacement its predecessor
-- so each wrapper decides for itself whether, when and with what to call
-- through. Written as a helper because the alternative is the same
-- capture-then-assign preamble six times over, and because the interesting part
-- of each hook is the forwarding RULE, which differs every time: render
-- composes, the mouse handlers gate on who owns the drag, and the outside
-- release routes rather than forwards. A single shared policy would have to
-- lie about at least one of them.
local function takeOver(widget, name, replace)
    widget[name] = replace(widget[name])
end

-- PROVENANCE (LM-EDIT-1, re-authored 2026-08-04): earlier revisions followed
-- PhunZones2's ui_map_overlay.lua for this; nothing of it survives. Wrapping a
-- widget's handlers and delegating to the captured original is the ordinary Lua
-- decorator idiom - the design decisions that matter here are ours and are
-- written down where they are made. See docs/limes-design.md §2.
function LSGridOverlay:hookNow()
    if self._hooked then return end
    local mapWidget = self.lsmap and self.lsmap.map
    if not mapWidget then return end
    local overlay = self

    -- THE OWNERSHIP RULE, which every mouse hook below is an application of:
    -- the widget owns the mouse until the overlay starts a drag, and gets it
    -- back the moment that drag ends. So we always observe first, then forward
    -- unless we are mid-drag - forwarding during a drag would let the map pan
    -- under the handle the user is dragging, which reads as the rectangle
    -- sliding away from the cursor.
    local function forward(orig, ...)
        if not overlay:_consuming() and orig then orig(...) end
    end

    -- Render last so the overlay draws on top of the map, never under it.
    takeOver(mapWidget, "render", function(orig)
        return function(s)
            if orig then orig(s) end
            overlay:_render(s)
        end
    end)

    takeOver(mapWidget, "onMouseDown", function(orig)
        return function(s, x, y)
            overlay:_onMouseDown(s, x, y)
            forward(orig, s, x, y)
        end
    end)

    -- ASK THE WIDGET WHERE THE MOUSE IS; DO NOT ADD UP THE DELTAS.
    --
    -- onMouseMove carries frame deltas, not a position, so this used to seed an
    -- absolute from the mouse-down coordinates and accumulate dx/dy on top -
    -- a running total that is only ever as good as the dispatch history behind
    -- it, and that silently walks away from the cursor if a frame is dropped,
    -- duplicated, or delivered through a path that scales differently.
    -- ISUIElement:getMouseX (ISUI/ISUIElement.lua:339-351) is the live mouse
    -- position minus the widget's own absolute origin - i.e. already in the
    -- widget-local space our hit tests and world transforms work in, with no
    -- state to keep and nothing to reset when a cached map is re-parented into a
    -- rebuilt tab. Vanilla's own ISMiniMapInner:onMouseMove (ISUI/Maps/
    -- ISMiniMap.lua:251-266) ignores its dx/dy arguments and does exactly this.
    --
    -- Only ONE hook is installed here, not two. The old second hook on
    -- "onMouseMoveWhileCapture" was dead code: that name appears nowhere in
    -- 42.20's engine or its shipped Lua. A captured child gets plain onMouseMove
    -- like any other - UIElement.java:998 admits it to the dispatch loop on
    -- `mouse-in-bounds || ui.isCapture()`.
    takeOver(mapWidget, "onMouseMove", function(orig)
        return function(s, dx, dy)
            overlay:_onMouseMove(s, s:getMouseX(), s:getMouseY())
            forward(orig, s, dx, dy)
        end
    end)

    -- Release is the one place the overlay reports back: a live drag consumes
    -- the event outright, so the widget never sees the click that ended it.
    takeOver(mapWidget, "onMouseUp", function(orig)
        return function(s, x, y)
            local consumed = overlay:_onMouseUp(s, x, y)
            if not consumed and orig then orig(s, x, y) end
        end
    end)

    -- RELEASING OUTSIDE THE WIDGET MUST END THE DRAG. Without this, dragging a
    -- handle past the panel edge and letting go leaves _handleDrag/_bodyDrag
    -- set, so _consuming() keeps swallowing pan and zoom - and capture is never
    -- released - until the next in-widget release. Easy to hit on a small map
    -- pane, and it looks like the map froze.
    --
    -- Only the drag path is forwarded: _onMouseUp ignores x/y once a drag is
    -- live (the geometry was already applied during the move), but its other
    -- branch treats the coordinates as a click and can select a region. An
    -- off-widget release is not a click, so that branch is deliberately skipped
    -- and the click origin cleared instead.
    takeOver(mapWidget, "onMouseUpOutside", function(orig)
        return function(s, x, y)
            if overlay._handleDrag or overlay._bodyDrag then
                overlay:_onMouseUp(s, x, y)
                return
            end
            overlay._clickStartX, overlay._clickStartY = nil, nil
            if orig then orig(s, x, y) end
        end
    end)

    self._hooked = true
end

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

-- Keep an axis at least MIN_SPAN wide by pushing back on THE EDGE BEING
-- DRAGGED, not on its anchor: dragging the left edge rightwards past the right
-- edge must stop the left edge, not shove the right one along with it. A "mid"
-- edge means this axis is not part of the gesture at all, so it is returned
-- untouched even if a hand-edited file left it degenerate.
local function clampSpan(lo, hi, edge)
    if hi - lo >= MIN_SPAN then return lo, hi end
    if     edge == "min" then return hi - MIN_SPAN, hi
    elseif edge == "max" then return lo, lo + MIN_SPAN end
    return lo, hi
end

-- THE CAP IS A RUN LIMIT, NOT A DRAWING LIMIT (fixed 2026-08-04).
--
-- This used to refuse any candidate over maxCells, so the handle "stuck" at the
-- limit. The intent was a guard rail; the effect was a dead control. Once a
-- region reached the cap the refusal was total and silent - no message, no
-- colour, nothing - and since a region can also cross the cap by routes that
-- never touch this function (the Set button, lowering Cell size, a loaded file),
-- a region could sit permanently over the cap with every handle frozen,
-- INCLUDING the drags that would have shrunk it back under. The only way out
-- was to delete the tour and start over, which is exactly what it looked like
-- from the outside: "drag resizing doesn't work". A live tours file showed the
-- fingerprint plainly - two regions pinned at exactly 400 cells, and a nextId of
-- 43 behind four surviving tours.
--
-- The cap is enforced where it means something: recompute() greys out Run, and
-- preflight() refuses the run outright with a message naming the number and the
-- remedy. Nothing is lost by letting the admin draw freely, and the count is now
-- O(1) (LSTour.cellCountOf) so an oversized region costs nothing to display.
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

    nx1, nx2 = clampSpan(nx1, nx2, a.xEdge)
    ny1, ny2 = clampSpan(ny1, ny2, a.yEdge)

    t.region = { math.floor(nx1), math.floor(ny1), math.floor(nx2), math.floor(ny2) }
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
    local over    = self:_overCap(t.region)
    local fillA   = isSel and 0.22 or 0.12
    local borderA = isSel and 1.0  or 0.7
    -- Over the cap the region is still perfectly drawable - it just cannot be
    -- toured - so it keeps its own colour and gains a warning outline rather
    -- than being recoloured wholesale. The admin needs to see WHICH tour is the
    -- problem, and the tour's identity is its colour.
    local bc = over and OC.overCap or { r = c[1], g = c[2], b = c[3] }
    widget:drawRect(x1, y1, w, h, fillA, c[1], c[2], c[3])
    widget:drawRectBorder(x1, y1, w, h, borderA, bc.r, bc.g, bc.b)
    if isSel then
        widget:drawRectBorder(x1 + 1, y1 + 1, w - 2, h - 2, 0.5, bc.r, bc.g, bc.b)
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

    -- SAY WHY RUN IS GREYED OUT, ON THE THING THAT CAUSED IT. The cap used to be
    -- enforced by silently refusing the drag, which taught the admin that resize
    -- was broken rather than that the region was too big. Now the drag always
    -- works and the rectangle itself carries the diagnosis and the two remedies.
    if over then
        local msg = string.format("%d cells - over the %d cap; shrink it or raise Cell size",
            self:_cellCount(t.region), self.maxCells)
        local mw = getTextManager():MeasureStringX(FONT, msg)
        local my = ly + FONT_HGT + 3
        widget:drawRect(lx - 2, my - 1, mw + 6, FONT_HGT + 2, 0.85, 0.05, 0.05, 0.08)
        widget:drawText(msg, lx + 1, my, OC.overCap.r, OC.overCap.g, OC.overCap.b, 1.0, FONT)
    end
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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
