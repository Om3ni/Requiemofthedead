-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCMyVehicles - the player-facing fleet panel (client).
--
-- Lists every vehicle the LOCAL player has claimed (their registry slice, read
-- server-side and pushed back on request), with a live 3D preview of the
-- selected car, its last-known location + distance, and a Release button.
--
-- The panel holds NO authority: the list comes from the server (the "MyVehicles"
-- command), and Release is a server command (releaseclaim by claimId) that works
-- for UNLOADED cars too - the whole point of a fleet manager. modData stays the
-- source of truth; this is a viewer + a request button.
--
-- Entry point: the vanilla MP "Client" panel button (see RCUserPanelHook).

if isServer() and not isClient() then return end

require "ISUI/ISCollapsableWindow"

RCMyVehicles = ISCollapsableWindow:derive("RCMyVehicles")
RCMyVehicles.instance = nil

local M    = RCShared.MODULE
local PAD  = 10
local BTN_H = 24
local LIST_W = 220
local PREVIEW_H = 190

-- Prettify a vehicle script name for display: drop the module prefix
-- ("Base.CarNormal" -> "CarNormal") and space out CamelCase / underscores.
local function prettyName(scriptName)
    if not scriptName or scriptName == "" then return "?" end
    local s = scriptName:gsub("^%a+%.", "")
    s = s:gsub("_", " ")
    s = s:gsub("(%l)(%u)", "%1 %2")
    return s
end
-- Shared with RCMyVehiclesTab (the player panel's merged inspector) so the
-- same car can never print two different names on the two surfaces.
RCMyVehicles.prettyName = prettyName

-- ---------------------------------------------------------------------------
-- Open / construct
-- ---------------------------------------------------------------------------
function RCMyVehicles.open(playerObj)
    if RCMyVehicles.instance then
        RCMyVehicles.instance:close()
        RCMyVehicles.instance = nil
    end
    local w, h = LIST_W + PAD * 3 + 300, 470
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = RCMyVehicles:new(x, y, w, h, playerObj)
    o:initialise()
    o:addToUIManager()
    RCMyVehicles.instance = o
    o:requestList()
    return o
end

function RCMyVehicles:new(x, y, w, h, playerObj)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title     = getText("IGUI_RC_MyVehiclesTitle")
    o.playerObj = playerObj
    o.resizable = false
    -- pin=true so it does NOT auto-collapse when the mouse leaves (vanilla
    -- ISCollapsableWindow only auto-collapses while unpinned). The collapse
    -- toggle button stays, so the player can still collapse it by hand.
    o.pin       = true
    o.rows      = {}     -- claimId-keyed records from the server
    o.selRec    = nil
    o.shownSel  = -1
    return o
end

function RCMyVehicles:requestList()
    sendClientCommand(self.playerObj, M, "myvehicles", {})
end

function RCMyVehicles:createChildren()
    ISCollapsableWindow.createChildren(self)

    local th = getTextManager():getFontHeight(UIFont.Small)
    local top = self:titleBarHeight() + PAD
    local listH = self.height - top - BTN_H - PAD * 2

    -- Left: the vehicle list
    self.list = ISScrollingListBox:new(PAD, top, LIST_W, listH)
    self.list:initialise()
    self.list.itemheight = th + 8
    self.list.font = UIFont.Small
    self.list.drawBorder = true
    self:addChild(self.list)

    -- Right column origin
    local rx = PAD * 2 + LIST_W
    local rw = self.width - rx - PAD

    -- Right-top: 3D preview. RETAINED - but the lane is narrower than this
    -- comment used to think: the verb dispatch's throws (UI3DScene.java:894,
    -- :1422) are Java BODY throws, swallowed before Lua sees them. What
    -- genuinely throws here is the CONSTRUCTOR - instantiate() runs
    -- UI3DScene.new(self) (ISUI3DScene.lua:5-15), and constructors are the
    -- one exposed lane that rethrows into Lua (ConstructorCaller.java:25-28,
    -- LuaJavaInvoker.java:150-151) - plus the vanilla ISUIElement Lua around
    -- it. If the scene cannot be built we skip the preview and the rest of
    -- the panel still works. (createVehicle returns nil even on success, so
    -- there is nothing to verify by return value.)
    self.previewY = top
    local ok = pcall(function()
        self.preview = ISUI3DScene:new(rx, top, rw, PREVIEW_H)
        self.preview:initialise()
        self.preview:instantiate()
        self.preview:setView("Right")
        -- The engine clips the 3D render to the box via glViewport, so too high a
        -- zoom clips a large vehicle (truck/SUV) at the box edges. Frame low to
        -- fit the biggest vehicles; the player can mouse-wheel in for detail.
        self.preview.javaObject:fromLua1("setZoom", 2)
        self.preview.javaObject:fromLua1("setDrawGrid", false)
        self.preview.javaObject:fromLua1("createVehicle", "rcPreview")
        self:addChild(self.preview)
    end)
    if not ok then self.preview = nil end

    self.infoY = top + PREVIEW_H + 8   -- info text is drawn here in prerender
    self.rightX = rx

    -- Bottom buttons: Refresh under the list; Manage + Release under the detail.
    -- Manage lights up only when the car is loaded (editable); Release always
    -- works (safe one-way clear, loaded or not).
    local by = self.height - BTN_H - PAD
    local halfW = math.floor((rw - 8) / 2)
    self.btnManage = ISButton:new(rx, by, halfW, BTN_H, getText("IGUI_RC_Manage"), self, RCMyVehicles.onManage)
    self.btnManage:initialise(); self:addChild(self.btnManage)
    self.btnManage:setEnable(false)

    self.btnRelease = ISButton:new(rx + halfW + 8, by, halfW, BTN_H, getText("IGUI_RC_MV_Release"), self, RCMyVehicles.onRelease)
    self.btnRelease:initialise(); self:addChild(self.btnRelease)
    self.btnRelease:setEnable(false)

    self.btnRefresh = ISButton:new(PAD, by, LIST_W, BTN_H, getText("IGUI_RC_MV_Refresh"), self, RCMyVehicles.onRefresh)
    self.btnRefresh:initialise(); self:addChild(self.btnRefresh)
