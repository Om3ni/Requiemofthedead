-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSettingsWindow - the deck's settings wheel popout (client only).
--
-- LIVES IN CORE, NOT IN DRAGONFLY. The gear that opens it is deck chrome, but
-- what it edits is DFPrefs - a Core concern that every tab in every mod reads.
-- Putting the window here means the old DFPanel, the deck, or anything else
-- that grows a settings entry point all open the SAME window rather than each
-- growing their own copy of it.
--
-- IT RENDERS A SCHEMA, IT DOES NOT KNOW WHAT THE SETTINGS ARE. The whole body
-- is a DFForm over DFPrefs.SCHEMA, so adding a preference is one schema entry
-- in DFPrefs and nothing here changes. That is the same contract the Janitor
-- view uses for server dials; this window is simply the client-side twin.
--
-- APPLIES IMMEDIATELY, no Save. Every change writes through DFPrefs.set, which
-- persists and re-applies in one step, and the listener wakes any open panel to
-- re-lay-out. A settings dialogue with an OK button would be lying about when
-- the change happens - you can see it happen behind the window as you click.

if isServer() then return end

require "ISUI/ISPanel"
require "DFPrefs"
require "DFForm"
require "DFHelp"

DFSettingsWindow = ISPanel:derive("DFSettingsWindow")

-- Survives a hot reload, same reasoning as DFDeckState: a window referenced
-- only from a class global becomes unclosable when the global is replaced.
DFSettingsState = DFSettingsState or { instance = nil }

local W       = 430
local TITLE_H = 28
local PAD     = 10
local FOOT_H  = 34

function DFSettingsWindow:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.background    = false
    o.moveWithMouse = false
    o.dragging      = false
    o.dragDX, o.dragDY = 0, 0
    return o
end

function DFSettingsWindow:createChildren()
    self.form = DFForm.new{
        schema = DFPrefs.SCHEMA,
        title  = "Display",
        get    = function(k) return DFPrefs.get(k) end,
        set    = function(k, v) DFPrefs.set(k, v) end,
        -- No `moved`: these ARE the user's own values, so every row would be
        -- marked and the gutter tick would mean nothing.
    }
    self.form:attach(self)

    self.btnReset = DFKit.button(self, 0, 0, 120, "Reset to defaults", self, function()
        DFPrefs.reset()
    end, "warn", { hold = true,
        tooltip = "Put text size and opacity back to how they shipped." })

    self.btnClose = DFKit.button(self, 0, 0, 80, "Close", self, function()
        DFSettingsWindow.close()
    end, "primary")

    self:layoutBody()
end

function DFSettingsWindow:layoutBody()
    local bodyY = TITLE_H + PAD
    local bodyH = self.height - TITLE_H - PAD * 2 - FOOT_H
    self.form:layout(PAD, bodyY, self.width - PAD * 2, bodyH)

    local fy = self.height - FOOT_H + 4
    self.btnReset:setX(PAD);                  self.btnReset:setY(fy)
    self.btnClose:setX(self.width - 80 - PAD); self.btnClose:setY(fy)
end

function DFSettingsWindow:prerender()
    local c = DFKit.col
    local a = DFKit.alpha
    local w, h = self.width, self.height

    -- Deliberately more opaque than a tab panel, for the same reason DFHelp is:
    -- this window exists to be read and acted on, and it is also the only place
    -- to fix an opacity setting that has been dragged too low.
    self:drawRect(0, 0, w, h, math.min(0.95, (a.window or 0.6) + 0.3),
        c.bg.r, c.bg.g, c.bg.b)
    self:drawRectBorder(0, 0, w, h, 0.7, c.accent.r, c.accent.g, c.accent.b)

    local fTitle = DFKit.font.label or UIFont.Small
    self:drawRect(0, 0, w, TITLE_H, 0.5, c.panel.r, c.panel.g, c.panel.b)
    self:drawText("DECK SETTINGS", PAD, 7, c.text.r, c.text.g, c.text.b, 1, fTitle)
    self:drawText("X", w - 18, 7,
        self.hoverClose and c.accent.r or c.textDim.r,
        self.hoverClose and c.accent.g or c.textDim.g,
        self.hoverClose and c.accent.b or c.textDim.b, 1, fTitle)
    self:drawRect(0, TITLE_H, w, 1, 0.4, c.line.r, c.line.g, c.line.b)

    self.form:draw(self)
end

function DFSettingsWindow:onMouseMove(dx, dy)
    local x, y = self:getMouseX(), self:getMouseY()
    self.hoverClose = (y < TITLE_H and x > self.width - 26)
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFSettingsWindow:onMouseMoveOutside(dx, dy)
    self.hoverClose = false
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFSettingsWindow:onMouseDown(x, y)
    if y < TITLE_H then
        if x > self.width - 26 then DFSettingsWindow.close(); return end
        self.dragging = true
        self.dragDX = getMouseX() - self:getX()
        self.dragDY = getMouseY() - self:getY()
    end
end

function DFSettingsWindow:onMouseUp()        self.dragging = false end
function DFSettingsWindow:onMouseUpOutside() self.dragging = false end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
function DFSettingsWindow.close()
    local w = DFSettingsState.instance
    if w then
        pcall(function() w:removeFromUIManager() end)
        DFSettingsState.instance = nil
    end
    DFHelp.close()
end

function DFSettingsWindow.isOpen()
    return DFSettingsState.instance ~= nil
end

function DFSettingsWindow.open(nearX, nearY)
    if DFSettingsState.instance then DFSettingsWindow.close(); return nil end

    -- Sized from the schema rather than a magic number, so adding a preference
    -- grows the window instead of silently pushing a row off the bottom.
    local probe = DFForm.new{ schema = DFPrefs.SCHEMA, get = function() end }
    local h = TITLE_H + PAD * 2 + FOOT_H + probe:contentHeight()

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x = nearX and (nearX - W + 40) or math.floor((sw - W) / 2)
    local y = nearY and (nearY + 12) or math.floor((sh - h) / 2)
    if x + W > sw - 8 then x = sw - W - 8 end
    if y + h > sh - 8 then y = sh - h - 8 end
    if x < 8 then x = 8 end
    if y < 8 then y = 8 end

    local win = DFSettingsWindow:new(x, y, W, h)
    win:initialise()
    win:instantiate()
    win:addToUIManager()
    DFSettingsState.instance = win
    return win
end

function DFSettingsWindow.toggle(nearX, nearY)
    if DFSettingsState.instance then DFSettingsWindow.close()
    else DFSettingsWindow.open(nearX, nearY) end
end

-- The font may have changed under an open window, which changes how tall its
-- rows are. Re-lay-out rather than leaving the footer overlapping the last row.
DFPrefs.onChange(function()
    local w = DFSettingsState.instance
    if w then pcall(function() w:layoutBody() end) end
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
