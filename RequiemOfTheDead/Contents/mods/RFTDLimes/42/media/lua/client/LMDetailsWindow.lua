-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMDetailsWindow - the Details surface, popped out (S7 of the redesign).
--
-- The owner's locked decision: Details is its OWN floating window, opened
-- from a zone's right-click menu, never a strip tab - so an admin can hold a
-- zone's dials and the map on screen at once instead of flipping between
-- them. The LMImportWindow dual-host pattern, exactly: this window supplies a
-- frame; the content is LMDetailsView, unchanged and unduplicated - the mod
-- list, the per-registrant forms, the profiles block, and the "tonight's
-- effective values" strip all attach into the window's body the same way
-- they attached into the deck.
--
-- SELECTION FOLLOWS THE ZONE SELECTOR. The window polls the shared selection
-- a few times a second (the LMImportWindow throttle idiom - a subscription
-- would need an unsubscribe on every close route, and one left on a dead
-- window survives each reopen) and re-runs the view's refresh when it moves,
-- so right-clicking a different zone and choosing Edit Details... retargets
-- the open window instead of stacking a second one.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "LMDetailsView"

LMDetailsWindow = ISCollapsableWindow:derive("LMDetailsWindow")

local W, H = 720, 560
local POLL_FRAMES = 15

function LMDetailsWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight()
    self.body = ISPanel:new(0, top, self.width, self.height - top)
    self.body.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.body.borderColor     = { r = 0, g = 0, b = 0, a = 0 }
    self.body:initialise(); self.body:instantiate()
    self:addChild(self.body)
    LMDetailsView.attach(self.body)

    -- The forms are drawn chrome (DFForm), routed through the view's draw -
    -- the same chain LMZonesTab used to run for the strip view.
    local origPrerender = self.body.prerender
    self.body.prerender = function(p)
        if origPrerender then origPrerender(p) end
        LMDetailsView.draw(p)
    end

    self:onResize()
end

function LMDetailsWindow:onResize()
    ISCollapsableWindow.onResize(self)
    local top = self:titleBarHeight()
    if self.body then
        self.body:setWidth(self.width)
        self.body:setHeight(self.height - top)
        LMDetailsView.layout(self.body, 0, 0, self.width, self.height - top)
    end
end

function LMDetailsWindow:prerender()
    ISCollapsableWindow.prerender(self)
    self._tick = (self._tick or 0) + 1
    if self._tick < POLL_FRAMES then return end
    self._tick = 0
    local sel = LMEditView.selected()
    if sel ~= self._lastSel then
        self._lastSel = sel
        self:setTitle("Zone details" .. (sel and (" - " .. sel) or ""))
        LMDetailsView.onShow()
        self:onResize()      -- the effective strip appears/disappears with a selection
    end
end

function LMDetailsWindow:close()
    ISCollapsableWindow.close(self)
    LMDetailsWindow.instance = nil
    self:removeFromUIManager()
end

-- One window, retargeted by selection rather than stacked: LMDetailsView
-- keeps its widgets in a module-level singleton (the deck-era contract), so
-- a second attach would orphan the first window's forms.
function LMDetailsWindow.toggle()
    if LMDetailsWindow.instance then
        LMDetailsWindow.instance:removeFromUIManager()
        LMDetailsWindow.instance = nil
        return
    end
    local w = LMDetailsWindow:new(
        math.floor((getCore():getScreenWidth()  - W) / 2),
        math.floor((getCore():getScreenHeight() - H) / 2), W, H)
    w:initialise()
    w:instantiate()
    local sel = LMEditView.selected()
    w:setTitle("Zone details" .. (sel and (" - " .. sel) or ""))
    w._lastSel = sel
    w:addToUIManager()
    LMDetailsWindow.instance = w
    LMDetailsView.onShow()
end

return LMDetailsWindow

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
