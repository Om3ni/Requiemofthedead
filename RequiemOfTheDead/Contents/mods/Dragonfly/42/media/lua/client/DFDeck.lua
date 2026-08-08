-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFDeck.lua - the deck: Growl-skinned admin shell (client only).
--
-- INCUBATION CONTRACT. This is the successor chassis to DFPanel, running
-- ALONGSIDE it while the skin matures - same mod since 2026-08-13, when the
-- planned RFTDDragonfly split was folded back in (the server runs ONE
-- Dragonfly; the RFTDDragonfly name lives on only as the sandbox namespace
-- and wire module this mod always used): same registry (DFRegistry, in
-- Core), same tab build contract - spec.build(spec, contentPanel, 0, 0, w, h)
-- - same access policy (RDAccess.meetsTier over RFTDDragonfly.PanelAccess,
-- the sandbox page this mod ships). Every
-- tab the family registers appears here, functional immediately; tabs keep
-- their stock look inside the new chrome until their Phase 4 migration. The
-- old panel opens on Shift+U as always; the deck opens from its own sidebar
-- badge beneath Dragonfly's (DFDeckButton - red closed / green open, the old
-- badge's inverse for the incubation) or Shift+Numpad9, so both panels can
-- be compared live on the same box. At the swap, the deck inherits the old
-- keybind and colors, and DFPanel retires. (Shift+I was considered and
-- rejected: I is the inventory key.)
--
-- PRESENTATION ONLY - the standing order of this whole mod: no tab logic, no
-- domain knowledge, no wire traffic lives here, ever. The deck knows the
-- game; the tools live in their own mods.
--
-- CHROME ANATOMY (all custom-drawn through DFTheme; zero stock widgets):
--   titlebar   the mark (disc + ring + D), DRAGONFLY, cached status line
--   roster     text-only page list down the left, wing venation behind it -
--              a roster, not a menu. Hover = 120ms acquisition (rail slides,
--              label lifts ash->bone). Active = sight rail + sight label.
--   content    an ISPanel child; tabs build into it exactly as before
--   motion     one sweep down the frame on open, the 4s watch pulse, the
--              acquisitions. Nothing else moves (rule 4).
--
-- Per-frame discipline: prerender allocates nothing and formats nothing -
-- status text rebuilds on a 30-frame cadence, roster labels are cached
-- uppercase at rebuild(), capability checks share the same 30-frame beat.
--
-- HOT-RELOAD SAFE, because skin iteration lives on it: reloadLuaFile
-- (LuaManager.java:3521) re-executes this file in place, which replaces the
-- DFDeck global wholesale. Everything that must SURVIVE that lives in
-- DFDeckState (window instance, keybind-hooked flag), and the key handler is
-- registered exactly once, dereferencing the DFDeck global at call time so
-- one registration always drives the newest code. The loop: edit -> reload
-- via the debug Lua window -> toggle twice, badge or Shift+Numpad9 (close
-- tears down the old-class window, open builds from the new). DFTheme reloads the same way; sprites
-- do not hot-swap (engine texture cache) - which is fine, sprites are shape
-- and shape is stable; color changes are DFTheme edits.

if isServer() then return end

require "ISUI/ISPanel"
require "DFKit"      -- the font tier the resize drives
require "DFTheme"

DFDeck = ISPanel:derive("DFDeck")

-- Reload-surviving state: never `DFDeck.instance` - the class global dies
-- with every reload, and a window referenced only from a dead global is a
-- window nobody can ever close.
DFDeckState = DFDeckState or { instance = nil, hooked = false }

local C = DFTheme.col

local TITLE_H  = 40
local ROSTER_W = 148
local ROW_H    = 30
local PAD      = 8
local SWEEP_MS    = 1800  -- duration of one sweep, top to bottom
local SWEEP_EVERY = 15000 -- rest between sweeps. The deck is a watch, not a
                          -- strobe: long enough that the sweep reads as the
                          -- panel breathing rather than as an animation.
