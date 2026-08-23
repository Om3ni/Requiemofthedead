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
    self.failures = {}
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

-- A view can be supplied by any suite tab. A failure must not strand the host
-- mid-switch or kill its render pass, but a per-frame console flood is not a
-- recovery either. Name each failed operation once for this tab instance.
local function reportFailure(self, operation, id, err)
    local key = operation .. "\0" .. tostring(id)
    if self.failures[key] then return end
    self.failures[key] = true
    print("[Core] DFViews " .. operation .. " failed (" .. tostring(id) .. "): " .. tostring(err))
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

-- The standard host layout: claim a strip along the top, give the rest to
-- whichever view is active.
--
-- PROMOTED 2026-08-23 because it was written twice, identically, and
-- check-helpers said so - HBHusbandryTab and the Admin tab had the same
-- thirteen lines. That is not a coincidence to be tolerated: it is what hosting
-- a DFViews strip IS, and the two copies would drift on the strip's height the
-- first time anyone adjusted one.
--
-- The strip is claimed FIRST, above anything either view owns, so it stays put
-- while the body underneath changes completely. A host with its own chrome to
-- place can still do the two calls by hand; this is the common case, not a
-- mandate.
function DFViews:layoutHost(panel, x, y, w, h)
    local m = DFKit.metrics
    local R = DFKit.layout(panel, x, y, w, h)
    local strip = R:header(m.btnH + m.gap)
    self:layoutStrip(strip.x, strip.y)
    local body = R:rest()
    self:layoutActive(panel, body.x, body.y, body.w, body.h)
    return body
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
        for index, wdg in ipairs(v.widgets or {}) do
            -- pcall per widget: a view's list can hold anything a tab put in
            -- it, and one bad entry must not leave the rest of the panel in a
            -- half-switched state.
            if wdg then
                local ok, err = pcall(function() wdg:setVisible(on) end)
                if not ok then reportFailure(self, "widget visibility", vid .. " #" .. index, err) end
            end
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
    if self.relayout then
        -- guarded: caller-owned relayout callback; preserve the completed
        -- visibility switch and continue to the active view's independent refresh.
        local ok, err = pcall(self.relayout)
        if not ok then reportFailure(self, "relayout", id, err) end
    end

    local v = self.views[id]
    if v.view and v.view.onShow then
        -- guarded: caller-owned view refresh; the active view is still usable
        -- when its optional refresh fails after a completed switch.
        local ok, err = pcall(v.view.onShow)
        if not ok then reportFailure(self, "onShow", id, err) end
    end
end

-- Chrome pass for whichever view is active. Hosts that draw their own active
-- view inline can ignore this; it exists so a host does not need to know which
-- of its views happens to have a draw method.
function DFViews:draw(el)
    local v = self.views[self.activeId]
    -- tab-owned callback; a draw fault must not kill the host's render pass
    if v and v.view and v.view.draw then
        local ok, err = pcall(v.view.draw, el)
        if not ok then reportFailure(self, "draw", self.activeId, err) end
    end
end

-- Layout the active view into the body rect the host has left after its strip.
function DFViews:layoutActive(panel, x, y, w, h)
    local v = self.views[self.activeId]
    -- tab-owned callback; a layout fault must not break the host's resize
    if v and v.view and v.view.layout then
        local ok, err = pcall(v.view.layout, panel, x, y, w, h)
        if not ok then reportFailure(self, "layout", self.activeId, err) end
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
