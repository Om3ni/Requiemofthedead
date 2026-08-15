-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMMapEditor - draw and reshape zone rectangles on an embedded world map (M4).
--
-- Hosts on an LSMap (Dragonfly's ISMiniMapInner wrapper) exactly the way
-- LSGridOverlay does, and for the same reason: that widget already owns the
-- world<->screen transform, the pan and the zoom, so an editor only has to
-- supply geometry and gestures. Taking `host` as a constructor argument rather
-- than reaching for a global keeps the choice of frame - tab pane now,
-- maximised pane or floating window later - a parenting decision instead of a
-- rewrite (docs/limes-design.md §11.1).
--
-- IT EDITS A DRAFT, NEVER THE STORE. Everything here writes to an LMEdit
-- working copy; the store moves only when the server echoes a save back
-- (§6.1 rules 2 and 3). A drag is therefore free - no packets, no listeners
-- firing at frame rate, and no window where this admin can see state nobody
-- else has.
--
-- WHERE IT DIFFERS FROM LSGridOverlay, and why it is a sibling rather than a
-- subclass:
--   * a zone is MANY rectangles, not one. Selection is (zone, rect index), and
--     the gestures that matter - add a rect, delete a rect - have no meaning in
--     a one-rect model.
--   * there are ~76 zones on a live map instead of a handful of tours, so
--     everything is culled to the viewport and labels are earned by size.
--   * colour is derived from the zone NAME, not handed out round-robin, so a
--     zone is the same colour in every session and on every admin's screen.
--   * no cell lattice and no cap: nothing here gets walked afterwards.
--
-- INHERITED RULE, bought the hard way in Longstrider on 2026-08-04: a limit
-- never refuses a gesture. Its resize handles used to stick silently at a cell
-- cap, which read as "drag resizing is broken" and could only be escaped by
-- deleting the region. Limits in this editor are reported by validate() and
-- enforced at Save; the drag always moves.

if isServer() then return end

require "LMCore"
require "LMEdit"

LMMapEditor = LMMapEditor or {}
LMMapEditor.__index = LMMapEditor

local HANDLE_R     = 5
local HANDLE_HIT_R = 9
-- Smallest span a drag may leave, in world tiles. Below this the rect is
-- unreadable and its own handles overlap, so it can never be grabbed again.
local MIN_SPAN     = 8
-- A rect narrower than this on screen gets no label and no handles: at world
-- zoom the whole map is a few hundred pixels and 76 zones of chrome is noise.
local LABEL_MIN_PX = 46
local FONT         = UIFont.Small
local FONT_HGT     = getTextManager():getFontHeight(FONT)

-- Deterministic palette. The same zone is the same colour in every session, on
-- every admin's screen, and across a rename-free edit - which is what makes
-- "the orange one is wrong" a usable sentence between two people.
local PALETTE = {
    { 0.95, 0.55, 0.10 }, { 0.30, 0.70, 0.95 }, { 0.45, 0.85, 0.35 },
    { 0.92, 0.40, 0.85 }, { 0.95, 0.85, 0.25 }, { 0.60, 0.50, 0.95 },
    { 0.95, 0.40, 0.35 }, { 0.25, 0.85, 0.80 },
}

-- djb2, folded to the palette. Any stable hash would do; this one is three
-- lines and has no collisions worth caring about across ~76 short names.
local function colourFor(name)
    local h = 5381
    for i = 1, #name do
        h = (h * 33 + string.byte(name, i)) % 16777216
    end
    return PALETTE[(h % #PALETTE) + 1]
end
LMMapEditor.colourFor = colourFor

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function LMMapEditor:new(host)
    local o = setmetatable({}, self)
    o.host       = host        -- an LSMap
    o.draft      = nil         -- an LMEdit draft
    o.selected   = nil         -- zone name
    o.rectIdx    = nil         -- index into that zone's rects
    o.locked     = false
    o.showAll    = true        -- false = only the selected zone

    o._handleDrag, o._handleIdx, o._handleOrig = false, nil, nil
    o._bodyDrag,   o._bodyOrig,  o._bodyStartW = false, nil, nil
    o._newDrag,    o._newStartW                = false, nil
    o._dragRect   = nil

    o.onSelect = nil           -- fn(zoneName, rectIndex)
    o.onEdited = nil           -- fn(zoneName)  - geometry settled, mark dirty

    o._hooked = false
    o:hookNow()
    return o
end

function LMMapEditor:setDraft(d)       self.draft = d end
function LMMapEditor:setLocked(b)      self.locked = b and true or false end
function LMMapEditor:setShowAll(b)     self.showAll = b and true or false end

function LMMapEditor:setSelected(name, rectIdx)
    self.selected = name
    self.rectIdx  = rectIdx
    -- A zone with geometry always has a live rect selected, so the handles are
    -- reachable the moment it is picked from the list rather than after a
    -- second click nobody knows they have to make.
    if name and not rectIdx then
        local rec = self.draft and self.draft:get(name)
        if rec and rec.rects and #rec.rects > 0 then self.rectIdx = 1 end
    end
end

-- HOW BIG A NEW RECTANGLE STARTS, and it cannot be a number of tiles.
--
-- MIN_SPAN is 8 tiles. At a zoom showing a whole region - which is where an
-- admin actually is when they decide to add a zone - eight tiles is about two
-- pixels: the rectangle exists, is selected, has handles, and is invisible.
-- That is the whole of "I can add a zone but no box appears on the map".
--
-- So the seed is a fraction of what is ON SCREEN: about a twelfth of the
-- visible width, which is a comfortable grab target at any zoom and shrinks to
-- something sane when zoomed into a single building. Clamped at both ends so a
-- fully zoomed-out world map does not seed a 1200-tile monster and a fully
-- zoomed-in one still yields something draggable.
function LMMapEditor:_seedSpan()
    local api = self:_api()
    local w = self.host and self.host.map and self.host.map:getWidth() or 0
    if not api or w <= 0 then return 64 end
    -- pcall: uiToWorldX is the engine world-map API projecting through a
    -- transform that is not populated until the widget has rendered a frame,
    -- so this throws when called before the map is on screen. 64 is the seed
    -- that keeps in that case.
    local ok, span = pcall(function()
        return math.abs(api:uiToWorldX(w, 0) - api:uiToWorldX(0, 0))
    end)
    if not ok or not span or span <= 0 then return 64 end
    local seed = math.floor(span / 12)
    if seed < MIN_SPAN * 2 then seed = MIN_SPAN * 2 end
    if seed > 1500 then seed = 1500 end
    return seed
end

-- Drop a rectangle in the middle of the current view and select it. This is
-- what "Add zone" uses: a zone with no geometry is a template, and a template
-- is not what somebody who just pressed Add wanted - they wanted a box to drag.
-- Longstrider's Add has always worked this way; the zone editor asking for a
-- modifier-key gesture instead was a regression against a pattern the admin had
-- already learned.
function LMMapEditor:addRectAtView(name)
    local api = self:_api()
    if not (api and self.draft) then return nil end
    local rec = self.draft:get(name)
    if not rec then return nil end
    local mw = self.host.map:getWidth()
    local mh = self.host.map:getHeight()
    local cx, cy
    -- pcall: same unrendered-transform failure as _seedSpan. No centre means no
    -- rectangle, which is the nil return below.
    local ok = pcall(function()
        cx = math.floor(api:uiToWorldX(mw / 2, mh / 2))
        cy = math.floor(api:uiToWorldY(mw / 2, mh / 2))
    end)
    if not ok or not cx or not cy then return nil end

    local half = math.floor(self:_seedSpan() / 2)
    rec.rects = rec.rects or {}
    rec.rects[#rec.rects + 1] = { cx - half, cy - half, cx + half, cy + half }
    self.selected = name
    self.rectIdx  = #rec.rects
    return #rec.rects
end

function LMMapEditor:selectedRect()
    if not (self.draft and self.selected and self.rectIdx) then return nil end
    local rec = self.draft:get(self.selected)
    return rec and rec.rects and rec.rects[self.rectIdx] or nil
end

-- ---------------------------------------------------------------------------
-- Hooking. Same ownership rule as LSGridOverlay: the widget owns the mouse
-- until this overlay starts a drag and gets it back the moment that drag ends,
-- because forwarding mid-drag lets the map pan under the handle being dragged -
-- which reads as the rectangle sliding away from the cursor.
-- ---------------------------------------------------------------------------

local function takeOver(widget, name, replace)
    widget[name] = replace(widget[name])
end

function LMMapEditor:hookNow()
    if self._hooked then return end
    local w = self.host and self.host.map
    if not w then return end
    local ed = self

    local function forward(orig, ...)
        if not ed:_consuming() and orig then orig(...) end
    end

    takeOver(w, "render", function(orig)
        return function(s)
            if orig then orig(s) end
            ed:_render(s)
        end
    end)

    takeOver(w, "onMouseDown", function(orig)
        return function(s, x, y)
            ed:_onMouseDown(s, x, y)
            forward(orig, s, x, y)
        end
    end)

    -- Absolute position from the widget, not accumulated deltas. See the same
    -- hook in LSGridOverlay for the full reasoning; the short version is that a
    -- running total is only as good as the dispatch history behind it, and
    -- ISUIElement:getMouseX is already in the widget-local space the world
    -- transforms use.
    takeOver(w, "onMouseMove", function(orig)
        return function(s, dx, dy)
            ed:_onMouseMove(s, s:getMouseX(), s:getMouseY())
            forward(orig, s, dx, dy)
        end
    end)

    takeOver(w, "onMouseUp", function(orig)
        return function(s, x, y)
            local consumed = ed:_onMouseUp(s, x, y)
            if not consumed and orig then orig(s, x, y) end
        end
    end)

    -- Releasing off-widget must end the drag, or _consuming() keeps swallowing
    -- pan and zoom and capture is never released - it looks like the map froze.
    -- Only the drag path forwards: an off-widget release is not a click, so the
    -- selection branch is skipped and the click origin cleared.
    takeOver(w, "onMouseUpOutside", function(orig)
        return function(s, x, y)
            if ed:_consuming() then ed:_onMouseUp(s, x, y); return end
            ed._clickX, ed._clickY = nil, nil
            if orig then orig(s, x, y) end
        end
    end)

    self._hooked = true
end

function LMMapEditor:_consuming()
    return self._handleDrag or self._bodyDrag or self._newDrag
end

-- ---------------------------------------------------------------------------
-- Transforms
-- ---------------------------------------------------------------------------

function LMMapEditor:_api()
    return self.host and self.host.map and self.host.map.mapAPI
end

function LMMapEditor:_wToS(wx, wy)
    local api = self:_api()
    if not api then return 0, 0 end
    return api:worldToUIX(wx, wy), api:worldToUIY(wx, wy)
end

function LMMapEditor:_sToW(sx, sy)
    local api = self:_api()
    if not api then return 0, 0 end
    return api:uiToWorldX(sx, sy), api:uiToWorldY(sx, sy)
end

function LMMapEditor:_screenRect(r)
    local x1, y1 = self:_wToS(r[1], r[2])
    local x2, y2 = self:_wToS(r[3], r[4])
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end
    return math.floor(x1), math.floor(y1), math.ceil(x2), math.ceil(y2)
end

-- ---------------------------------------------------------------------------
-- Handles - same table-driven anchor model LSGridOverlay uses, so there is no
-- positional index switch anywhere and the two editors describe a resize the
-- same way.
-- ---------------------------------------------------------------------------

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

local function handlePoints(x1, y1, x2, y2)
    local pts = {}
    for i, a in ipairs(ANCHORS) do
        pts[i] = { sx = edgePos(x1, x2, a.xEdge), sy = edgePos(y1, y2, a.yEdge) }
    end
    return pts
end

local function hitHandle(sx, sy, x1, y1, x2, y2)
    for i, h in ipairs(handlePoints(x1, y1, x2, y2)) do
        if math.abs(sx - h.sx) <= HANDLE_HIT_R and math.abs(sy - h.sy) <= HANDLE_HIT_R then
            return i
        end
    end
    return nil
end

-- Push back on the edge being dragged, never on its anchor.
local function clampSpan(lo, hi, edge)
    if hi - lo >= MIN_SPAN then return lo, hi end
    if     edge == "min" then return hi - MIN_SPAN, hi
    elseif edge == "max" then return lo, lo + MIN_SPAN end
    return lo, hi
end

function LMMapEditor:_applyHandle(wx, wy)
    local r = self._dragRect
    local a = ANCHORS[self._handleIdx]
    if not (r and a and self._handleOrig) then return end
    local o = self._handleOrig
    local x1, y1, x2, y2 = o[1], o[2], o[3], o[4]

    if     a.xEdge == "min" then x1 = wx
    elseif a.xEdge == "max" then x2 = wx end
    if     a.yEdge == "min" then y1 = wy
    elseif a.yEdge == "max" then y2 = wy end

    x1, x2 = clampSpan(x1, x2, a.xEdge)
    y1, y2 = clampSpan(y1, y2, a.yEdge)

    r[1], r[2] = math.floor(x1), math.floor(y1)
    r[3], r[4] = math.floor(x2), math.floor(y2)
end

function LMMapEditor:_applyBody(wx, wy)
    local r = self._dragRect
    if not (r and self._bodyOrig and self._bodyStartW) then return end
    local o  = self._bodyOrig
    local dx = wx - self._bodyStartW[1]
    local dy = wy - self._bodyStartW[2]
    r[1], r[2] = math.floor(o[1] + dx), math.floor(o[2] + dy)
    r[3], r[4] = math.floor(o[3] + dx), math.floor(o[4] + dy)
end

-- ---------------------------------------------------------------------------
-- Hit testing against the draft
-- ---------------------------------------------------------------------------

-- Zone + rect under a screen point. Prefers the selected zone (so a rect drawn
-- underneath another cannot steal its own handles back), then the SMALLEST
-- containing rect - the same "smallest wins" tie-break Limes.getLocation uses
-- for overlaps, so clicking picks the zone the game would actually resolve.
function LMMapEditor:_hitZone(sx, sy)
    if not self.draft then return nil end

    local function hit(name)
        local rec = self.draft:get(name)
        if not rec or not rec.rects then return nil end
        for i = 1, #rec.rects do
            local x1, y1, x2, y2 = self:_screenRect(rec.rects[i])
            if sx >= x1 and sx <= x2 and sy >= y1 and sy <= y2 then
                return i, (x2 - x1) * (y2 - y1)
            end
        end
        return nil
    end

    if self.selected then
        local i = hit(self.selected)
        if i then return self.selected, i end
    end

    local bestName, bestIdx, bestArea = nil, nil, nil
    for _, name in ipairs(self.draft:names()) do
        if name ~= self.selected then
            local i, area = hit(name)
            if i and (bestArea == nil or area < bestArea) then
                bestName, bestIdx, bestArea = name, i, area
            end
        end
    end
    return bestName, bestIdx
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

local function shiftDown()
    return isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT)
end
local function ctrlDown()
    return isKeyDown(Keyboard.KEY_LCONTROL) or isKeyDown(Keyboard.KEY_RCONTROL)
end

function LMMapEditor:_onMouseDown(widget, x, y)
    self._clickX, self._clickY = x, y
    if self.locked or not self.draft then return end

    -- Ctrl-drag draws a NEW rectangle onto the selected zone. Deliberately
    -- modified rather than a mode: a mode has to be entered, shown, and left,
    -- and an editor that is silently in the wrong one is worse than one that
    -- needs a key held.
    if ctrlDown() and self.selected then
        local wx, wy = self:_sToW(x, y)
        local rec = self.draft:get(self.selected)
        if rec then
            rec.rects = rec.rects or {}
            -- Seeded from the VIEW, not from MIN_SPAN: a ctrl-CLICK with no drag
            -- has to leave something you can see and grab, and eight tiles at
            -- region zoom is two pixels.
            local seed = self:_seedSpan()
            local r = { math.floor(wx), math.floor(wy),
                        math.floor(wx) + seed, math.floor(wy) + seed }
            rec.rects[#rec.rects + 1] = r
            self.rectIdx    = #rec.rects
            self._newDrag   = true
            self._newStartW = { math.floor(wx), math.floor(wy) }
            self._dragRect  = r
            widget:setCapture(true)
            return
        end
    end

    local r = self:selectedRect()
    if r then
        local x1, y1, x2, y2 = self:_screenRect(r)
        local h = hitHandle(x, y, x1, y1, x2, y2)
        if h then
            self._handleDrag = true
            self._handleIdx  = h
            self._handleOrig = { r[1], r[2], r[3], r[4] }
            self._dragRect   = r
            widget:setCapture(true)
            return
        end
        if shiftDown() and x >= x1 and x <= x2 and y >= y1 and y <= y2 then
            local wx, wy = self:_sToW(x, y)
            self._bodyDrag   = true
            self._bodyOrig   = { r[1], r[2], r[3], r[4] }
            self._bodyStartW = { wx, wy }
            self._dragRect   = r
            widget:setCapture(true)
            return
        end
    end
end

function LMMapEditor:_onMouseMove(widget, x, y)
    if not self:_consuming() then return end
    local wx, wy = self:_sToW(x, y)
    if self._handleDrag then
        self:_applyHandle(wx, wy)
    elseif self._bodyDrag then
        self:_applyBody(wx, wy)
    elseif self._newDrag then
        local s = self._newStartW
        local r = self._dragRect
        local x1, x2 = math.min(s[1], wx), math.max(s[1], wx)
        local y1, y2 = math.min(s[2], wy), math.max(s[2], wy)
        local floorSpan = math.max(MIN_SPAN, math.floor(self:_seedSpan() / 8))
        if x2 - x1 < floorSpan then x2 = x1 + floorSpan end
        if y2 - y1 < floorSpan then y2 = y1 + floorSpan end
        r[1], r[2] = math.floor(x1), math.floor(y1)
        r[3], r[4] = math.floor(x2), math.floor(y2)
    end
end

function LMMapEditor:_onMouseUp(widget, x, y)
    if self:_consuming() then
        widget:setCapture(false)
        local name = self.selected
        self._handleDrag, self._handleIdx, self._handleOrig = false, nil, nil
        self._bodyDrag,   self._bodyOrig,  self._bodyStartW = false, nil, nil
        self._newDrag,    self._newStartW                   = false, nil
        self._dragRect = nil
        if name and self.onEdited then self.onEdited(name) end
        return true
    end

    local dx = self._clickX and math.abs(x - self._clickX) or 999
    local dy = self._clickY and math.abs(y - self._clickY) or 999
    self._clickX, self._clickY = nil, nil
    if dx <= 4 and dy <= 4 and not self.locked then
        local name, idx = self:_hitZone(x, y)
        if name then
            -- Clicking the already-selected zone cycles through ITS rects, so a
            -- nine-rect zone is fully reachable with the mouse alone rather
            -- than only through the list.
            if name == self.selected and idx == self.rectIdx then
                local rec = self.draft and self.draft:get(name)
                local n = rec and rec.rects and #rec.rects or 0
                if n > 1 then idx = (self.rectIdx % n) + 1 end
            end
            self.selected, self.rectIdx = name, idx
            if self.onSelect then self.onSelect(name, idx) end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function LMMapEditor:_render(widget)
    if not self:_api() or not self.draft then return end
    widget:setStencilRect(0, 0, widget.width, widget.height)

    local names = self.draft:names()
    -- Unselected first, so the selected zone's outline and handles are never
    -- drawn under a neighbour that happens to sort after it.
    for i = 1, #names do
        if names[i] ~= self.selected and self.showAll then
            self:_renderZone(widget, names[i], false)
        end
    end
    if self.selected then self:_renderZone(widget, self.selected, true) end

    if #names == 0 then
        self:_hint(widget, "No zones. Add one from the list, then Ctrl-drag here to draw it.")
    elseif not self.selected then
        self:_hint(widget, "Pick a zone - click it on the map, or choose it from the list.")
    end

    widget:clearStencilRect()
end

function LMMapEditor:_renderZone(widget, name, isSel)
    local rec = self.draft:get(name)
    if not rec or not rec.rects or #rec.rects == 0 then return end

    local c = colourFor(name)
    -- A disabled zone still occupies the map and still has to be findable, so
    -- it is dimmed rather than hidden - hiding it makes "why is nothing
    -- happening here" unanswerable from the editor.
    local off = rec.fields and (rec.fields.disabled == true or rec.fields.disabled == "true")
    local fillA   = (isSel and 0.22 or 0.10) * (off and 0.4 or 1)
    local borderA = (isSel and 1.00 or 0.55) * (off and 0.5 or 1)

    local vw, vh = widget.width, widget.height
    for i = 1, #rec.rects do
        local x1, y1, x2, y2 = self:_screenRect(rec.rects[i])
        -- Cull to the viewport. At world zoom most of a 76-zone layer is off
        -- screen, and drawRect on coordinates in the tens of thousands is not
        -- free just because nothing comes of it.
        if x2 >= 0 and y2 >= 0 and x1 <= vw and y1 <= vh then
            local w, h = x2 - x1, y2 - y1
            if w >= 1 and h >= 1 then
                widget:drawRect(x1, y1, w, h, fillA, c[1], c[2], c[3])
                widget:drawRectBorder(x1, y1, w, h, borderA, c[1], c[2], c[3])

                local active = isSel and i == self.rectIdx
                if active then
                    widget:drawRectBorder(x1 + 1, y1 + 1, w - 2, h - 2, 0.6, 1, 1, 1)
                    if not self.locked then
                        for _, hd in ipairs(handlePoints(x1, y1, x2, y2)) do
                            widget:drawRect(hd.sx - HANDLE_R, hd.sy - HANDLE_R,
                                HANDLE_R * 2, HANDLE_R * 2, 0.9, 0.06, 0.06, 0.08)
                            widget:drawRectBorder(hd.sx - HANDLE_R, hd.sy - HANDLE_R,
                                HANDLE_R * 2, HANDLE_R * 2, 1, 0.98, 0.98, 0.98)
                        end
                    end
                end

                -- Labels are earned: the selected zone always gets one, anything
                -- else only when its rect is wide enough to read. 76 zones of
                -- unconditional chrome is a wall of text, not a map.
                if isSel or w >= LABEL_MIN_PX then
                    local label = name
                    if #rec.rects > 1 then label = label .. " [" .. i .. "/" .. #rec.rects .. "]" end
                    if off then label = label .. " (off)" end
                    local lw = getTextManager():MeasureStringX(FONT, label)
                    widget:drawRect(x1 + 1, y1 + 1, lw + 6, FONT_HGT + 2, 0.75, 0.05, 0.05, 0.08)
                    widget:drawText(label, x1 + 4, y1 + 2, c[1], c[2], c[3],
                        isSel and 1.0 or 0.8, FONT)
                end
            end
        end
    end
end

function LMMapEditor:_hint(widget, msg)
    local tw = getTextManager():MeasureStringX(FONT, msg)
    local px = math.floor((widget.width - tw) / 2)
    local py = math.floor(widget.height / 2 - FONT_HGT / 2)
    widget:drawRect(px - 10, py - 6, tw + 20, FONT_HGT + 12, 0.78, 0.05, 0.05, 0.08)
    widget:drawRectBorder(px - 10, py - 6, tw + 20, FONT_HGT + 12, 0.85, 0.90, 0.55, 0.10)
    widget:drawText(msg, px, py, 0.95, 0.85, 0.55, 1.0, FONT)
end

-- ---------------------------------------------------------------------------
-- Framing
-- ---------------------------------------------------------------------------

-- Put the named zone on screen. Frames its whole bounding box, not the largest
-- rect: unlike a teleport, which has to land somewhere standable, the point of
-- looking at a split zone is seeing that it IS split.
function LMMapEditor:frameZone(name)
    local rec = self.draft and self.draft:get(name)
    if not rec or not rec.rects or #rec.rects == 0 then return false end
    local b = { rec.rects[1][1], rec.rects[1][2], rec.rects[1][3], rec.rects[1][4] }
    for i = 2, #rec.rects do
        local r = rec.rects[i]
        if r[1] < b[1] then b[1] = r[1] end
        if r[2] < b[2] then b[2] = r[2] end
        if r[3] > b[3] then b[3] = r[3] end
        if r[4] > b[4] then b[4] = r[4] end
    end
    if self.host and self.host.zoomAndCentreMapToBounds then
        self.host:zoomAndCentreMapToBounds(b[1], b[2], b[3], b[4])
    end
    return true
end

return LMMapEditor

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