end

-- ---------------------------------------------------------------------------
-- Populate from the server slice
-- ---------------------------------------------------------------------------
function RCMyVehicles:setList(list)
    self.rows = {}
    -- DFKit.refillList: a bare clear() leaves the scroll height behind and
    -- addItem stacks onto it, which eventually scrolls the list off its own
    -- rows. See that function's header.
    DFKit.refillList(self.list, function(box)
        if type(list) ~= "table" then return end
        table.sort(list, function(a, b) return prettyName(a.name) < prettyName(b.name) end)
        for _, rec in ipairs(list) do
            self.rows[#self.rows + 1] = rec
            box:addItem(prettyName(rec.name), rec)
        end
    end)
    -- keep a valid selection
    if #self.rows == 0 then
        self.list.selected = 0
    elseif self.list.selected == nil or self.list.selected < 1 or self.list.selected > #self.rows then
        self.list.selected = 1
    end
    self.shownSel = -1   -- force a selection refresh next prerender
end

function RCMyVehicles:updateSelection()
    local sel = self.list.selected
    local item = sel and self.list.items[sel]
    self.selRec = item and item.item or nil

    -- swap the previewed model (or clear it)
    if self.preview then
        local script = self.selRec and self.selRec.name or ""
        -- Bare: a bad script name does not throw AT ALL - SceneVehicle
        -- .setScriptName null-handles the lookup and the vehicle just stops
        -- rendering (UI3DScene.java:4899, :4665) - and the unknown-id NPE in
        -- the dispatch is a Java BODY throw, swallowed by MethodCaller
        -- (UI3DScene.java:1376, MethodCaller.java:33-56). javaObject exists
        -- whenever self.preview does: both are set inside the same guarded
        -- build above.
        self.preview.javaObject:fromLua2("setVehicleScript", "rcPreview", script or "")
    end
    self.btnRelease:setEnable(self.selRec ~= nil)
    -- Manage only when the car is loaded somewhere (editable); greyed otherwise.
    self.btnManage:setEnable(self.selRec ~= nil and self.selRec.loaded == true)
end

-- ---------------------------------------------------------------------------
-- Render: react to selection changes + draw the info block
-- ---------------------------------------------------------------------------
function RCMyVehicles:prerender()
    ISCollapsableWindow.prerender(self)

    if self.list.selected ~= self.shownSel then
        self.shownSel = self.list.selected
        self:updateSelection()
    end

    -- Empty state
    if #self.rows == 0 then
        self:drawText(getText("IGUI_RC_MV_None"), self.rightX, self.previewY,
            0.8, 0.8, 0.8, 1, UIFont.Small)
        return
    end

    local rec = self.selRec
    if not rec then return end

    local y = self.infoY
    local lh = getTextManager():getFontHeight(UIFont.Small) + 3

    self:drawText(prettyName(rec.name), self.rightX, y, 1, 1, 1, 1, UIFont.Medium)
    y = y + getTextManager():getFontHeight(UIFont.Medium) + 4

    local loc = string.format("%s: %d, %d, %d",
        getText("IGUI_RC_MV_Location"), rec.x or 0, rec.y or 0, rec.z or 0)
    self:drawText(loc, self.rightX, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
    y = y + lh

    -- live distance from the local player
    local p = self.playerObj
    if p and rec.x then
        local dx = p:getX() - rec.x
        local dy = p:getY() - rec.y
        local dist = math.floor(math.sqrt(dx * dx + dy * dy))
        self:drawText(string.format("%s: %d %s", getText("IGUI_RC_MV_Distance"), dist, getText("IGUI_RC_MV_Tiles")),
            self.rightX, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
        y = y + lh
    end

    -- loaded/out-of-range status (drives whether Manage Access is available)
    local stTxt = rec.loaded and getText("IGUI_RC_MV_InRange") or getText("IGUI_RC_OutOfRange")
    local sr, sg, sb = 0.55, 0.85, 0.55
    if not rec.loaded then sr, sg, sb = 1, 0.55, 0.35 end
    self:drawText(stTxt, self.rightX, y, sr, sg, sb, 1, UIFont.Small)
    y = y + lh

    self:drawText(getText("IGUI_RC_MV_ClaimId") .. ": " .. tostring(rec.claimId),
        self.rightX, y, 0.55, 0.55, 0.6, 1, UIFont.Small)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
function RCMyVehicles:onRefresh()
    self:requestList()
end

-- Open the shared access manager for the selected claim. Only reachable when the
-- car is loaded (button is greyed otherwise), so the snapshot carries live perms.
function RCMyVehicles:onManage()
    local rec = self.selRec
    if not rec or not rec.loaded then return end
    if RCClaimGUI and RCClaimGUI.openForClaim then
        RCClaimGUI.openForClaim(rec.claimId,
            { allowed = rec.allowed, public = rec.public, loaded = rec.loaded },
            self.playerObj)
    end
end

function RCMyVehicles:onRelease()
    local rec = self.selRec
    if not rec then return end
    local w, h = 340, 130
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - w / 2,
        getCore():getScreenHeight() / 2 - h / 2,
        w, h,
        getText("IGUI_RC_MV_ConfirmRelease"), true, self, RCMyVehicles.onReleaseConfirm, nil, rec.claimId)
    modal:initialise()
    modal:addToUIManager()
end

function RCMyVehicles:onReleaseConfirm(button, claimId)
    if button.internal ~= "YES" then return end
    if not claimId then return end
    sendClientCommand(self.playerObj, M, "releaseclaim", { claimId = claimId })
    -- the server pushes a fresh slice back after processing; nothing else to do
end

function RCMyVehicles:close()
    -- Vanilla teardown is nil-safe (ISUIElement.lua:1373-1380).
    if self.preview then self.preview:removeFromUIManager() end
    RCMyVehicles.instance = nil
    ISCollapsableWindow.close(self)
end

-- ---------------------------------------------------------------------------
-- Server -> client: the slice arrives here
-- ---------------------------------------------------------------------------
-- Entry point is the vanilla Client panel button (RCUserPanelHook) - management
-- lives there, not on the vehicle right-click menu (owner's UX decision).
local function onServerCommand(module, command, args)
    if module ~= M then return end
    if command ~= "MyVehicles" then return end
    local inst = RCMyVehicles.instance
    if inst then inst:setList(args and args.list or {}) end
end
Events.OnServerCommand.Add(onServerCommand)

-- The player panel's My Vehicles tab (RCMyVehiclesTab) registers itself and
-- is the MERGED surface - this window's list and actions plus the admin
-- inspector's diagram and parts breakdown, minus every power that changes a
-- car. This window keeps its Client-panel door for now; whether it retires is
-- the owner's call, same as the other vanilla-panel entry points.

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
