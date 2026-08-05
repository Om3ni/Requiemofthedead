-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSideButton.lua - a Dragonfly badge in the vanilla left-hand sidebar,
-- directly beneath CLIENT and ADMIN.
--
-- WHY PATCH ISEquippedItem: that class owns the whole left column. Vanilla builds
-- it in ISEquippedItem:initialise() as a vertical run of icon buttons - inventory,
-- health, crafting, build, movable, search, zone, map, debug, safety, then
-- clientBtn ("USERPANEL"), adminBtn ("ADMINPANEL"), warManagerBtn
-- ("WARMANAGERPANEL"). There is no registry or hook for adding one, so appending a
-- child is the only route. Two wraps, both call the original first:
--
--   initialise() - create the button. Vanilla's own last act is shrinkWrap()
--                  (ISEquippedItem.lua:969), which sizes the panel to the
--                  bottom-most ISButton child. We add ours and call it AGAIN, or
--                  the panel stays too short and our button is drawn but not
--                  clickable - the parent's bounds are what receive the mouse.
--   prerender()  - position, visibility and on/off state. This CANNOT be done
--                  once at creation: vanilla re-lays-out every frame in prerender
--                  (warManagerBtn is moved to adminBtn:getBottom(), and adminBtn
--                  is hidden outright for non-admins), so a fixed Y drifts or
--                  collides the moment either changes.
--
-- We deliberately do NOT patch ISEquippedItem:onOptionMouseDown. That function
-- dispatches on button.internal with an if/elseif chain over vanilla's own names;
-- adding a branch means owning a copy of that chain forever. ISButton takes its
-- own target+callback, so ours routes straight to DFPanel.toggle and vanilla's
-- dispatcher never sees it.
--
-- ANCHORING: not "below adminBtn". The bottom of the column moves - adminBtn is
-- hidden without the admin tool, and warManagerBtn only appears when a war is
-- nearby (and then steals adminBtn's Y when admin is hidden). So each frame we
-- take the bottom-most VISIBLE button of the three and sit under that. Anchoring
-- on adminBtn alone would overlap warManagerBtn on a war server and float in dead
-- space for a non-admin.
--
-- SIZING is read from adminBtn rather than hardcoded, because the icon metrics are
-- resolution-dependent: vanilla's TEXTURE_WIDTH is 48/64/80/96/128 by sidebar-size
-- option with height = width * 0.75, and both are FILE-LOCAL to ISEquippedItem, so
-- they cannot be read from here. Copying the numbers would silently mismatch the
-- moment a player changes the sidebar size option (which re-runs initialise via
-- prerender's checkSidebarSizeOption).
--
-- ICON: optional, and currently absent - Dragonfly ships no UI texture. If one of
-- the paths in ICON_CANDIDATES resolves we use the vanilla icon idiom
-- (transparent background, image only, matching CLIENT/ADMIN). If not, we fall
-- back to a bordered text badge so the feature WORKS TODAY and upgrades silently
-- when art lands. Drop a square PNG (128x128 covers every sidebar size; PZ scales
-- down) at Dragonfly/42/media/ui/DF_Panel.png and it takes over with no code
-- change. A second "_on" file is picked up automatically for the open state.
--
-- ACCESS: gated on DFPanel.canOpen(), the same sandbox policy
-- (RFTDDragonfly.PanelAccess, Admin-only default, fails closed) that DFPanel.open
-- enforces. The button is HIDDEN, not disabled, for anyone who fails it - matching
-- DFPanel.open's "silent return so the panel's existence isn't advertised".

if not ISEquippedItem then return end

DFSideButton = DFSideButton or {}

local SPACING = 10   -- vanilla's UI_BORDER_SPACING; file-local there, so re-stated

-- Two supported art layouts, best first:
--
--  1. PER-SIZE SET, mirroring vanilla's scheme in OUR OWN folder:
--       media/ui/DFSidebar/<W>/DF_Panel_Off_<W>.png  (+ _On_ for the open state)
--     where W is the sidebar bucket - 48, 64, 80, 96 or 128, SQUARE. Vanilla does
--     exactly this (Client_Icon_Off_128.png is 128x128 under media/ui/Sidebar/128/),
--     so a matching set is pixel-sharp at every setting. Deliberately NOT dropped
--     into vanilla's own media/ui/Sidebar/ - keeping our files in a Dragonfly-owned
--     directory means we can never shadow or be confused with the engine's set.
--
--  2. SINGLE FILE fallback: media/ui/DF_Panel.png (+ DF_Panel_on.png). One
--     128x128 is plenty - ISButton scales down aspect-correctly.
--
-- Square art in a 4:3 button is CORRECT and not a mistake: the button is
-- W x (W*0.75), and ISButton's image branch uses drawTextureScaledAspect, which
-- fits the art inside those bounds without distorting it. Vanilla's own square
-- badges take the identical path, so ours sit exactly like CLIENT and ADMIN.
--
-- Resolution is cached PER BUCKET, not once globally: changing the sidebar size
-- option re-runs initialise(), and a single global cache would pin the first
-- bucket's texture forever and render blurry at every other size.

local SIZE_BUCKETS = { 48, 64, 80, 96, 128 }

local iconCache = {}   -- bucket -> { off = tex, on = tex } (or false when no art)

local function tex(path)
    local t
    -- getTexture on a missing path can throw OR return nil depending on build,
    -- so both outcomes have to be treated as "not found".
    pcall(function() t = getTexture(path) end)
    return t
end

-- Snap the button's real width to the nearest vanilla bucket. Read from the live
-- button rather than assumed, because TEXTURE_WIDTH is file-local to
-- ISEquippedItem and unreadable from here.
local function bucketFor(width)
    local best, bestDiff = SIZE_BUCKETS[#SIZE_BUCKETS], nil
    for _, b in ipairs(SIZE_BUCKETS) do
        local d = math.abs(b - (width or 0))
        if not bestDiff or d < bestDiff then best, bestDiff = b, d end
    end
    return best
end

local function resolveIcon(width)
    local b = bucketFor(width)
    local hit = iconCache[b]
    if hit ~= nil then return hit or nil end

    local off = tex("media/ui/DFSidebar/" .. b .. "/DF_Panel_Off_" .. b .. ".png")
    local on  = off and tex("media/ui/DFSidebar/" .. b .. "/DF_Panel_On_" .. b .. ".png") or nil

    if not off then
        off = tex("media/ui/DF_Panel.png")
        on  = off and tex("media/ui/DF_Panel_on.png") or nil
    end

    if not off then
        iconCache[b] = false   -- cached miss: don't re-probe the filesystem every resize
        return nil
    end

    iconCache[b] = { off = off, on = on or off }
    return iconCache[b]
end

local function panelOpen()
    return DFPanel ~= nil and DFPanel.instance ~= nil
       and DFPanel.instance.getIsVisible ~= nil and DFPanel.instance:getIsVisible()
end

local function mayOpen()
    -- Runtime lookup, never file scope: DFPanel and RDAccess are other files'
    -- globals and the client walks lua tiers alphabetically across every mod.
    if not DFPanel or not DFPanel.canOpen then return false end
    local s = SandboxVars.RFTDDragonfly or {}
    if s.Enabled == false then return false end
    local ok, allowed = pcall(DFPanel.canOpen)
    return ok and allowed == true
end

local function onClick()
    if not mayOpen() then return end
    if DFPanel.toggle then DFPanel.toggle() end
end

-- ---------------------------------------------------------------------------
-- initialise: build the button
-- ---------------------------------------------------------------------------

local _origInitialise = ISEquippedItem.initialise
function ISEquippedItem:initialise()
    _origInitialise(self)

    -- adminBtn is our size reference AND our proof the sidebar actually built its
    -- multiplayer section. In single player these buttons do not exist, and a
    -- Dragonfly badge would be pointless there anyway.
    if not self.adminBtn then return end

    -- initialise() re-runs when the sidebar size option changes, and vanilla makes
    -- fresh buttons each time. Drop the previous one or the panel accumulates a
    -- stale badge per resize, each still a shrinkWrap candidate.
    if self.dfPanelBtn then
        pcall(function() self:removeChild(self.dfPanelBtn) end)
        self.dfPanelBtn = nil
    end

    local w = self.adminBtn:getWidth()
    local h = self.adminBtn:getHeight()

    -- Per-instance, because the bucket follows this sidebar's current size.
    local icon = resolveIcon(w)
    self.dfPanelIcon = icon

    local btn = ISButton:new(self.adminBtn:getX(), self.adminBtn:getBottom() + SPACING,
                             w, h, icon and "" or "DF", self, onClick)
    btn.internal = "DFPANEL"   -- descriptive only; vanilla's dispatcher never sees it
    btn:initialise()
    btn:instantiate()
    btn:ignoreWidthChange()
    btn:ignoreHeightChange()

    if icon then
        -- Vanilla icon idiom: no chrome, the texture is the whole button.
        btn:setImage(icon.off)
        btn:setDisplayBackground(false)
        btn.borderColor = { r = 1, g = 1, b = 1, a = 0.1 }
    else
        -- No art yet: a bordered badge, so it is visibly a button rather than an
        -- invisible click target. Dragonfly green-ish to read as ours.
        btn:setDisplayBackground(true)
        btn.backgroundColor       = { r = 0.10, g = 0.16, b = 0.10, a = 0.85 }
        btn.backgroundColorMouseOver = { r = 0.18, g = 0.30, b = 0.18, a = 0.95 }
        btn.borderColor           = { r = 0.45, g = 0.75, b = 0.45, a = 0.60 }
    end

    btn:setTooltip("Dragonfly Panel")
    self:addChild(btn)
    self.dfPanelBtn = btn

    -- Re-run vanilla's own sizing now that a lower child exists, or the parent's
    -- bounds stop short of the badge and the click never lands.
    self:shrinkWrap()
end

-- ---------------------------------------------------------------------------
-- prerender: follow the column, reflect state
-- ---------------------------------------------------------------------------

local _origPrerender = ISEquippedItem.prerender
function ISEquippedItem:prerender()
    _origPrerender(self)   -- FIRST: vanilla moves warManagerBtn and hides adminBtn in here

    local btn = self.dfPanelBtn
    if not btn then return end

    local allowed = mayOpen()
    btn:setVisible(allowed)
    if not allowed then return end

    -- Bottom-most VISIBLE button of the multiplayer trio - see ANCHORING above.
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

    local icon = self.dfPanelIcon
    if icon then
        btn:setImage(panelOpen() and icon.on or icon.off)
    end

    -- Grow only. shrinkWrap already covered the common case; this catches the
    -- frames where the anchor moved down (war timer appearing) and the parent
    -- would otherwise clip our new bottom. Never shrink here - that would fight
    -- vanilla's own sizing every frame.
    if btn:getBottom() > self:getHeight() then
        self:setHeight(btn:getBottom())
    end
end

return DFSideButton

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
