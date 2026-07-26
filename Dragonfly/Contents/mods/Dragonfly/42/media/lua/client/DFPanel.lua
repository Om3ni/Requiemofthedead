-- DFPanel - F10 admin window. Hosts tabs registered via DFRegistry.
--
-- Chassis only: tab bar, content area, status badge strip, prerender refresh.
-- No first-party tabs live here; the basic Zombies tab and consumer tabs
-- all come in via DFRegistry. Window title is "Dragonfly Admin Panel".

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISPanel"

DFPanel = ISCollapsableWindow:derive("DFPanel")
DFPanel.instance = nil

local TITLE         = "Dragonfly Admin Panel"
local TAB_HEIGHT    = 26
local TAB_GAP       = 4
local BADGE_HEIGHT  = 18
local CHROME_HEIGHT = 24
local PADDING       = 8

function DFPanel:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title       = TITLE
    o.resizable   = true
    o.pin         = true
    o.minimumWidth  = 640
    o.minimumHeight = 480
    o.activeTabId   = nil
    o.tabButtons    = {}
    o.contentArea   = nil
    return o
end

function DFPanel:initialise()
    ISCollapsableWindow.initialise(self)
end

function DFPanel:createChildren()
    ISCollapsableWindow.createChildren(self)
    self:rebuild()
end