local BEAT     = 30      -- frames between status/capability refreshes

-- Titlebar icon strip, measured from the right edge. GEAR_X is the wheel's
-- CENTRE; GEAR_COL is how much horizontal room it claims, which the status
-- line subtracts so the two can never overlap.
local GEAR_X   = 46
local GEAR_COL = 26

-- Resize grip, bottom-right. MIN is the smallest the deck may be dragged to:
-- the roster is a fixed 148 wide and every tab wants a usable pane beside it, so
-- below this the content area stops being a place anything can be laid out.
local GRIP    = 18
local MIN_W   = 820
local MIN_H   = 460
local LAYOUT_FILE = "DFDeck_layout.txt"

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function DFDeck:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.background    = false
    o.moveWithMouse = false   -- drag is titlebar-only, handled below
    o.rows          = {}      -- { id, spec, label, enabled, hoverT }
    o.activeId      = nil
    o.hoverRow      = nil
    o.contentArea   = nil
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

function DFDeck:createChildren()
    self:rebuild()
end

function DFDeck:rebuild()
    self.rows = {}
    local tabs = DFRegistry.getTabs()
    for i = 1, #tabs do
        local spec = tabs[i]
        self.rows[#self.rows + 1] = {
            id      = spec.id,
            spec    = spec,
            label   = string.upper(tostring(spec.label or spec.id)),
            -- Placeholder rows start disabled and refreshBeat leaves them so.
            -- The roster already renders !enabled in scar rather than ash and
            -- onMouseDown already refuses them, so reserving a slot costs
            -- nothing but this flag.
            enabled = DFRegistry.isSelectable(spec),
            hoverT  = 0,
        }
    end
    if #self.rows > 0 then
        -- Never land on a placeholder: the deck would show its empty content
        -- pane with no way to tell that apart from a tab that failed to build.
        local landing = self.activeId
        if not DFRegistry.isSelectable(DFRegistry.tabs[landing or ""]) then
            landing = DFRegistry.firstSelectable(tabs)
        end
        if landing then self:showTab(landing) end
    end
end

-- The content rect, in one place, because three things need it: the build, the
-- live reflow during a resize drag, and the rebuild after one.
function DFDeck:contentRect()
    local cx = ROSTER_W + PAD
    local cy = TITLE_H + PAD
    return cx, cy, self.width - cx - PAD, self.height - cy - PAD
end

-- ---------------------------------------------------------------------------
-- Resize
--
-- THE TAB `resize` HOOK EXISTS AND NOTHING WAS CALLING IT. DFRegistry has
-- accepted a `resize` on a tab spec since it was written, and Limes, Husbandry
-- and Reclamation all supply one - they were simply never invoked, by either
-- shell, because neither shell could change size. That hook is what makes a live
-- drag affordable: it re-lays-out in place, keeping list selection, scroll
-- position and any parsed state the tab is holding.
--
-- A tab WITHOUT one falls back to a full rebuild, and that is deferred to the
-- release. Rebuilding per frame would throw the tab away sixty times a second -
-- and with it, on the Zones tab, an unsaved draft.
-- ---------------------------------------------------------------------------

-- Returns true when the active tab laid itself out; false means it needs the
-- rebuild that settleResize() performs on release.
function DFDeck:reflowContent()
    if not self.contentArea then return true end
    local cx, cy, cw, ch = self:contentRect()
    self.contentArea:setX(cx); self.contentArea:setY(cy)
    self.contentArea:setWidth(cw); self.contentArea:setHeight(ch)

    local spec = DFRegistry.tabs[self.activeId or ""]
    if spec and type(spec.resize) == "function" then
        local ok, err = pcall(spec.resize, spec, self.contentArea, cw, ch)
        if ok then return true end
        print("[Deck] tab resize failed (" .. tostring(self.activeId) .. "): " .. tostring(err))
    end
    return false
