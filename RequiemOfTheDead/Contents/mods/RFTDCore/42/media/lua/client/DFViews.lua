-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFViews - two or more views behind one tab, sharing a strip of buttons.
--
-- WHY THIS IS SHARED AND NOT COPIED. The pattern was written once inside
-- RCVehicleTab for Fleet|Janitor and immediately wanted a second home
-- (Animals|Hutches). It is forty lines, and the subtlest of them is the one
-- nobody would think to copy correctly:
--
--     setVisible(false) also stops an element receiving MOUSE EVENTS.
--
-- That is why switching is visibility rather than drawing over the top. A
-- second implementation that merely hid things visually would leave the
-- inactive view's buttons and hotspots clickable through the active one - a bug
-- that reads as "the panel sometimes does the wrong thing" and is miserable to
-- track down. One implementation, one place for that to be right.
--
-- THE VIEW CONTRACT. A view is any table implementing as much of this as it
-- needs; every method is optional and a missing one is simply not called.
--
--   attach(panel) -> flat widget list   built ONCE, host toggles visibility
--   layout(panel, x, y, w, h)           own everything inside your rect
--   draw(el)                            chrome pass, only while active
--   onShow()                            entered - refresh server state here
--
-- A view may also be nil, for a host that builds that view's widgets inline
-- (RCVehicleTab's Fleet view is the host itself). Register those with
-- setWidgets and everything else works identically.
--
-- WIDGETS ARE BUILT ONCE, never on switch. Rebuilding would drop selection,
-- scroll position and in-flight requests every time somebody looked at the
-- other view.

if isServer() then return end

require "DFKit"

DFViews = DFViews or {}
DFViews.__index = DFViews

-- spec = {
--   views    = { { id, label, w, tip, view }, ... }   -- order is strip order
--   relayout = function() end                          -- after a switch
-- }
-- The FIRST view is the landing view. Order it deliberately: the one somebody
-- opens the tab to use goes first, and the one they go to on purpose second.
function DFViews.new(spec)
    local self = setmetatable({}, DFViews)
    self.views    = {}
    self.order    = {}
    self.buttons  = {}
    self.relayout = spec and spec.relayout
    for _, v in ipairs((spec and spec.views) or {}) do
        if v.id then
            self.views[v.id] = { id = v.id, label = v.label or v.id, w = v.w or 80,
                                 tip = v.tip, view = v.view, widgets = {} }
            self.order[#self.order + 1] = v.id
        end
    end
    self.activeId = self.order[1]
    return self
end

-- Build the strip. Returns the buttons so the host can keep them in its own
-- always-visible set - the strip belongs to the tab, not to either view, and
-- must never be hidden by a switch.
function DFViews:attachStrip(panel)
    for _, id in ipairs(self.order) do
        local v = self.views[id]
        local b = DFKit.button(panel, 0, 0, v.w, v.label, panel, function()
            self:set(id)
        end, "action", { tooltip = v.tip })
        b.dfView = id
        self.buttons[#self.buttons + 1] = b
    end
    return self.buttons
end

-- Call each view's attach(panel) and record what it returns. A view with no
-- attach (the host builds it inline) is skipped and registered via setWidgets.
function DFViews:attachViews(panel)
    for _, id in ipairs(self.order) do
        local v = self.views[id]
        if v.view and v.view.attach then
            v.widgets = v.view.attach(panel) or {}
        end
    end
end

-- Register the widget list for a view the host built itself.
function DFViews:setWidgets(id, widgets)
    local v = self.views[id]
    if v then v.widgets = widgets or {} end
end

function DFViews:active() return self.activeId end

function DFViews:activeView()
    local v = self.views[self.activeId]
    return v and v.view or nil
end

-- Position the strip left to right from (x, y). Returns the x the strip ended
-- at, so a host can put something after it.
function DFViews:layoutStrip(x, y)
    for _, b in ipairs(self.buttons) do
        b:setX(x); b:setY(y)
        x = x + b:getWidth() + 2
    end
    return x
end

-- Switch. Unknown ids fall back to the landing view rather than leaving the
-- panel showing nothing, which is what a stale saved id would otherwise do.
function DFViews:set(id)
    if not self.views[id] then id = self.order[1] end
    if not id then return end
    self.activeId = id

    for _, vid in ipairs(self.order) do
        local v = self.views[vid]
        local on = (vid == id)
        for _, wdg in ipairs(v.widgets or {}) do
            -- pcall per widget: a view's list can hold anything a tab put in
            -- it, and one bad entry must not leave the rest of the panel in a
            -- half-switched state.
            if wdg then pcall(function() wdg:setVisible(on) end) end
        end
    end

    for _, b in ipairs(self.buttons) do
        b.borderColor = (b.dfView == id)
            and { r = DFKit.col.accent.r, g = DFKit.col.accent.g, b = DFKit.col.accent.b, a = 0.9 }
            or  { r = DFKit.col.line.r,   g = DFKit.col.line.g,   b = DFKit.col.line.b,   a = 0.4 }
    end

    -- Relayout BEFORE onShow. onShow usually fires a server request whose reply
    -- paints into rects the switch just changed; doing it the other way round
    -- can land a reply against the outgoing view's geometry. Both are tab-owned
    -- callbacks: one view's fault must not leave the switch half-done.
    if self.relayout then pcall(self.relayout) end

    local v = self.views[id]
    if v.view and v.view.onShow then pcall(v.view.onShow) end
end

-- Chrome pass for whichever view is active. Hosts that draw their own active
-- view inline can ignore this; it exists so a host does not need to know which
-- of its views happens to have a draw method.
function DFViews:draw(el)
    local v = self.views[self.activeId]
    -- tab-owned callback; a draw fault must not kill the host's render pass
    if v and v.view and v.view.draw then pcall(v.view.draw, el) end
end

-- Layout the active view into the body rect the host has left after its strip.
function DFViews:layoutActive(panel, x, y, w, h)
    local v = self.views[self.activeId]
    -- tab-owned callback; a layout fault must not break the host's resize
    if v and v.view and v.view.layout then
        pcall(v.view.layout, panel, x, y, w, h)
    end
end

print("[Core] DFViews loaded (one tab, many views)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