-- Build tab buttons + content area from current registry state. Called
-- on open and when registry contents change (rare, mainly for hot-reload
-- during development).
function DFPanel:rebuild()
    for _, btn in ipairs(self.tabButtons) do
        if btn.removeFromUIManager then btn:removeFromUIManager() end
        self:removeChild(btn)
    end
    self.tabButtons = {}
    if self.contentArea then self:removeChild(self.contentArea) end

    local y = self:titleBarHeight() + PADDING

    -- Status badges row. Each registered consumer (Ladybug etc.) reports
    -- one short status line; useful for verifying which mods are loaded.
    local badges = DFRegistry.getStatusBadges()
    if #badges > 0 then
        local text = ""
        for i, b in ipairs(badges) do
            if i > 1 then text = text .. "  |  " end
            text = text .. tostring(b.text or b.id)
        end
        local lbl = ISLabel:new(PADDING, y, BADGE_HEIGHT, text, 0.7, 0.85, 0.7, 1, UIFont.Small, true)
        lbl:initialise()
        lbl:instantiate()
        self:addChild(lbl)
        y = y + BADGE_HEIGHT + PADDING
    end

    -- Chrome toolbar: global panel controls (coord overlay toggle, sudo
    -- easter egg). Right-anchored so it doesn't crowd the tab row.
    self.overlayBtn = ISButton:new(self.width - 158, y, 150, CHROME_HEIGHT,
        DFCoordOverlay.isOpen() and "Coord overlay: ON" or "Coord overlay: OFF",
        self, function()
            DFCoordOverlay.toggle()
            self.overlayBtn:setTitle(
                DFCoordOverlay.isOpen() and "Coord overlay: ON" or "Coord overlay: OFF")
        end)
    self.overlayBtn.borderColor.a = 0.4
    self.overlayBtn:initialise()
    self.overlayBtn:instantiate()
    self:addChild(self.overlayBtn)

    self.sudoBtn = ISButton:new(self.width - 184, y, 22, CHROME_HEIGHT,
        "?", self, function()
            if DFFeedback then
                DFFeedback.good("sudo: a tool for managing your bug colony.")
            end
        end)
    self.sudoBtn:setTooltip("sudo: a tool for managing your bug colony")
    self.sudoBtn.borderColor.a = 0.4
    self.sudoBtn:initialise()
    self.sudoBtn:instantiate()
    self:addChild(self.sudoBtn)

    y = y + CHROME_HEIGHT + PADDING

    -- Tab bar.
    local tabs = DFRegistry.getTabs()
    local x = PADDING
    for _, spec in ipairs(tabs) do
        local label = tostring(spec.label or spec.id)
        local width = getTextManager():MeasureStringX(UIFont.Small, label) + 24
        local btn = ISButton:new(x, y, width, TAB_HEIGHT, label, self, DFPanel.onTabButton)
        btn.internal     = spec.id
        btn.borderColor.a = 0.4
        btn:initialise()
        btn:instantiate()
        self:addChild(btn)
        self.tabButtons[#self.tabButtons + 1] = btn
        x = x + width + TAB_GAP
    end
    y = y + TAB_HEIGHT + PADDING
    self.contentTopY = y

    if #tabs > 0 then
        self:showTab(self.activeTabId or tabs[1].id)
    else
        self:showEmptyState()
    end
end

function DFPanel:contentHeight()
    return self.height - (self.contentTopY or 0) - PADDING * 2
end

function DFPanel:showEmptyState()
    local msg = "No tabs registered. Install Reaper or Husbandry to add tabs."
    local lbl = ISLabel:new(PADDING, PADDING + 20, BADGE_HEIGHT, msg, 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    lbl:initialise()
    lbl:instantiate()
    self.contentArea:addChild(lbl)
    self.contentArea.emptyLabel = lbl
end

function DFPanel:showTab(id)
    self.activeTabId = id
    local spec = DFRegistry.tabs[id]
    if not spec then return end

    if self.contentArea then self:removeChild(self.contentArea) end

    local y = self.contentTopY or (self:titleBarHeight() + PADDING + TAB_HEIGHT + PADDING)
    local contentH = self:contentHeight()
    self.contentArea = ISPanel:new(PADDING, y, self.width - PADDING * 2, contentH)
    self.contentArea.background = false
    self.contentArea.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.5 }
    self.contentArea:initialise()
    self.contentArea:instantiate()
    self:addChild(self.contentArea)

    -- Highlight the active tab button.
    for _, btn in ipairs(self.tabButtons) do
        btn.backgroundColor = (btn.internal == id)
            and { r = 0.25, g = 0.35, b = 0.55, a = 0.7 }
            or  { r = 0.0,  g = 0.0,  b = 0.0,  a = 0.5 }
    end

    if type(spec.build) == "function" then
        local ok, err = pcall(spec.build, spec, self.contentArea,
            0, 0, self.contentArea.width, self.contentArea.height)
        if not ok then
            print(string.format("[Dragonfly] tab build failed (%s): %s", tostring(id), tostring(err)))
        end
    end
end

function DFPanel:onTabButton(button)
    if button and button.internal then self:showTab(button.internal) end
end

-- Prerender refresh: live capability check on tab buttons so a role change
-- mid-session greys out tabs the player can no longer access.
function DFPanel:prerender()
    ISCollapsableWindow.prerender(self)
    local p = getPlayer()
    for _, btn in ipairs(self.tabButtons) do
        local spec = DFRegistry.tabs[btn.internal]
        if spec and spec.capability then
            btn.enable = DFCore.roleHas(p, spec.capability)
        else
            btn.enable = true
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Open / close / toggle / keybind
-- ─────────────────────────────────────────────────────────────────────────

-- Panel access is a SANDBOX POLICY (RFTDDragonfly.PanelAccess) resolved by
-- RDAccess.meetsTier: 1 = Admin only (the shipped default - access level
-- "admin", nothing less), 2 = all staff (any capability). The default stays
-- deliberately strict because the role editor can grant capabilities to the
-- User role, which under "all staff" would let every player open the panel -
-- a server choosing tier 2 is choosing to own that. Per-tab gating in
-- prerender still hides tabs a role doesn't grant. FAILS CLOSED: a bad
-- lookup or unset option resolves to Admin only. (isAdmin() is deliberately
-- not consulted - it can return false for a genuine admin on a
-- dedicated-server client; the access-level check inside isTopAdmin is the
-- authoritative path, same robust pattern the rest of RFTD uses.)
function DFPanel.canOpen()
    local tier
    pcall(function() tier = SandboxVars.RFTDDragonfly and SandboxVars.RFTDDragonfly.PanelAccess end)
    return RDAccess.meetsTier(getPlayer(), tier)
end

function DFPanel.open()
    -- Admin/staff gate. Without this any player can open the panel and see
    -- every tab; per-tab capability checks only grey out buttons, they don't
    -- stop the window from opening. Silent return so the panel's existence
    -- isn't advertised to non-staff.
    if not DFPanel.canOpen() then
        print("[Dragonfly] DFPanel.open denied: caller lacks admin/staff access")
        return
    end

    -- Always print current registry state on open so the console shows
    -- whether tabs registered or not. v0.1 diagnostic.
    if DFRegistry and DFRegistry.getTabs then
        local tabs = DFRegistry.getTabs()
        local names = {}
        for _, t in ipairs(tabs) do names[#names + 1] = t.id end
        print("[Dragonfly] DFPanel.open: registry has " .. #tabs ..
              " tab(s): " .. table.concat(names, ", "))
    else
        print("[Dragonfly] DFPanel.open: DFRegistry not loaded!")
    end

    if DFPanel.instance then
        DFPanel.instance:setVisible(true)
        DFPanel.instance:addToUIManager()
        DFPanel.instance:rebuild()
        return
    end
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local w, h = 1040, 680
    local x = math.floor((sw - w) / 2)
    local y = math.floor((sh - h) / 2)
    DFPanel.instance = DFPanel:new(x, y, w, h)
    DFPanel.instance:initialise()
    DFPanel.instance:addToUIManager()
    DFPanel.instance:setVisible(true)
end

function DFPanel.close()
    if DFPanel.instance then
        DFPanel.instance:removeFromUIManager()
        DFPanel.instance = nil
    end
end

function DFPanel.toggle()
    if DFPanel.instance and DFPanel.instance:getIsVisible() then
        DFPanel.close()
    else
        DFPanel.open()
    end
end

-- Keybind. Default Shift+U (LWJGL keycode 22 + shift requirement).
-- Rebind in sandbox via RFTDDragonfly.OpenKeybind and OpenKeyRequiresShift.
-- Set OpenKeybind to 0 to disable entirely. F10 is reserved by PZ for debug
-- mode, so avoid 68.
local function shiftDown()
    local ok, held = pcall(function()
        return isKeyDown(Keyboard.KEY_LSHIFT) or isKeyDown(Keyboard.KEY_RSHIFT)
    end)
    return ok and held == true
end

local function onKeyPressed(key)
    local s = SandboxVars.RFTDDragonfly or {}
    if s.Enabled == false then return end
    local bound = tonumber(s.OpenKeybind) or 22
    if bound <= 0 or key ~= bound then return end
    if s.OpenKeyRequiresShift ~= false and not shiftDown() then return end
    DFPanel.toggle()
end
Events.OnKeyPressed.Add(onKeyPressed)

print("[Dragonfly] DFPanel loaded (v" .. tostring(DFCore.VERSION) .. ", Shift+U to open)")
