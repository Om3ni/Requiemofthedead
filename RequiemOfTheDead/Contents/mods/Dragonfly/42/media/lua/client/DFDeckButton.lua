-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFDeckButton.lua - the deck's badge in the vanilla left sidebar, hung
-- directly beneath old Dragonfly's (client only).
--
-- THE INVERSION, on purpose and temporary: two identical marks in a column
-- would be a coin flip every click, so during incubation the deck wears the
-- old badge's states BACKWARD - the RED mark when the deck is CLOSED, the
-- GREEN mark when it is OPEN (the classic badge: green closed, red open).
-- One glance tells you which door is which and which panel is up. When the
-- deck graduates and DFPanel retires, the colors swap back to the family's
-- normal reading. Art is the classic badge's own set (media/ui/DFSidebar/
-- <W>/...) - same mod since the deck came home (2026-08-13; the server runs
-- one Dragonfly, not two) - and the text-badge fallback ("DECK") still
-- covers a missing texture.
--
-- MECHANISM: the same two-wrap ISEquippedItem patch DFSideButton documents
-- (initialise creates + shrinkWrap, prerender anchors + reflects state) -
-- read that header for the full why; the reasoning is not repeated here.
-- LOAD ORDER MOVED when the deck moved in: client files load alphabetically
-- within a mod and "DFDeckButton" sorts before "DFSideButton", so our wraps
-- are now INNER - each frame we anchor before the old badge re-anchors, and
-- read dfPanelBtn where the PREVIOUS frame left it. Benign: the column only
-- moves when the sidebar rebuilds, so the badge is off for at most the one
-- frame after that, and self-corrects. When the old badge is absent
-- (post-swap), we anchor on the bottom-most visible of the vanilla trio
-- exactly as it did.
--
-- RELOAD-SAFE like the rest of the deck: the wraps install once behind a
-- surviving sentinel - re-running this file must never stack a second wrap
-- chain onto ISEquippedItem (every stacked wrap is another full pass per
-- frame, forever).
--
-- ACCESS mirrors the old badge: hidden, not disabled, for anyone who fails
-- DFDeck.canOpen - the deck's existence is not advertised to non-staff.

if isServer() then return end
if not ISEquippedItem then return end

require "DFDeck"

DFDeckButton = DFDeckButton or {}

DFDeckBtnState = DFDeckBtnState or { wrapped = false }

local SPACING = 10
local SIZE_BUCKETS = { 48, 64, 80, 96, 128 }

local iconCache = {}   -- bucket -> { green = tex, red = tex } | false

local function tex(path)
    local t
    pcall(function() t = getTexture(path) end)
    return t
end

local function bucketFor(width)
    local best, bestDiff = SIZE_BUCKETS[#SIZE_BUCKETS], nil
    for _, b in ipairs(SIZE_BUCKETS) do
        local d = math.abs(b - (width or 0))
        if not bestDiff or d < bestDiff then best, bestDiff = b, d end
    end
    return best
end

-- The old set, by its honest colors: Off-art is the green mark, On-art the
-- red (verified against art/dragonfly masters). The deck draws them inverted.
local function resolveIcon(width)
    local b = bucketFor(width)
    local hit = iconCache[b]
    if hit ~= nil then return hit or nil end

    local green = tex("media/ui/DFSidebar/" .. b .. "/DF_Panel_Off_" .. b .. ".png")
    local red   = green and tex("media/ui/DFSidebar/" .. b .. "/DF_Panel_On_" .. b .. ".png") or nil

    if not green or not red then
        iconCache[b] = false
        return nil
    end
    iconCache[b] = { green = green, red = red }
    return iconCache[b]
end

local function deckOpen()
    return DFDeckState ~= nil and DFDeckState.instance ~= nil
       and DFDeckState.instance.getIsVisible ~= nil and DFDeckState.instance:getIsVisible()
end

local function mayOpen()
    if not DFDeck or not DFDeck.canOpen then return false end
    local s = SandboxVars.RFTDDragonfly or {}
    if s.Enabled == false then return false end
    local ok, allowed = pcall(DFDeck.canOpen)
    return ok and allowed == true
end

local function onClick()
    if not mayOpen() then return end
    if DFDeck.toggle then DFDeck.toggle() end
end

if not DFDeckBtnState.wrapped then
    DFDeckBtnState.wrapped = true

    local _origInitialise = ISEquippedItem.initialise
    function ISEquippedItem:initialise()
        _origInitialise(self)
        if not self.adminBtn then return end

        if self.dfDeckBtn then
            pcall(function() self:removeChild(self.dfDeckBtn) end)
            self.dfDeckBtn = nil
        end

        local w = self.adminBtn:getWidth()
        local h = self.adminBtn:getHeight()
        local icon = resolveIcon(w)
        self.dfDeckIcon = icon

        local btn = ISButton:new(self.adminBtn:getX(), self.adminBtn:getBottom() + SPACING,
                                 w, h, icon and "" or "DECK", self, onClick)
        btn.internal = "DFDECK"
        btn:initialise()
        btn:instantiate()
        btn:ignoreWidthChange()
        btn:ignoreHeightChange()

        if icon then
            btn:setImage(icon.red)
            btn:setDisplayBackground(false)
            btn.borderColor = { r = 1, g = 1, b = 1, a = 0.1 }
        else
            btn:setDisplayBackground(true)
            btn.backgroundColor          = { r = 0.03, g = 0.04, b = 0.03, a = 0.85 }
            btn.backgroundColorMouseOver = { r = 0.09, g = 0.13, b = 0.09, a = 0.95 }
            btn.borderColor              = { r = 0.56, g = 0.89, b = 0.20, a = 0.60 }
        end

        btn:setTooltip("Dragonfly Deck (incubating)")
        self:addChild(btn)
        self.dfDeckBtn = btn
        self:shrinkWrap()
    end

    local _origPrerender = ISEquippedItem.prerender
    function ISEquippedItem:prerender()
        _origPrerender(self)   -- old Dragonfly's badge (if present) anchors in here

        local btn = self.dfDeckBtn
        if not btn then return end

        local allowed = mayOpen()
        btn:setVisible(allowed)
        if not allowed then return end

        -- Beneath the old badge when it is up; beneath the vanilla trio when
        -- the deck stands alone.
        local bottom = nil
        if self.dfPanelBtn and self.dfPanelBtn:isVisible() then
            bottom = self.dfPanelBtn:getBottom()
        else
            for _, ref in ipairs({ self.clientBtn, self.adminBtn, self.warManagerBtn }) do
                if ref and ref:isVisible() then
                    local b = ref:getBottom()
                    if not bottom or b > bottom then bottom = b end
                end
            end
        end
        if not bottom then
            btn:setVisible(false)
            return
        end

        local targetY = bottom + SPACING
        if btn:getY() ~= targetY then btn:setY(targetY) end

        local icon = self.dfDeckIcon
        if icon then
            -- The inversion: red = closed, green = open.
            btn:setImage(deckOpen() and icon.green or icon.red)
        end

        if btn:getBottom() > self:getHeight() then
            self:setHeight(btn:getBottom())
        end
    end
end

return DFDeckButton

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
