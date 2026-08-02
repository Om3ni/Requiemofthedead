-- DFDeck.lua - the deck: Growl-skinned admin shell (client only).
--
-- INCUBATION CONTRACT. This is the successor chassis to Dragonfly's DFPanel,
-- running ALONGSIDE it while the skin matures: same registry (DFRegistry, in
-- Core), same tab build contract - spec.build(spec, contentPanel, 0, 0, w, h)
-- - same access policy (RDAccess.meetsTier over RFTDDragonfly.PanelAccess,
-- the sandbox page old Dragonfly already ships under this mod's name). Every
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
local SWEEP_MS = 1800
local BEAT     = 30      -- frames between status/capability refreshes

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
    o.openedMs      = 0
    o.beat          = 0
    o.statusText    = ""
    o.dragging      = false
    o.dragDX, o.dragDY = 0, 0
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
            enabled = true,
            hoverT  = 0,
        }
    end
    if #self.rows > 0 then
        self:showTab(self.activeId or self.rows[1].id)
    end
end

function DFDeck:showTab(id)
    self.activeId = id
    local spec = DFRegistry.tabs[id]
    if not spec then return end

    if self.contentArea then self:removeChild(self.contentArea) end
    local cx = ROSTER_W + PAD
    local cy = TITLE_H + PAD
    local cw = self.width - cx - PAD
    local ch = self.height - cy - PAD
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
        local cap = self.rows[i].spec.capability
        self.rows[i].enabled = (cap == nil) or RDAccess.roleHas(p, cap)
    end
end

function DFDeck:prerender()
    local d  = DFTheme.delta()
    local ms = d * 33.3
    self.clockMs  = self.clockMs + ms
    self.openedMs = self.openedMs + ms
    self.beat = self.beat - 1
    if self.beat <= 0 then
        self.beat = BEAT
        self:refreshBeat()
    end

    local w, h = self.width, self.height

    -- frame: void ground, scar outline, murk strips
    DFTheme.roundFrame(self, 0, 0, w, h, DFTheme.radius, 1, C.scar, C.void)
    self:drawRect(1, 1, w - 2, TITLE_H - 1, 1, C.murk.r, C.murk.g, C.murk.b)
    DFTheme.hairline(self, 1, TITLE_H, w - 2)
    self:drawRect(1, TITLE_H + 1, ROSTER_W - 1, h - TITLE_H - 2, 1, C.murk.r, C.murk.g, C.murk.b)
    DFTheme.hairlineV(self, ROSTER_W, TITLE_H + 1, h - TITLE_H - 2)
    DFTheme.vein(self, 1, TITLE_H + 1, ROSTER_W - 1, math.min(560, h - TITLE_H - 2), 0.06)

    -- the mark: ring, disc, D
    local mx, my, mr = 14, math.floor((TITLE_H - 26) / 2), 26
    DFTheme.roundRect(self, mx, my, mr, mr, mr / 2, 1, C.sightDim)
    DFTheme.roundRect(self, mx + 1, my + 1, mr - 2, mr - 2, (mr - 2) / 2, 1, C.black)
    DFTheme.textCentre(self, "D", mx + mr / 2, my + 5, DFTheme.font.label, C.sight)

    DFTheme.text(self, "DRAGONFLY", mx + mr + 12, 10, DFTheme.font.label, C.bone)
    DFTheme.text(self, "ADMIN COMMAND DECK", mx + mr + 108, 10, DFTheme.font.label, C.ash, 0.8)

    -- watch pulse + status, right side
    local pulse = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(self.clockMs / 4000 * 6.283))
    local sw = DFTheme.strW(DFTheme.font.label, self.statusText)
    self:drawRect(w - sw - 46, 17, 6, 6, pulse, C.sight.r, C.sight.g, C.sight.b)
    DFTheme.text(self, self.statusText, w - sw - 34, 10, DFTheme.font.label, C.ash)

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

    -- the sweep: once, on open (rule 4)
    if self.openedMs < SWEEP_MS then
        local t = self.openedMs / SWEEP_MS
        local a = (t < 0.12) and (t / 0.12) * 0.5 or (1 - t) * 0.5
        self:drawRect(1, math.floor(t * (h - 2)), w - 2, 2, a, C.sight.r, C.sight.g, C.sight.b)
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
    local x, y = self:getMouseX(), self:getMouseY()
    if y < TITLE_H then
        self.hoverRow = (x > self.width - 28) and "close" or nil
    else
        self.hoverRow = rowAt(self, x, y)
    end
    if self.dragging then
        self:setX(getMouseX() - self.dragDX)
        self:setY(getMouseY() - self.dragDY)
    end
end

function DFDeck:onMouseMoveOutside(dx, dy)
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
        self.dragging = true
        self.dragDX = getMouseX() - self:getX()
        self.dragDY = getMouseY() - self:getY()
        return
    end
    local i = rowAt(self, x, y)
    if i and self.rows[i].enabled then
        self:showTab(self.rows[i].id)
    end
end

function DFDeck:onMouseUp(x, y)        self.dragging = false end
function DFDeck:onMouseUpOutside(x, y) self.dragging = false end

-- ---------------------------------------------------------------------------
-- Open / close / toggle / keybind. Same access policy as DFPanel: sandbox
-- tier via RDAccess.meetsTier, failing closed to admin-only. Shift+Numpad9
-- for the incubation (primary opener is the DFDeckButton sidebar badge);
-- the swap inherits Shift+U.
-- ---------------------------------------------------------------------------

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
        DFDeckState.instance.openedMs = 0
        DFDeckState.instance:rebuild()
        return
    end
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = 1040, 680
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

print("[Deck] DFDeck loaded (incubation shell - sidebar badge or Shift+Numpad9)")

return DFDeck

-- ---------------------------------------------------------------------------
-- Copyright Project_Omen
