-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFDeckButton.lua - the deck's badge in the vanilla left sidebar, directly
-- beneath CLIENT and ADMIN (client only).
--
-- GRADUATED 2026-08-13: DFPanel and its DFSideButton retired, and this badge
-- took over their art, their anchor slot, and the family's honest color
-- reading - GREEN mark when the deck is CLOSED, RED when it is OPEN. (During
-- incubation it wore those backward so the two admin badges could be told
-- apart at a glance; with one admin door there is nothing left to confuse.)
-- The wrap documentation below is inherited from DFSideButton's header,
-- because this file is now the canonical patch on the sidebar.
--
-- WHY PATCH ISEquippedItem: that class owns the whole left column. Vanilla
-- builds it in initialise() as a vertical run of icon buttons ending in
-- clientBtn ("USERPANEL"), adminBtn ("ADMINPANEL"), warManagerBtn
-- ("WARMANAGERPANEL"). There is no registry or hook for adding one, so
-- appending a child is the only route. Two wraps, both call the original
-- first:
--
--   initialise() - create the button. Vanilla's own last act is shrinkWrap()
--                  (ISEquippedItem.lua:969), which sizes the panel to the
--                  bottom-most ISButton child. We add ours and call it AGAIN,
--                  or the panel stays too short and our button is drawn but
--                  not clickable - the parent's bounds receive the mouse.
--   prerender()  - position, visibility and on/off state. This CANNOT be
--                  done once at creation: vanilla re-lays-out every frame
--                  (warManagerBtn moves to adminBtn's Y, adminBtn is hidden
--                  outright for non-admins), so a fixed Y drifts or collides
--                  the moment either changes.
--
-- We deliberately do NOT patch onOptionMouseDown: it dispatches on
-- button.internal with an if/elseif chain over vanilla's names, and adding a
-- branch means owning a copy of that chain forever. ISButton takes its own
-- target+callback, so ours routes straight to DFDeck.toggle.
--
-- ANCHORING: not "below adminBtn" - the bottom of the column moves (adminBtn
-- hidden for non-admins, warManagerBtn only in war events), so each frame we
-- sit under the bottom-most VISIBLE of the three.
--
-- SIZING is read from adminBtn rather than hardcoded: vanilla's
-- TEXTURE_WIDTH is 48/64/80/96/128 by sidebar-size option, height = width *
-- 0.75, and both are file-local to ISEquippedItem. Copying the numbers would
-- silently mismatch the moment a player changes the sidebar size option
-- (which re-runs initialise via prerender's checkSidebarSizeOption).
--
-- RELOAD-SAFE like the rest of the deck: the wraps install once behind a
-- surviving sentinel - re-running this file must never stack a second wrap
-- chain onto ISEquippedItem (every stacked wrap is another full pass per
-- frame, forever).
--
-- ACCESS: hidden, not disabled, for anyone who fails DFDeck.canOpen - the
-- deck's existence is not advertised to non-staff.
--
-- THE ALERT CYCLE (2026-08-08). When RDTripwire observes an impossibility -
-- a privileged client command from an account with no staff capability - the
-- badge cycles red -> blue -> green until somebody opens the deck.
--
-- It uses THREE PLATES THAT ALREADY EXIST rather than new art: the admin badge's
-- own On (red) and Off (green), plus the player panel's Off (blue). All three
-- ship in every size bucket, so the cycle is correct at 48 through 128 with no
-- new files to keep in step. If the blue plate is ever missing the cycle
-- degrades to red/green - still plainly an alarm, never a broken icon.
--
-- STICKY, NOT TIMED, and acknowledged only by OPENING THE DECK. An impossibility
-- that happened while nobody was at the keyboard is precisely the one worth
-- surfacing, so a flash that expires on its own would drop the case it exists to
-- carry. Clicking the badge opens the deck, so the click acknowledges as a side
-- effect of the thing that actually matters: somebody looked.
--
-- ONLY the server-observed tier flashes. Client-reported tripwires go to the
-- console and stop there - see RDTripwire's header on why the tiers are kept
-- apart, and why an alert that cries wolf is worse than none.

if isServer() then return end
if not ISEquippedItem then return end

require "DFDeck"

DFDeckButton = DFDeckButton or {}

DFDeckBtnState = DFDeckBtnState or { wrapped = false }

local SPACING = 10
local SIZE_BUCKETS = { 48, 64, 80, 96, 128 }

-- Dwell per plate in the alert cycle. Slow enough to read as deliberate rather
-- than as a rendering fault, fast enough to catch peripheral vision.
local ALERT_FRAME_MS = 400

local iconCache = {}   -- bucket -> { off = tex, on = tex, alert = tex } | false

local function tex(path)
    -- the getTexture GLOBAL is self-catching (LuaManager:6855 ->
    -- Texture.getSharedTexture:406, try/catch returning null), so a missing
    -- file is a nil here, never a throw
    return getTexture(path)
end

local function bucketFor(width)
    local best, bestDiff = SIZE_BUCKETS[#SIZE_BUCKETS], nil
    for _, b in ipairs(SIZE_BUCKETS) do
        local d = math.abs(b - (width or 0))
        if not bestDiff or d < bestDiff then best, bestDiff = b, d end
    end
    return best
end

-- Worn honestly since graduation: Off art (green) closed, On art (red) open.
--
-- `alert` is the PLAYER panel's Off plate, which is the family's tide blue. It is
-- borrowed purely as a colour frame for the alert cycle and never as a state -
-- the admin badge has no blue state of its own, and inventing one would confuse
-- the two doors the graduation note above was written to stop confusing. Its
-- absence is tolerated: the cycle drops to two plates rather than failing.
local function resolveIcon(width)
    local b = bucketFor(width)
    local hit = iconCache[b]
    if hit ~= nil then return hit or nil end

    local off = tex("media/ui/DFSidebar/" .. b .. "/DF_Panel_Off_" .. b .. ".png")
    local on  = off and tex("media/ui/DFSidebar/" .. b .. "/DF_Panel_On_" .. b .. ".png") or nil

    if not off or not on then
        iconCache[b] = false
        return nil
    end
    local alert = tex("media/ui/DFSidebar/" .. b .. "/DF_PlayerPanel_Off_" .. b .. ".png")
    iconCache[b] = { off = off, on = on, alert = alert }
    return iconCache[b]
end

-- Is there an unacknowledged server-observed impossibility? Guarded rather than
-- assumed: DFTripwire is Core's and this file is Dragonfly's, so it may legitimately
-- be absent and the badge must simply behave as it always did.
local function alerting()
    if not DFTripwire or not DFTripwire.alertActive then return false end
    local ok, v = pcall(DFTripwire.alertActive)
    return ok and v == true
end

-- Which plate the alert cycle is showing this frame. Red, then blue, then green,
-- then round again - derived from the wall clock rather than counted, so it
-- cannot drift with frame rate and needs no state.
local function alertPlate(icon)
    local ms = getTimestampMs()   -- System.currentTimeMillis (LuaManager:7470)

    local frames = { icon.on, icon.alert, icon.off }
    if not icon.alert then frames = { icon.on, icon.off } end

    local i = (math.floor(ms / ALERT_FRAME_MS) % #frames) + 1
    return frames[i] or icon.off
end

local function deckOpen()
    return DFDeckState ~= nil and DFDeckState.instance ~= nil
       and DFDeckState.instance.getIsVisible ~= nil and DFDeckState.instance:getIsVisible()
end

local function mayOpen()
    if not DFDeck or not DFDeck.canOpen then return false end
    local s = SandboxVars.RFTDDragonfly or {}
    if s.Enabled == false then return false end
    -- canOpen chains into Core's RDAccess (foreign mod): a missing or
    -- mismatched Core must not break every sidebar prerender
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
            -- vanilla ISUI Lua (removeChild); a stale button from a previous
            -- initialise must not kill the sidebar rebuild
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
            btn:setImage(icon.off)
            btn:setDisplayBackground(false)
            btn.borderColor = { r = 1, g = 1, b = 1, a = 0.1 }
        else
            btn:setDisplayBackground(true)
            btn.backgroundColor          = { r = 0.03, g = 0.04, b = 0.03, a = 0.85 }
            btn.backgroundColorMouseOver = { r = 0.09, g = 0.13, b = 0.09, a = 0.95 }
            btn.borderColor              = { r = 0.56, g = 0.89, b = 0.20, a = 0.60 }
        end

        btn:setTooltip("Dragonfly Admin Deck")
        self:addChild(btn)
        self.dfDeckBtn = btn
        self:shrinkWrap()
    end

    local _origPrerender = ISEquippedItem.prerender
    function ISEquippedItem:prerender()
        _origPrerender(self)

        local btn = self.dfDeckBtn
        if not btn then return end

        local allowed = mayOpen()
        btn:setVisible(allowed)
        if not allowed then return end

        -- Beneath the bottom-most visible of the vanilla trio.
        local bottom = nil
        for _, ref in ipairs({ self.clientBtn, self.adminBtn, self.warManagerBtn }) do
            if ref and ref:isVisible() then
                local b = ref:getBottom()
                if not bottom or b > bottom then bottom = b end
            end
        end
        if not bottom then
            btn:setVisible(false)
            return
        end

        local targetY = bottom + SPACING
        if btn:getY() ~= targetY then btn:setY(targetY) end

        -- Acknowledgement is a side effect of the deck being open, so it works
        -- however the deck was opened - badge, keybind, or anything added later.
        -- Idempotent, because this runs every frame the deck is visible.
        local open = deckOpen()
        if open and DFTripwire and DFTripwire.acknowledge then
            -- Core's tripwire (foreign mod): contained so it cannot take the
            -- sidebar prerender down with it
            pcall(DFTripwire.acknowledge)
        end

        local icon = self.dfDeckIcon
        if icon then
            if (not open) and alerting() then
                btn:setImage(alertPlate(icon))
            else
                btn:setImage(open and icon.on or icon.off)
            end
        end

        -- The tooltip carries the count, because the cycle says "something" and
        -- an operator deciding whether to stop what they are doing wants "how
        -- much". Only touched when the answer changes: setTooltip on every frame
        -- is a string build per frame, forever.
        local want
        if (not open) and alerting() then
            local n = 0
            -- Core's tripwire (foreign mod): a count that throws reads as 0
            pcall(function() n = DFTripwire.pendingCount() or 0 end)
            want = "Dragonfly Admin Deck  -  " .. tostring(n)
                .. " unreviewed tripwire" .. ((n == 1) and "" or "s")
        else
            want = "Dragonfly Admin Deck"
        end
        if btn.tooltip ~= want then btn:setTooltip(want) end

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
