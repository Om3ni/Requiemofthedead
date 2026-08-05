-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFScroll - the family's scroll primitive for DRAWN surfaces (client only).
--
-- WHY THIS EXISTS. PZ gives us ISScrollingListBox and nothing else. That widget
-- is fine when every row is a widget, and useless the moment a pane is drawn in
-- prerender - which is how most of this suite's dense surfaces are built, because
-- a hundred part rows as a hundred ISUIElements is a hundred objects to lay out,
-- hit-test and garbage-collect every frame.
--
-- So drawn panes grew their own scrolling, one at a time, and that is exactly the
-- duplication this file exists to stop. The Janitor dial form and the vehicle
-- parts grid were written days apart and had already diverged on the things a
-- user actually notices: thumb size, wheel distance, whether clicking the bare
-- track jumps, whether a half-scrolled row can still be clicked. Two
-- implementations means two sets of those answers and two places to fix each bug.
--
-- ONE implementation, therefore, and every drawn scrolling surface in the family
-- calls it. A pane looks and behaves the same wherever it appears, and a fix to
-- thumb behaviour is a fix everywhere rather than a survey.
--
-- WHAT IT IS NOT. It does not draw your content, own your rect, or know what a
-- row is. It owns exactly one number - how far down you are - plus the bar that
-- shows it and the arithmetic for moving it. Callers keep their own layout.
--
-- VIRTUAL SPACE, stated once because getting it wrong is silent. A virtual y is
-- SCREEN SPACE AT OFFSET ZERO - where the item would sit if nothing were
-- scrolled. So a caller lays out exactly as it always did, starting its cursor
-- at rect.y, and DFScroll shifts the result; it does not ask anyone to switch
-- to content-relative coordinates. The one asymmetry to know: measure() takes a
-- content HEIGHT (a length, origin-free), while screenY/shows take a virtual y
-- (which already has rect.y in it).
--
-- THE CONTRACT, in the order a caller uses it:
--
--   local sc = DFScroll.new()                     -- once, kept across frames
--
--   -- each frame, once you know how tall your content is:
--   local gutter = sc:measure(rect.h, contentH)   -- reserve this much width
--   ...lay out into (rect.w - gutter)...
--
--   sc:clip(el, rect)                             -- stencil to the pane
--   for each item at VIRTUAL y vy:
--       if sc:shows(vy, itemH, rect) then
--           draw at sc:screenY(vy)                -- and record hit rects HERE,
--       end                                       -- in screen space, only when
--   sc:unclip(el)                                 -- the item is actually shown
--
--   sc:draw(el, rect)                             -- the bar, last and unclipped
--
-- Mouse, from a hotspot over the pane, in the SAME space as the rect:
--   sc:wheel(del)      sc:press(px, py)      sc:drag(py)      sc:release()
--
-- INVARIANT WORTH KEEPING. Only record a hit rect for an item you actually
-- drew. An item scrolled out of sight that still answers a click is the bug
-- both call sites had to be talked out of independently - it lets a context
-- menu act on whatever happens to share those coordinates.

if isServer() then return end

DFScroll = DFScroll or {}
DFScroll.__index = DFScroll

-- Bar width and wheel distance are TOKENS, not per-caller taste. They live here
-- for the same reason DFForm's spacing constants live in DFForm: "the scrollbar
-- is a different width on this tab" is a bug report, not a design.
DFScroll.BAR_W = 8
DFScroll.WHEEL = 48     -- ~3 rows a notch on a typical dense grid

function DFScroll.new()
    return setmetatable({
        offset  = 0,    -- pixels hidden above the top edge
        max     = 0,    -- recomputed by measure() every frame
        bar     = nil,  -- last drawn bar geometry, caller space
        -- Named gesture, not drag: an instance field shadows a method of the
        -- same name through __index, so self:drag() would try to call the
        -- gesture table.
        gesture = nil,
    }, DFScroll)
end

-- Recompute the range for a pane of height h holding contentH of content.
-- Returns the width to reserve for the bar: BAR_W when it is needed, 0 when it
-- is not, so a pane that fits still uses its full width and grows no gutter.
--
-- Call this BEFORE laying out - the returned gutter changes the content width,
-- which can change the content height, which is why the caller measures first
-- and this only does arithmetic.
function DFScroll:measure(h, contentH)
    self.offset  = self.offset or 0
    self.content = contentH
    self.paneH   = h
    self.max     = math.max(0, contentH - h)
    if self.offset > self.max then self.offset = self.max end
    if self.offset < 0 then self.offset = 0 end
    return (self.max > 0) and DFScroll.BAR_W or 0
