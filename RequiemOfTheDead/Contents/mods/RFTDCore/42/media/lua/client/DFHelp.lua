-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFHelp - the family's explain-this popout (client only).
--
-- ONE POPOUT, EVERY SURFACE. Any control anywhere in the suite can say what it
-- does by calling DFHelp.show(title, body). No caller owns a window, sizes a
-- box, or writes a word-wrapper - they hand over two strings and this places
-- the result. That matters because the alternative is what tooltips already
-- are: the same explanation re-typed per tab, drifting apart as the behaviour
-- changes under it.
--
-- WHY NOT A TOOLTIP. Tooltips die on mouse-out, cannot be read at length, and
-- cannot be kept open next to the control while you decide. These strings are
-- paragraphs about server policy - the kind of text an admin wants to sit and
-- read - so this is a real window: it stays until dismissed, and it never
-- steals input from the panel underneath.
--
-- SINGLETON, deliberately. Opening help on a second control REPLACES the first
-- rather than stacking, because a pile of half-forgotten popouts is how a
-- panel becomes unusable and there is no sensible reason to compare two help
-- texts side by side.

if isServer() then return end

require "ISUI/ISPanel"

DFHelp = ISPanel:derive("DFHelp")

-- Survives a hot reload of this file: a window referenced only from the class
-- global would become unclosable the moment the global is replaced.
DFHelpState = DFHelpState or { instance = nil }

local PAD   = 12
local MAX_H = 460

-- Measured, not fixed: text size is a client preference, and a 16px line at a
-- 20px glyph overlaps the line below it. Width scales too, because a wrap
-- column that stays put while the glyphs grow ends up three words per line.
local function fontBody()  return DFKit.font.small or UIFont.Small end
local function fontTitle() return DFKit.font.label or UIFont.Small end

-- getFontHeight/MeasureStringX (TextManager:127) NPE on a font this build
-- lacks; each measure below keeps its fallback behind the guard.

local function lineH()
    local fh = 14
    pcall(function() fh = getTextManager():getFontHeight(fontBody()) end)
    return math.max(14, fh + 2)
end

local function titleH()
    local fh = 14
    pcall(function() fh = getTextManager():getFontHeight(fontTitle()) end)
    return math.max(24, fh + 12)
end

local function width()
    -- Roughly 62 characters of the current font, which keeps prose near the
    -- comfortable measure at every size instead of only at Small.
    local w = 380
    pcall(function()
        w = getTextManager():MeasureStringX(fontBody(),
            "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij") + PAD * 2
    end)
    return math.max(320, math.min(w, 620))
end

-- ---------------------------------------------------------------------------
-- Word wrap. The implementation moved to DFKit.wrapText when DFEntry needed the
-- same thing to lay out a validation rule - two copies of a wrapper is how the
-- two surfaces end up disagreeing about what a paragraph break does. This shim
-- stays so the call sites below read the same as they always did.
-- ---------------------------------------------------------------------------
local function wrap(text, font, maxW)
    return DFKit.wrapText(text, font, maxW)
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
function DFHelp:new(x, y, w, h, title, body)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.background    = false
    o.moveWithMouse = false
    o.titleText     = title or "About this setting"
    o.bodyText      = body or ""
    o.dragging      = false
    o.dragDX, o.dragDY = 0, 0
    return o
end

function DFHelp:prerender()
    local c = DFKit.col
    local a = DFKit.alpha
    local w, h = self.width, self.height

    -- Ground: deliberately more opaque than a panel. This is text to be read,
    -- and the world showing through prose is exactly the complaint that
    -- produced the opacity preference in the first place.
    self:drawRect(0, 0, w, h, math.min(0.95, (a.window or 0.6) + 0.3),
        c.bg.r, c.bg.g, c.bg.b)
    self:drawRectBorder(0, 0, w, h, 0.7, c.accent.r, c.accent.g, c.accent.b)

    local fTitle, fBody = fontTitle(), fontBody()
    local th, lh = titleH(), lineH()

    self:drawRect(0, 0, w, th, 0.5, c.panel.r, c.panel.g, c.panel.b)
    local ty = math.floor((th - lh) / 2) + 1
    self:drawText(self.titleText, PAD, ty, c.text.r, c.text.g, c.text.b, 1, fTitle)

    local closeHot = self.hoverClose
    self:drawText("X", w - 18, ty,
        closeHot and c.accent.r or c.textDim.r,
        closeHot and c.accent.g or c.textDim.g,
        closeHot and c.accent.b or c.textDim.b, 1, fTitle)
    self:drawRect(0, th, w, 1, 0.4, c.line.r, c.line.g, c.line.b)

    local y = th + PAD
    for _, ln in ipairs(self.lines or {}) do
        if ln ~= "" then
            self:drawText(ln, PAD, y, c.text.r, c.text.g, c.text.b, 0.95, fBody)
        end
        y = y + lh
    end
end

function DFHelp:onMouseMove(dx, dy)
    local x, y = self:getMouseX(), self:getMouseY()
    self.hoverClose = (y < titleH() and x > self.width - 26)
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFHelp:onMouseMoveOutside(dx, dy)
    self.hoverClose = false
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFHelp:onMouseDown(x, y)
    if y < titleH() then
        if x > self.width - 26 then DFHelp.close(); return end
        self.dragging = true
        self.dragDX = getMouseX() - self:getX()
        self.dragDY = getMouseY() - self:getY()
    end
end

function DFHelp:onMouseUp()        self.dragging = false end
function DFHelp:onMouseUpOutside() self.dragging = false end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
function DFHelp.close()
    local w = DFHelpState.instance
    if w then
        -- vanilla ISUI Lua teardown; a fault must still null the instance
        pcall(function() w:removeFromUIManager() end)
        DFHelpState.instance = nil
    end
end

-- Show help. nearX/nearY are optional: when given the window opens beside that
-- point rather than centre-screen, so the explanation appears next to the
-- control that raised it instead of somewhere the eye has to go looking.
function DFHelp.show(title, body, nearX, nearY)
    DFHelp.close()

    local fBody = fontBody()
    local W = width()
    local lines = wrap(body, fBody, W - PAD * 2)
    local h = math.min(MAX_H, titleH() + PAD * 2 + #lines * lineH())

    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local x = nearX and (nearX + 16) or math.floor((sw - W) / 2)
    local y = nearY and (nearY - 20) or math.floor((sh - h) / 2)

    -- Keep it on screen: opening beside a control near the right or bottom
    -- edge would otherwise put half the text outside the window.
    if x + W > sw - 8 then x = math.max(8, (nearX or sw) - W - 16) end
    if y + h > sh - 8 then y = math.max(8, sh - h - 8) end
    if x < 8 then x = 8 end
    if y < 8 then y = 8 end

    local win = DFHelp:new(x, y, W, h, title, body)
    win.lines = lines
    win:initialise()
    win:instantiate()
    win:addToUIManager()
    DFHelpState.instance = win
    return win
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
