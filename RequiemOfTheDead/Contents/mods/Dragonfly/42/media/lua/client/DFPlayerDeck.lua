-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFPlayerDeck.lua - the player panel: the deck's ungated sibling (client only).
--
-- WHAT THIS IS. The family rule (owner, 2026-08-08): player-facing config
-- lives IN the game, where players already are - not on the ESC options
-- screen. This is that surface. Architecturally it is a deck - same Growl
-- chrome vocabulary, same hot-reload discipline, same build contract for
-- tenants - but its door is open to EVERY player, its accent is tide blue
-- rather than sight green (so the two surfaces can never be mistaken), and
-- its tenants come from DFPlayerRegistry, never DFRegistry. Two registries
-- exist precisely so a staff tool cannot leak onto this panel by a missing
-- filter (see DFPlayerRegistry's header).
--
-- TWO TENANT CLASSES, rendered differently:
--   SETTINGS  the built-in first tab: one flat DFForm over every
--             registerPlayerSettings{} sheet, grouped by mod. No tenant UI
--             code exists for these rows anywhere.
--   OWN TABS  registerPlayerTab{} specs build into the content pane exactly
--             as admin tabs build into the deck: spec.build(spec, panel, 0,
--             0, w, h), optional spec.resize for live reflow, disabled=true
--             for a reserved slot.
--
-- CHROME: titlebar (mark, DRAGONFLY, status, X) over a HORIZONTAL tab strip,
-- not the admin deck's left roster - the player panel expects a handful of
-- tabs, not a staff toolbox, and the owner's design sketch called for a tab
-- strip. Content pane below. One sweep on open, the watch pulse, 120ms
-- acquisitions; nothing else moves (rule 4, in force here too).
--
-- NOT GATED. No RDAccess tier, no sandbox switch, no capability checks: an
-- ungated surface is the entire point. The only doors are the sidebar badge
-- (DFPlayerButton - blue closed / red open, the owner's scheme for this
-- surface) - there is deliberately no keybind yet; picking a key that
-- collides with someone's muscle memory is an owner decision, and the badge
-- covers the MP servers this suite ships on.
--
-- PRESENTATION ONLY, the standing order of every deck file (the mod around
-- them carries the classic panel's tabs and tools, but the deck chassis
-- never does): no tenant logic, no domain knowledge, no wire traffic. Mods
-- own their settings stores; this panel is the glass they present through.
--
-- HOT-RELOAD SAFE like DFDeck: everything that must survive reloadLuaFile
-- lives in DFPlayerDeckState; listeners register once and dereference the
-- global at call time. Edit -> reload -> toggle twice via the badge.

if isServer() then return end

require "ISUI/ISPanel"
require "DFKit"
require "DFForm"
require "DFPlayerRegistry"
require "DFTheme"

DFPlayerDeck = ISPanel:derive("DFPlayerDeck")

-- Reload-surviving state; never a field on the class global (it dies with
-- every reload, taking the only reference to an open window with it).
DFPlayerDeckState = DFPlayerDeckState or { instance = nil }

local C = DFTheme.col

local TITLE_H = 40
local TAB_H   = 30
local PAD     = 8
local SWEEP_MS    = 1800
local SWEEP_EVERY = 15000  -- the panel breathes; it does not strobe
local BEAT    = 30         -- frames between status refreshes

local GRIP  = 18
-- Smaller floor than the admin deck's 820x460: no fixed-width roster to
-- clear, and the sheet is a single column that stays usable narrow.
local MIN_W = 520
local MIN_H = 380
-- The settings sheet's own footprint - also the panel's opening size, since
-- SETTINGS is where a fresh panel lands.
local DEF_W = 700
local DEF_H = 540
-- One line PER TAB now ("<key> w=%d h=%d") - a single remembered size was
-- the first smoke test's headline flaw: the sheet's modest window and the My
-- Vehicles inspector's wide one are different rooms, and one number forced
-- every visit to open in the wrong one.
local LAYOUT_FILE = "DFPlayerDeck_layout.txt"

-- The built-in first tab's id. The \1 prefix keeps it out of any namespace a
-- registering mod could plausibly pick.
local SETTINGS_ID = "\1settings"

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function DFPlayerDeck:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.background    = false
    o.moveWithMouse = false   -- drag is titlebar-only
    o.tabs          = {}      -- { id, spec|nil, label, x, w, enabled, hoverT }
    o.activeId      = nil
    o.hoverTab      = nil     -- index | "close"
    o.contentArea   = nil
    o.form          = nil     -- live DFForm while the settings tab is up
    o.clockMs       = 0
    o.sweepMs       = 0
    o.beat          = 0
    o.statusText    = ""
    o.dragging      = false
    o.dragDX, o.dragDY = 0, 0
    o.resizing      = false
    o.resizeDX, o.resizeDY = 0, 0
    return o
end

function DFPlayerDeck:createChildren()
    self:rebuild()
end

-- Strip geometry is cached here because it depends on the label widths, and
-- those depend on the font tier - both of which change only at rebuild time
-- (registration happens at boot; the tier change listener below rebuilds).
function DFPlayerDeck:rebuild()
    self.tabs = {}
    self.tabs[1] = { id = SETTINGS_ID, spec = nil, label = "SETTINGS", enabled = true, hoverT = 0 }
    local specs = DFPlayerRegistry.getTabs()
    for i = 1, #specs do
        local spec = specs[i]
        self.tabs[#self.tabs + 1] = {
            id      = spec.id,
            spec    = spec,
            label   = string.upper(tostring(spec.label or spec.id)),
            enabled = DFPlayerRegistry.isSelectable(spec),
            hoverT  = 0,
        }
    end

    local x = PAD + 4
    for i = 1, #self.tabs do
        local t = self.tabs[i]
        t.x = x
        t.w = DFTheme.strW(DFTheme.font.label, t.label) + 28
        x = x + t.w
    end

    -- Settings always exists and is always selectable, so unlike the admin
    -- deck there is no empty state and no disabled-landing hazard - but a
    -- remembered activeId may name a tab whose mod was removed.
    local landing = self.activeId
    local known = false
    for i = 1, #self.tabs do
        if self.tabs[i].id == landing and self.tabs[i].enabled then known = true end
    end
    self:showTab(known and landing or SETTINGS_ID)
end

function DFPlayerDeck:contentRect()
    local cx = PAD
    local cy = TITLE_H + TAB_H + PAD
    return cx, cy, self.width - cx - PAD, self.height - cy - PAD
end

-- ---------------------------------------------------------------------------
-- Resize - same shape as DFDeck's: cheap reflow per frame during the drag,
-- the expensive settle once on release.
-- ---------------------------------------------------------------------------

function DFPlayerDeck:reflowContent()
    if not self.contentArea then return true end
    local cx, cy, cw, ch = self:contentRect()
    self.contentArea:setX(cx); self.contentArea:setY(cy)
    self.contentArea:setWidth(cw); self.contentArea:setHeight(ch)

    if self.activeId == SETTINGS_ID then
        if self.form then self.form:layout(0, 0, cw, ch) end
        return true
    end
    local spec = DFPlayerRegistry.tabs[self.activeId or ""]
    if spec and type(spec.resize) == "function" then
        local ok, err = pcall(spec.resize, spec, self.contentArea, cw, ch)
        if ok then return true end
        print("[PlayerDeck] tab resize failed (" .. tostring(self.activeId) .. "): " .. tostring(err))
    end
    return false
end

function DFPlayerDeck:settleResize()
    -- Resync the font tier from the preference (see DFDeck.settleResize for
    -- the autopsy of why the tier must never follow the width).
    local pref = (DFPrefs and DFPrefs.get and DFPrefs.get("fontScale")) or 1
    local fontMoved = DFKit.setFontScale(pref)

    if fontMoved or not self:reflowContent() then
        self:rebuild()
    end
    -- Remembered PER TAB: a drag while My Vehicles is up is a statement about
    -- My Vehicles, and must not shrink the sheet or stretch the Workshop.
    self.sizes = self.sizes or {}
    self.sizes[DFPlayerDeck.sizeKey(self.activeId or SETTINGS_ID)] =
        { w = self.width, h = self.height }
    DFPlayerDeck.saveSizes(self.sizes)
end

-- ---------------------------------------------------------------------------
-- Per-tab sizing. Priority: the size the player last dragged THIS tab to,
-- else the spec's declared preference (prefW/prefH), else - for the built-in
-- sheet - the panel default; a tab declaring nothing keeps whatever size the
-- panel already has. Always clamped to the screen and the floor, and shifted
-- back on-screen when growth would push the grip off an edge.
-- ---------------------------------------------------------------------------

-- File keys must survive a "%S+" parse: the sheet's \1 sentinel and any
-- whitespace a mod put in a tab id are stripped, not written.
function DFPlayerDeck.sizeKey(id)
    return (tostring(id):gsub("[%c%s]", ""))
end

function DFPlayerDeck:applyTabSize(id)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local rec  = self.sizes and self.sizes[DFPlayerDeck.sizeKey(id)]
    local spec = DFPlayerRegistry.tabs[id]
    local w = (rec and rec.w) or (spec and spec.prefW)
    local h = (rec and rec.h) or (spec and spec.prefH)
    if id == SETTINGS_ID and not rec then w, h = DEF_W, DEF_H end
    if not w and not h then return end

    w = math.floor(math.min(w or self.width, sw - 40))
    h = math.floor(math.min(h or self.height, sh - 40))
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end
    if w == self.width and h == self.height then return end

    self:setWidth(w)
    self:setHeight(h)
    if self:getX() + w > sw then self:setX(math.max(0, sw - w)) end
    if self:getY() + h > sh then self:setY(math.max(0, sh - h)) end
end

function DFPlayerDeck:showTab(id)
    self:applyTabSize(id)   -- BEFORE contentRect is read: the size is the
                            -- tab's, not whatever the last tab left behind
    self.activeId = id
    self.builtTier = DFKit.fontScale   -- the tier these widgets BAKE; see the
                                       -- prefs listener at the bottom

    if self.contentArea then self:removeChild(self.contentArea) end
    self.form = nil
    local cx, cy, cw, ch = self:contentRect()
    self.contentArea = ISPanel:new(cx, cy, cw, ch)
    self.contentArea.background = false
    self.contentArea:initialise()
    self.contentArea:instantiate()
    self:addChild(self.contentArea)

    if id == SETTINGS_ID then
        -- Composed fresh on every visit: sheets register at boot, but their
        -- schema functions run NOW, so labels carry current translations and
        -- a hot-reloaded tenant's edits show on the next open.
        local binding = DFPlayerRegistry.sheetForm()
        local form = DFForm.new{
            schema = binding.schema,
            title  = "Setting",
            get    = binding.get,
            set    = binding.set,
        }
        form:attach(self.contentArea)
        form:layout(0, 0, cw, ch)
        self.form = form
        -- The form is drawn chrome, not widgets: the host's prerender is
        -- where it paints. Dereferenced through the deck instance so a
        -- rebuilt form is what draws, not the one this closure was born with.
        local deck = self
        self.contentArea.prerender = function(p)
            ISPanel.prerender(p)
            if deck.form then deck.form:draw(p) end
        end
        return
    end

    local spec = DFPlayerRegistry.tabs[id]
    if spec and type(spec.build) == "function" then
        local ok, err = pcall(spec.build, spec, self.contentArea, 0, 0, cw, ch)
        if not ok then
            print("[PlayerDeck] tab build failed (" .. tostring(id) .. "): " .. tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------------
-- The chrome
-- ---------------------------------------------------------------------------

function DFPlayerDeck:refreshBeat()
    local user = "?"
    pcall(function() user = getPlayer():getUsername() end)
    self.statusText = user
end

function DFPlayerDeck:prerender()
    local d  = DFTheme.delta()
    local ms = d * 33.3
    self.clockMs = self.clockMs + ms
    self.sweepMs = self.sweepMs + ms
    if self.sweepMs > SWEEP_MS + SWEEP_EVERY then self.sweepMs = 0 end
    self.beat = self.beat - 1
    if self.beat <= 0 then
        self.beat = BEAT
        self:refreshBeat()
    end

    local w, h = self.width, self.height
    local chromeH = TITLE_H + TAB_H

    -- frame: void ground, scar outline, murk chrome band - translucent to the
    -- same weights as the admin deck, driven by the same preference.
    local A = DFKit.alpha
    DFTheme.roundFrame(self, 0, 0, w, h, DFTheme.radius, A.window, C.scar, C.void)
    self:drawRect(1, 1, w - 2, chromeH - 1, A.chrome, C.murk.r, C.murk.g, C.murk.b)

    -- veil under the hairlines and type, exactly as the deck layers it
    DFTheme.roundRect(self, 1, 1, w - 2, h - 2, DFTheme.radius, A.veil, C.black)

    DFTheme.hairline(self, 1, TITLE_H, w - 2)
    DFTheme.hairline(self, 1, chromeH, w - 2)
    -- the wing, lying along the strip; tide, and quieter than the roster's
    DFTheme.vein(self, math.floor(w * 0.55), TITLE_H + 1, math.floor(w * 0.45) - 2, TAB_H - 1, 0.05, C.tide)

    -- the mark: ring, disc, D - in this surface's accent
    local mx, my, mr = 14, math.floor((TITLE_H - 26) / 2), 26
    DFTheme.roundRect(self, mx, my, mr, mr, mr / 2, 1, C.tideDim)
    DFTheme.roundRect(self, mx + 1, my + 1, mr - 2, mr - 2, (mr - 2) / 2, 1, C.black)
    DFTheme.textCentre(self, "D", mx + mr / 2, my + 5, DFTheme.font.label, C.tide)

    DFTheme.text(self, "DRAGONFLY", mx + mr + 12, 10, DFTheme.font.label, C.bone)
    DFTheme.text(self, "PLAYER PANEL", mx + mr + 108, 10, DFTheme.font.label, C.ash, 0.8)

    -- watch pulse + username, right side
    local pulse = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(self.clockMs / 4000 * 6.283))
    local sw = DFTheme.strW(DFTheme.font.label, self.statusText)
    self:drawRect(w - sw - 46, 17, 6, 6, pulse, C.tide.r, C.tide.g, C.tide.b)
    DFTheme.text(self, self.statusText, w - sw - 34, 10, DFTheme.font.label, C.ash)

    -- close: arms on hover
    local closeHot = self.hoverTab == "close"
    DFTheme.text(self, "X", w - 20, 10, DFTheme.font.label, closeHot and C.tide or C.ash)

    -- the strip
    local ty = TITLE_H
    for i = 1, #self.tabs do
        local t = self.tabs[i]
        local active = (t.id == self.activeId)
        t.hoverT = DFTheme.glide(t.hoverT, (self.hoverTab == i and t.enabled and not active) and 1 or 0, 0.25)

        if active then
            self:drawRect(t.x, ty + 1, t.w, TAB_H - 1, 0.5, C.hide.r, C.hide.g, C.hide.b)
            -- the rail lies on the strip's floor, underlining the label
            self:drawRect(t.x, ty + TAB_H - 2, t.w, 2, 1, C.tide.r, C.tide.g, C.tide.b)
            DFTheme.textCentre(self, t.label, t.x + t.w / 2, ty + 8, DFTheme.font.label, C.tide)
        elseif not t.enabled then
            DFTheme.textCentre(self, t.label, t.x + t.w / 2, ty + 8, DFTheme.font.label, C.scar)
        else
            if t.hoverT > 0.01 then
                self:drawRect(t.x, ty + 1, t.w, TAB_H - 1, 0.3 * t.hoverT, C.hideHi.r, C.hideHi.g, C.hideHi.b)
                self:drawRect(t.x, ty + TAB_H - 2, t.w, 2, t.hoverT, C.tideDim.r, C.tideDim.g, C.tideDim.b)
            end
            -- Enabled-at-rest is BONE, not ash. Ash labels read as "disabled"
            -- even to the owner (2026-08-08, twice) - and disabled already has
            -- scar. Rest slightly translucent so the active tab still owns the
            -- strip; hover lifts to full.
            self:drawTextCentre(t.label, t.x + t.w / 2, ty + 8,
                C.bone.r, C.bone.g, C.bone.b,
                0.7 + 0.3 * t.hoverT, DFTheme.font.label)
        end
    end

    -- grain over the chrome only
    DFTheme.grain(self, 1, 1, w - 2, chromeH - 1)

    -- the sweep: on open, then idling (rule 4)
    if self.sweepMs < SWEEP_MS then
        local t = self.sweepMs / SWEEP_MS
        local a = (t < 0.12) and (t / 0.12) * 0.5 or (1 - t) * 0.5
        self:drawRect(1, math.floor(t * (h - 2)), w - 2, 2, a, C.tide.r, C.tide.g, C.tide.b)
    end

    -- the grip, brightening while a resize is live
    local ga = self.resizing and 0.95 or 0.45
    for i = 1, 3 do
        local o = 4 + (i - 1) * 5
        self:drawRect(w - o - 6, h - 5, 6, 1, ga, C.tide.r, C.tide.g, C.tide.b)
        self:drawRect(w - 5, h - o - 6, 1, 6, ga, C.tide.r, C.tide.g, C.tide.b)
    end
end

-- ---------------------------------------------------------------------------
-- Mouse: strip hits, titlebar drag, close, grip. Content children see their
-- own events first; the panel only hears clicks on its bare chrome.
-- ---------------------------------------------------------------------------

local function tabAt(self, x, y)
    if y < TITLE_H or y >= TITLE_H + TAB_H then return nil end
    for i = 1, #self.tabs do
        local t = self.tabs[i]
        if x >= t.x and x < t.x + t.w then return i end
    end
    return nil
end

function DFPlayerDeck:onMouseMove(dx, dy)
    if self.resizing then self:applyResize(); return end
    local x, y = self:getMouseX(), self:getMouseY()
    if y < TITLE_H then
        self.hoverTab = (x > self.width - 28) and "close" or nil
    else
        self.hoverTab = tabAt(self, x, y)
    end
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFPlayerDeck:onMouseMoveOutside(dx, dy)
    if self.resizing then self:applyResize(); return end
    self.hoverTab = nil
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFPlayerDeck:onMouseDown(x, y)
    if y < TITLE_H then
        if x > self.width - 28 then
            DFPlayerDeck.close()
            return
        end
        self.dragging = true
        self.dragDX = getMouseX() - self:getX()
        self.dragDY = getMouseY() - self:getY()
        return
    end
    if x >= self.width - GRIP and y >= self.height - GRIP then
        self.resizing = true
        self.resizeDX = getMouseX() - self.width
        self.resizeDY = getMouseY() - self.height
        return
    end
    local i = tabAt(self, x, y)
    if i and self.tabs[i].enabled then
        self:showTab(self.tabs[i].id)
    end
end

function DFPlayerDeck:applyResize()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w = getMouseX() - self.resizeDX
    local h = getMouseY() - self.resizeDY
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end
    if w > sw - self:getX() then w = sw - self:getX() end
    if h > sh - self:getY() then h = sh - self:getY() end
    self:setWidth(math.floor(w))
    self:setHeight(math.floor(h))
    self:reflowContent()
end

local function endDrag(self)
    self.dragging = false
    if self.resizing then
        self.resizing = false
        self:settleResize()
    end
end

function DFPlayerDeck:onMouseUp(x, y)        endDrag(self) end
function DFPlayerDeck:onMouseUpOutside(x, y) endDrag(self) end

-- ---------------------------------------------------------------------------
-- Remembered sizes - client-local, one line per tab, failures non-fatal;
-- position is not saved (the panel centres on whatever screen it opens on).
-- The old single-line "w= h=" format simply fails the per-tab parse and is
-- forgotten - one default-sized open, then the file is rewritten new-style.
-- ---------------------------------------------------------------------------

function DFPlayerDeck.saveSizes(sizes)
    pcall(function()
        local f = getFileWriter(LAYOUT_FILE, true, false)
        if not f then return end
        for k, r in pairs(sizes or {}) do
            f:write(string.format("%s w=%d h=%d\n", k, math.floor(r.w), math.floor(r.h)))
        end
        f:close()
    end)
end

function DFPlayerDeck.loadSizes()
    local out = {}
    pcall(function()
        local r = getFileReader(LAYOUT_FILE, false)
        if not r then return end
        while true do
            local line = r:readLine()
            if not line then break end
            local k, w, h = line:match("^(%S+) w=(%d+) h=(%d+)")
            if k then out[k] = { w = tonumber(w), h = tonumber(h) } end
        end
        r:close()
    end)
    return out
end

-- ---------------------------------------------------------------------------
-- Open / close / toggle. No canOpen: this surface has no gate to fail.
-- ---------------------------------------------------------------------------

function DFPlayerDeck.open()
    if DFPlayerDeckState.instance then
        DFPlayerDeckState.instance:setVisible(true)
        DFPlayerDeckState.instance:addToUIManager()
        DFPlayerDeckState.instance.sweepMs = 0
        DFPlayerDeckState.instance:rebuild()
        return
    end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    -- Opens at the sheet's default; the landing tab's applyTabSize (inside
    -- the first showTab, before anything renders) immediately takes it to
    -- that tab's remembered or preferred size. Clamped so it can never open
    -- with its titlebar off-screen.
    local w = math.min(DEF_W, sw - 80)
    local h = math.min(DEF_H, sh - 80)
    if w < MIN_W then w = math.min(MIN_W, sw - 80) end
    if h < MIN_H then h = math.min(MIN_H, sh - 80) end

    -- Tier before first build, or every widget bakes the old font (see
    -- DFDeck.open).
    if DFPrefs and DFPrefs.get and DFKit.setFontScale then
        DFKit.setFontScale(DFPrefs.get("fontScale"))
    end
    local inst = DFPlayerDeck:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    inst.sizes = DFPlayerDeck.loadSizes()
    inst:initialise()
    inst:addToUIManager()
    inst:setVisible(true)
    DFPlayerDeckState.instance = inst
end

function DFPlayerDeck.close()
    if DFPlayerDeckState.instance then
        DFPlayerDeckState.instance:removeFromUIManager()
        DFPlayerDeckState.instance = nil
    end
    -- A sheet row's ? popout must not outlive the panel it explains.
    if DFHelp and DFHelp.close then DFHelp.close() end
end

function DFPlayerDeck.toggle()
    if DFPlayerDeckState.instance and DFPlayerDeckState.instance:getIsVisible() then
        DFPlayerDeck.close()
    else
        DFPlayerDeck.open()
    end
end

-- A text-size change while the panel is open: rebuild when the tier moved
-- past the one the widgets baked. Same reasoning and same trap as DFDeck's
-- listener (DFPrefs syncs the kit's tracker before it notifies, so asking
-- setFontScale from here always answers "no move"). The settings sheet is
-- where the text-size dial LIVES, so this fires while the panel is up nearly
-- every time it fires at all. Registered once across hot reloads.
if DFPrefs and DFPrefs.onChange and not DFPlayerDeckState.prefsHooked then
    DFPlayerDeckState.prefsHooked = true
    DFPrefs.onChange(function()
        local inst = DFPlayerDeckState.instance
        if not inst then return end
        local vis = false
        pcall(function() vis = inst:getIsVisible() end)
        if not vis then return end
        if inst.builtTier ~= DFKit.fontScale then
            inst:rebuild()
        end
    end)
end

-- Cross-tab navigation: a tab asks the REGISTRY to land somewhere
-- (Dragonfly.showPlayerTab), and the shell answers - opening itself first if
-- it has to. Only ids actually in the strip are honoured; a request for a
-- tab whose mod is absent dies quietly here rather than showing an empty
-- pane. Registered once across hot reloads, dereferencing globals at call
-- time, same discipline as every listener in this file.
if DFPlayerRegistry and DFPlayerRegistry.onShowRequest and not DFPlayerDeckState.showHooked then
    DFPlayerDeckState.showHooked = true
    DFPlayerRegistry.onShowRequest(function(id)
        if not DFPlayerDeck then return end
        local inst = DFPlayerDeckState.instance
        local vis = false
        if inst then pcall(function() vis = inst:getIsVisible() end) end
        if not vis then DFPlayerDeck.open() end
        inst = DFPlayerDeckState.instance
        if not inst then return end
        for i = 1, #inst.tabs do
            if inst.tabs[i].id == id and inst.tabs[i].enabled then
                inst:showTab(id)
                return
            end
        end
    end)
end

print("[PlayerDeck] DFPlayerDeck loaded (ungated - sidebar badge opens it)")

return DFPlayerDeck

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