end

-- Where a virtual y lands on screen.
function DFScroll:screenY(vy) return vy - self.offset end

-- Is an item at virtual y, itemH tall, inside the pane at all? False means draw
-- nothing AND record no hit rect.
function DFScroll:shows(vy, itemH, rect)
    local y = vy - self.offset
    return y + itemH >= rect.y and y <= rect.y + rect.h
end

-- Stencil helpers. Items straddling an edge have to be cut off rather than
-- allowed to paint over whatever the host drew above and below the pane.
function DFScroll:clip(el, rect)
    el:setStencilRect(rect.x, rect.y, rect.w, rect.h)
end

function DFScroll:unclip(el)
    el:clearStencilRect()
end

-- The bar. Draw it AFTER unclip so it is never clipped by the same rect its
-- content is, and last so it sits above that content.
function DFScroll:draw(el, rect, col)
    if (self.max or 0) <= 0 then self.bar = nil; return end
    local c  = col or DFKit.col
    local bx = rect.x + rect.w - DFScroll.BAR_W

    local thumbH = math.floor(rect.h * rect.h / math.max(1, self.content or rect.h))
    local minH   = math.min(rect.h, 24)
    if thumbH < minH then thumbH = minH end
    if thumbH > rect.h then thumbH = rect.h end

    local travel = rect.h - thumbH
    local thumbY = rect.y + math.floor(travel * (self.offset / self.max))

    el:drawRect(bx, rect.y, DFScroll.BAR_W, rect.h, 0.25, c.bg.r, c.bg.g, c.bg.b)
    el:drawRect(bx + 1, thumbY, DFScroll.BAR_W - 2, thumbH, 0.8,
        c.accent.r, c.accent.g, c.accent.b)

    self.bar = { x = bx, y = rect.y, w = DFScroll.BAR_W, h = rect.h,
                 thumbY = thumbY, thumbH = thumbH }
end

-- ---------------------------------------------------------------------------
-- Movement
-- ---------------------------------------------------------------------------

function DFScroll:scrollBy(dy)
    local max = self.max or 0
    if max <= 0 then return false end
    local s = (self.offset or 0) + dy
    if s < 0 then s = 0 elseif s > max then s = max end
    if s == self.offset then return false end
    self.offset = s
    return true
end

-- del is +1 down / -1 up in PZ. Returns true when it moved, so a caller can
-- report the wheel as handled and stop it bubbling.
function DFScroll:wheel(del, step)
    return self:scrollBy((del > 0 and 1 or -1) * (step or DFScroll.WHEEL))
end

function DFScroll:reset() self.offset = 0 end

-- Put the thumb's TOP at ty and derive the offset, so the grab point under the
-- cursor stays put for the whole drag instead of snapping to centre.
local function toThumb(self, ty)
    local b = self.bar
    if not b or (self.max or 0) <= 0 then return end
    local travel = b.h - b.thumbH
    if travel <= 0 then return end
    local t = (ty - b.y) / travel
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    self.offset = math.floor(t * self.max)
end

-- Returns true when the press belongs to the bar. That is also the caller's
-- signal that this is a drag and not a click on whatever is underneath.
function DFScroll:press(px, py)
    local b = self.bar
    if not b then return false end
    if px < b.x or px >= b.x + b.w then return false end
    if py >= b.thumbY and py < b.thumbY + b.thumbH then
        self.gesture = { grab = py - b.thumbY }
    else
        -- Clicked the bare track: centre the thumb there and carry on as a drag
        -- from that point, so an impatient jump can be corrected without
        -- letting go.
        local half = math.floor(b.thumbH / 2)
        toThumb(self, py - half)
        self.gesture = { grab = half }
    end
    return true
end

function DFScroll:drag(py)
    if not self.gesture then return false end
    toThumb(self, py - self.gesture.grab)
    return true
end

-- Returns true if a drag was in progress, which the caller uses to suppress the
-- click that would otherwise fire on release - the content moved under the
-- cursor while the thumb did.
function DFScroll:release()
    local was = self.gesture ~= nil
    self.gesture = nil
    return was
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