end

function DFDeck:settleResize()
    -- Font tier follows the TEXT SIZE PREFERENCE (DFPrefs), never the width.
    -- The width heuristic predates the preference and the two fought over
    -- DFKit.font: dragging past 1500px silently overrode the size the user
    -- chose in the settings wheel, and the next DFPrefs.apply() put it back -
    -- WITHOUT the rebuild, because the kit's tier tracker had been bypassed -
    -- leaving glyphs one size and layout another. That mismatch is what "text
    -- distorts and falls out of place after a resize" was. The call here is a
    -- resync (normally a no-op); a genuinely stale tracker still earns the
    -- rebuild it needs, because a tier change re-bakes every label and button
    -- and only a rebuild can apply that.
    local pref = (DFPrefs and DFPrefs.get and DFPrefs.get("fontScale")) or 1
    local fontMoved = DFKit.setFontScale(pref)

    if fontMoved or not self:reflowContent() then
        if self.activeId then self:showTab(self.activeId) end
    end
    DFDeck.saveLayout(self.width, self.height)
end

function DFDeck:showTab(id)
    self.activeId = id
    -- The tier these widgets are about to BAKE. The prefs listener below
    -- compares this stamp against DFKit.fontScale to know a rebuild is owed -
    -- it cannot ask setFontScale, because DFPrefs.apply() syncs the tracker
    -- before it notifies, so from a listener the answer is always "no move".
    self.builtTier = DFKit.fontScale
    local spec = DFRegistry.tabs[id]
    if not spec then return end

    if self.contentArea then self:removeChild(self.contentArea) end
    local cx, cy, cw, ch = self:contentRect()
    self.contentArea = ISPanel:new(cx, cy, cw, ch)
    self.contentArea.background = false
    self.contentArea:initialise()
    self.contentArea:instantiate()
    self:addChild(self.contentArea)

    if type(spec.build) == "function" then
        local ok, err = pcall(spec.build, spec, self.contentArea, 0, 0, cw, ch)
        if not ok then
            print("[Deck] tab build failed (" .. tostring(id) .. "): " .. tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------------
-- The chrome
-- ---------------------------------------------------------------------------

local function rowTop(i)
    return TITLE_H + 10 + (i - 1) * ROW_H
end

function DFDeck:refreshBeat()
    -- status line: cached, rebuilt on the beat, never per frame
    local user = "?"
    pcall(function() user = getPlayer():getUsername() end)
    local limes = ""
    if Limes and Limes.revision and Limes.revision > 0 then
        limes = "zones " .. tostring(#Limes.zoneNames()) .. " · rev " .. tostring(Limes.revision) .. "   "
    end
    self.statusText = limes .. user

    -- capability greying, same beat (mirrors DFPanel's live prerender check)
    local p = getPlayer()
    for i = 1, #self.rows do
        local spec = self.rows[i].spec
        -- `disabled` is a property of the build and outranks the per-player
        -- capability check - without this the beat would re-enable a
        -- placeholder a third of a second after rebuild set it false.
        if not DFRegistry.isSelectable(spec) then
            self.rows[i].enabled = false
        else
            local cap = spec.capability
            self.rows[i].enabled = (cap == nil) or RDAccess.roleHas(p, cap)
        end
    end
end

function DFDeck:prerender()
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

    -- frame: void ground, scar outline, murk strips
    -- Translucent to the same weight as the classic panel: vanilla
    -- ISCollapsableWindow initialises backgroundColor a = 0.8, and DFPanel
    -- inherits it. The deck was drawing at a = 1, which read as a solid wall
    -- sitting next to a window you can see the world through.
    local A = DFKit.alpha
    DFTheme.roundFrame(self, 0, 0, w, h, DFTheme.radius, A.window, C.scar, C.void)
    self:drawRect(1, 1, w - 2, TITLE_H - 1, A.chrome, C.murk.r, C.murk.g, C.murk.b)
    self:drawRect(1, TITLE_H + 1, ROSTER_W - 1, h - TITLE_H - 2, A.chrome, C.murk.r, C.murk.g, C.murk.b)

    -- Veil: laid over the ground and chrome, UNDER the hairlines, vein, mark,
    -- type and roster rows - so it darkens the world showing through without
    -- dulling the content drawn on top of it. Both hairlines sit below it so
    -- they read at the same weight as each other.
    DFTheme.roundRect(self, 1, 1, w - 2, h - 2, DFTheme.radius, A.veil, C.black)

    DFTheme.hairline(self, 1, TITLE_H, w - 2)
    DFTheme.hairlineV(self, ROSTER_W, TITLE_H + 1, h - TITLE_H - 2)
    DFTheme.vein(self, 1, TITLE_H + 1, ROSTER_W - 1, math.min(560, h - TITLE_H - 2), 0.06)

    -- the mark: ring, disc, D
    local mx, my, mr = 14, math.floor((TITLE_H - 26) / 2), 26
    DFTheme.roundRect(self, mx, my, mr, mr, mr / 2, 1, C.sightDim)
    DFTheme.roundRect(self, mx + 1, my + 1, mr - 2, mr - 2, (mr - 2) / 2, 1, C.black)
    DFTheme.textCentre(self, "D", mx + mr / 2, my + 5, DFTheme.font.label, C.sight)

    DFTheme.text(self, "DRAGONFLY", mx + mr + 12, 10, DFTheme.font.label, C.bone)
    DFTheme.text(self, "ADMIN COMMAND DECK", mx + mr + 108, 10, DFTheme.font.label, C.ash, 0.8)

    -- watch pulse + status, right side. Shifted left by the gear's column so
    -- the status line cannot run underneath it - the wheel is fixed-width, the
    -- status text is not, so the text is what moves.
    local pulse = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(self.clockMs / 4000 * 6.283))
    local sw = DFTheme.strW(DFTheme.font.label, self.statusText)
    self:drawRect(w - sw - 46 - GEAR_COL, 17, 6, 6, pulse, C.sight.r, C.sight.g, C.sight.b)
    DFTheme.text(self, self.statusText, w - sw - 34 - GEAR_COL, 10, DFTheme.font.label, C.ash)

    -- settings wheel: drawn, not typed. PZ's bitmap fonts carry no gear
    -- glyph, and the deck's standing contract is custom-drawn chrome anyway -
    -- a hub with four teeth reads as a gear at this size and costs five rects.
    local gearHot = self.hoverRow == "gear"
    local gc = gearHot and C.sight or C.ash
    local gx, gy, gr = w - GEAR_X, math.floor(TITLE_H / 2), 5
    DFTheme.roundRect(self, gx - gr, gy - gr, gr * 2, gr * 2, gr, 1, gc)
    DFTheme.roundRect(self, gx - 2, gy - 2, 4, 4, 2, 1, C.murk)
    self:drawRect(gx - 1, gy - gr - 3, 2, 3, 1, gc.r, gc.g, gc.b)   -- N tooth
    self:drawRect(gx - 1, gy + gr,     2, 3, 1, gc.r, gc.g, gc.b)   -- S
    self:drawRect(gx - gr - 3, gy - 1, 3, 2, 1, gc.r, gc.g, gc.b)   -- W
    self:drawRect(gx + gr,     gy - 1, 3, 2, 1, gc.r, gc.g, gc.b)   -- E

    -- close: a scar X that arms on hover
    local closeHot = self.hoverRow == "close"
    DFTheme.text(self, "X", w - 20, 10, DFTheme.font.label, closeHot and C.sight or C.ash)

    -- roster rows
    for i = 1, #self.rows do
        local row = self.rows[i]
        local ry = rowTop(i)
        local active = (row.id == self.activeId)
        row.hoverT = DFTheme.glide(row.hoverT, (self.hoverRow == i and row.enabled) and 1 or 0, 0.25)

        if active then
            self:drawRect(1, ry, ROSTER_W - 1, ROW_H, 0.5, C.hide.r, C.hide.g, C.hide.b)
            self:drawRect(1, ry, 2, ROW_H, 1, C.sight.r, C.sight.g, C.sight.b)
            DFTheme.text(self, row.label, 18, ry + 7, DFTheme.font.label, C.sight)
        else
            if row.hoverT > 0.01 then
                self:drawRect(1, ry, ROSTER_W - 1, ROW_H, 0.3 * row.hoverT, C.hideHi.r, C.hideHi.g, C.hideHi.b)
                self:drawRect(1, ry, 2, ROW_H, row.hoverT, C.sightDim.r, C.sightDim.g, C.sightDim.b)
            end
            local base, lift = C.ash, row.hoverT
            if not row.enabled then
                self:drawText(row.label, 18, ry + 7, C.scar.r, C.scar.g, C.scar.b, 1, DFTheme.font.label)
            else
                self:drawText(row.label,
                    18, ry + 7,
                    base.r + (C.bone.r - base.r) * lift,
                    base.g + (C.bone.g - base.g) * lift,
                    base.b + (C.bone.b - base.b) * lift,
                    1, DFTheme.font.label)
            end
        end
    end

    if #self.rows == 0 then
        DFTheme.text(self, "No tabs registered - the roster fills as family mods load.",
            ROSTER_W + PAD * 2, TITLE_H + PAD * 2, DFTheme.font.body, C.ash)
    end

    -- grain over the chrome only; content stays crisp until tabs migrate
    DFTheme.grain(self, 1, 1, ROSTER_W - 1, h - 2)
    DFTheme.grain(self, 1, 1, w - 2, TITLE_H - 1)

    -- the sweep: on open, then idling every SWEEP_EVERY (rule 4)
    if self.sweepMs < SWEEP_MS then
        local t = self.sweepMs / SWEEP_MS
        local a = (t < 0.12) and (t / 0.12) * 0.5 or (1 - t) * 0.5
        self:drawRect(1, math.floor(t * (h - 2)), w - 2, 2, a, C.sight.r, C.sight.g, C.sight.b)
    end

    -- THE GRIP. Three tapering rules in the bottom-right corner - the universal
    -- shorthand for "drag me" - drawn in the chrome vocabulary rather than as a
    -- stock widget, because rule one of this file is that the deck owns its own
    -- chrome. It brightens while a resize is live so the corner acknowledges the
    -- grab even when the cursor has run off the edge of the panel.
    local ga = self.resizing and 0.95 or 0.45
    for i = 1, 3 do
        local o = 4 + (i - 1) * 5
        self:drawRect(w - o - 6, h - 5, 6, 1, ga, C.sight.r, C.sight.g, C.sight.b)
        self:drawRect(w - 5, h - o - 6, 1, 6, ga, C.sight.r, C.sight.g, C.sight.b)
    end
end

-- ---------------------------------------------------------------------------
-- Mouse: roster hits, titlebar drag, close. Content children see their own
-- events first; the deck only hears clicks on its bare chrome.
-- ---------------------------------------------------------------------------

local function rowAt(self, x, y)
    if x >= ROSTER_W then return nil end
    for i = 1, #self.rows do
        local ry = rowTop(i)
        if y >= ry and y < ry + ROW_H then return i end
    end
    return nil
end

function DFDeck:onMouseMove(dx, dy)
    if self.resizing then self:applyResize(); return end
    local x, y = self:getMouseX(), self:getMouseY()
    if y < TITLE_H then
        if x > self.width - 28 then
            self.hoverRow = "close"
        elseif x > self.width - GEAR_X - 10 and x < self.width - GEAR_X + 10 then
            self.hoverRow = "gear"
        else
            self.hoverRow = nil
        end
    else
        self.hoverRow = rowAt(self, x, y)
    end
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFDeck:onMouseMoveOutside(dx, dy)
    if self.resizing then self:applyResize(); return end
    self.hoverRow = nil
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFDeck:onMouseDown(x, y)
    if y < TITLE_H then
        if x > self.width - 28 then
            DFDeck.close()
            return
        end
        -- The wheel opens Core's settings window, not one of the deck's own.
        -- Presentation preferences belong to every tab in the family, so the
        -- deck's job here is to be a door, not to own the room.
        if x > self.width - GEAR_X - 10 and x < self.width - GEAR_X + 10 then
            if DFSettingsWindow then
                DFSettingsWindow.toggle(self:getAbsoluteX() + x, self:getAbsoluteY() + TITLE_H)
            end
            return
        end
        self.dragging = true
        self.dragDX = getMouseX() - self:getX()
        self.dragDY = getMouseY() - self:getY()
        return
    end
    -- The grip is checked before the roster, but it cannot collide with it: the
    -- roster is on the left edge and this is the bottom-RIGHT corner.
    if x >= self.width - GRIP and y >= self.height - GRIP then
        self.resizing = true
        self.resizeDX = getMouseX() - self.width
        self.resizeDY = getMouseY() - self.height
        return
    end

    local i = rowAt(self, x, y)
    if i and self.rows[i].enabled then
        self:showTab(self.rows[i].id)
    end
end

-- Clamped to the SCREEN as well as to MIN. A deck dragged wider than the display
-- puts its own resize grip somewhere unreachable, which is the same class of
-- trap as an off-screen titlebar.
function DFDeck:applyResize()
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
        -- The expensive half happens ONCE, here: a tab with no resize hook is
        -- rebuilt, the size is persisted, and a font-tier change is applied.
        self:settleResize()
    end
end

function DFDeck:onMouseUp(x, y)        endDrag(self) end
function DFDeck:onMouseUpOutside(x, y) endDrag(self) end

-- ---------------------------------------------------------------------------
-- Open / close / toggle / keybind. Same access policy as DFPanel: sandbox
-- tier via RDAccess.meetsTier, failing closed to admin-only. Shift+Numpad9
-- for the incubation (primary opener is the DFDeckButton sidebar badge);
-- the swap inherits Shift+U.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Remembered size. Client-local, one line, failures non-fatal: a deck that
-- forgets its size is a nuisance, a deck that refuses to open because it could
-- not write a preference is a fault. Position is NOT saved - the deck centres
-- itself on the screen it opens on, which is the right answer when the screen
-- may have changed since last session.
-- ---------------------------------------------------------------------------

function DFDeck.saveLayout(w, h)
    pcall(function()
        local f = getFileWriter(LAYOUT_FILE, true, false)
        if not f then return end
        f:write(string.format("w=%d h=%d\n", math.floor(w), math.floor(h)))
        f:close()
    end)
end

function DFDeck.loadLayout()
    local w, h
    pcall(function()
        local r = getFileReader(LAYOUT_FILE, false)
        if not r then return end
        local line = r:readLine()
        r:close()
        if not line then return end
        w = tonumber(line:match("w=(%d+)"))
        h = tonumber(line:match("h=(%d+)"))
    end)
    return w, h
end

function DFDeck.canOpen()
    local tier
    pcall(function() tier = SandboxVars.RFTDDragonfly and SandboxVars.RFTDDragonfly.PanelAccess end)
    return RDAccess.meetsTier(getPlayer(), tier)
end

function DFDeck.open()
    if not DFDeck.canOpen() then
        print("[Deck] open denied: caller lacks admin/staff access")
        return
    end
    if DFDeckState.instance then
        DFDeckState.instance:setVisible(true)
        DFDeckState.instance:addToUIManager()
        DFDeckState.instance.sweepMs = 0
        DFDeckState.instance:rebuild()
        return
    end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    -- 1092x714: the 1456x952 it grew to, taken back down 25%. Net effect is
    -- roughly the original 1040x680 plus 5%.
    --
    -- Clamped with a margin so the deck can never open larger than the screen
    -- it lands on - an off-screen titlebar is an unmovable window. The clamp
    -- still matters at this size: 1092 wide overflows a 1024x768 display.
    local rw, rh = DFDeck.loadLayout()
    local w = math.min(rw or 1292, sw - 80)
    local h = math.min(rh or 714,  sh - 80)
    if w < MIN_W then w = math.min(MIN_W, sw - 80) end
    if h < MIN_H then h = math.min(MIN_H, sh - 80) end

    -- The font tier belongs to the TEXT SIZE PREFERENCE - set before the
    -- first build, or every widget bakes the old font and only a later pref
    -- change would correct it. (It used to follow the remembered width, which
    -- fought the settings wheel; see settleResize.)
    if DFPrefs and DFPrefs.get and DFKit.setFontScale then
        DFKit.setFontScale(DFPrefs.get("fontScale"))
    end
    local inst = DFDeck:new(math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    inst:initialise()
    inst:addToUIManager()
    inst:setVisible(true)
    DFDeckState.instance = inst
end

function DFDeck.close()
    if DFDeckState.instance then
        DFDeckState.instance:removeFromUIManager()
        DFDeckState.instance = nil
    end
end

function DFDeck.toggle()
    if DFDeckState.instance and DFDeckState.instance:getIsVisible() then
        DFDeck.close()
    else
        DFDeck.open()
    end
end

local function shiftDown()
    local ok, held = pcall(function()
        return isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT)
    end)
    return ok and held == true
end

-- Registered ONCE across any number of reloads; the closure reads the DFDeck
-- global at press time, so the single registration always runs current code.
-- Keycode resolved symbolically with the verified constant as the net
-- (KEY_NUMPAD9 = 73, org/lwjglx/input/Keyboard.java:94).
if not DFDeckState.hooked then
    DFDeckState.hooked = true
    local deckKey = nil
    Events.OnKeyPressed.Add(function(key)
        if deckKey == nil then
            local ok, v = pcall(function() return Keyboard.KEY_NUMPAD9 end)
            deckKey = (ok and type(v) == "number") and v or 73
        end
        if key ~= deckKey then return end
        if not shiftDown() then return end
        DFDeck.toggle()
    end)
end

-- A text-size change while the deck is OPEN re-bakes nothing on its own:
-- ISLabel and ISButton capture their font at construction, so the settings
-- wheel used to flip the drawn chrome to the new size while every widget kept
-- the old one - the "text falls out of its boxes without touching the resize
-- grip" report. Only a rebuild applies a tier change, so listen for the
-- preference and rebuild the active tab when the tier moved past the one the
-- widgets BAKED (the builtTier stamp in showTab). Not setFontScale's return:
-- DFPrefs.apply() syncs the tracker before it notifies, so from here that
-- always reports "no move" - gating on it is a listener that never fires.
-- Registered ONCE across hot reloads via DFDeckState, dereferencing the
-- globals at call time - the same discipline as the keybind. Opacity changes
-- ride this listener harmlessly: the tier has not moved past the stamp, so
-- nothing rebuilds. (With LMEditView keeping a dirty draft across attach,
-- this rebuild no longer costs the Zones tab its unsaved work.)
if DFPrefs and DFPrefs.onChange and not DFDeckState.prefsHooked then
    DFDeckState.prefsHooked = true
    DFPrefs.onChange(function()
        local inst = DFDeckState.instance
        if not inst then return end
        local vis = false
        pcall(function() vis = inst:getIsVisible() end)
        if not vis then return end
        if inst.activeId and inst.builtTier ~= DFKit.fontScale then
            inst:showTab(inst.activeId)
        end
    end)
end

print("[Deck] DFDeck loaded (incubation shell - sidebar badge or Shift+Numpad9)")

return DFDeck

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
