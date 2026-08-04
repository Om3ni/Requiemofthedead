-- RCClaimGUI - the access manager (client). ONE window, two doors.
--
-- A permission GRID: top "Everyone" row = per-vehicle PUBLIC flags, one row per
-- whitelisted player, four checkbox columns (Driver/Passenger/Mechanic/Inventory).
-- Below it: revoke a player, or grant a new one by name. (The old live
-- online-players list is gone on purpose: client-side getOnlinePlayers()
-- only sees STREAMED players, so the list was incomplete and stale by
-- design - add-by-name is the one door that always works.)
--
-- It is opened two ways, and reads/edits through a SOURCE abstraction so the two
-- never diverge:
--   * RCClaimGUI.open(vehicle, player)              - at the car (radial). The
--     source reads live modData and edits by vehicleId. Always editable.
--   * RCClaimGUI.openForClaim(claimId, snap, player) - from the fleet panel. The
--     source reads a server-sent snapshot (the enriched My Vehicles slice) and
--     edits by claimId. Editable ONLY while the car is loaded somewhere on the
--     server (snap.loaded); otherwise the grid greys with "out of range".
--
-- The window NEVER writes claim modData. Every toggle is a server command; the
-- live source's cells read synced modData, the snapshot source re-reads from the
-- next slice the server pushes (both refresh on the server's post-write signal).

if isServer() and not isClient() then return end

require "ISUI/ISCollapsableWindow"

RCClaimGUI = ISCollapsableWindow:derive("RCClaimGUI")
RCClaimGUI.instance = nil

local M     = RCShared.MODULE
local PAD   = 10
local BTN_H = 24
local NAME_X = 8
-- checkbox column centres (relative to the grid's left edge)
local CX = { driver = 190, passenger = 265, mechanic = 340, inventory = 415 }
local ORDER = { "driver", "passenger", "mechanic", "inventory" }
local BOX = 16
local HIT = 16  -- half-width of a column's clickable zone

-- ---------------------------------------------------------------------------
-- Sources: the ONLY difference between at-the-car and fleet-panel management.
-- Both expose the same read + command surface so the grid is source-agnostic.
-- ---------------------------------------------------------------------------
local function sendCmd(source, cmd, extra)
    local a = source.cmdArgs()
    if extra then for k, v in pairs(extra) do a[k] = v end end
    sendClientCommand(source.player, M, cmd, a)
end

-- Live vehicle (radial / at the car). Reads live modData; edits by vehicleId.
local function vehicleSource(vehicle, player)
    local vehicleId = vehicle and vehicle:getId() or nil
    return {
        mode      = "live",
        player    = player,
        vehicleId = vehicleId,
        claimId   = vehicle and RCClaim.getClaimId(vehicle) or nil,
        getOwner      = function() return RCClaim.getOwner(vehicle) end,
        getAllowedMap = function() return RCClaim.getAllowedMap(vehicle) end,
        getPublic     = function() return RCClaim.getPublic(vehicle) end,
        isEditable    = function() return true end,
        cmdArgs       = function() return { vehicleId = vehicleId } end,
    }
end

-- Snapshot (fleet panel). Reads a server-sent perm snapshot; edits by claimId.
-- Editable only while the car is loaded (snap.loaded). snap is mutated in place
-- when a fresh slice arrives, so the grid re-renders against current data.
local function claimSource(claimId, snap, player)
    snap = snap or {}
    return {
        mode      = "snapshot",
        player    = player,
        vehicleId = nil,
        claimId   = claimId,
        snap      = snap,
        getOwner      = function() return snap.owner end,
        getAllowedMap = function() return snap.allowed or {} end,
        getPublic     = function() return snap.public or {} end,
        isEditable    = function() return snap.loaded == true end,
        cmdArgs       = function() return { claimId = claimId } end,
    }
end

-- ---------------------------------------------------------------------------
-- The grid list (custom-drawn checkbox rows)
-- ---------------------------------------------------------------------------
local PermGrid = ISScrollingListBox:derive("RCPermGrid")

local function cellChecked(source, row, perm)
    if row.public then return source.getPublic()[perm] == true end
    local e = source.getAllowedMap()[row.username]
    return (e and e[perm] == true) or false
end

function PermGrid:doDrawItem(y, item, alt)
    local row = item.item
    local ih = self.itemheight
    local editable = self.source.isEditable()

    if self.selected == item.index then
        self:drawRect(0, y, self.width, ih - 1, 0.3, 0.45, 0.55, 0.35)
    end
    self:drawRectBorder(0, y, self.width, ih, 0.10, 1, 1, 1)

    -- dim everything when the source can't be edited (out of range)
    local dim = editable and 1 or 0.45

    local label = row.public and getText("IGUI_RC_Everyone") or row.username
    local nr, ng, nb = 1, 1, 1
    if row.public then nr, ng, nb = 1.0, 0.85, 0.4 end
    self:drawText(label, NAME_X, y + (ih - getTextManager():getFontHeight(UIFont.Small)) / 2,
        nr * dim, ng * dim, nb * dim, 1, UIFont.Small)

    local by = y + (ih - BOX) / 2
    for _, perm in ipairs(ORDER) do
        local cx = CX[perm]
        local bx = cx - BOX / 2
        self:drawRectBorder(bx, by, BOX, BOX, 0.9 * dim, 0.7, 0.7, 0.7)
        if cellChecked(self.source, row, perm) then
            self:drawRect(bx + 3, by + 3, BOX - 6, BOX - 6, 1, 0.30 * dim, 0.85 * dim, 0.35 * dim) -- filled = ON
        end
    end
    return y + ih
end

function PermGrid:onMouseDown(x, y)
    local idx = self:rowAt(x, y)
    if not idx or idx < 1 or idx > #self.items then return end
    self.selected = idx
    if not self.source.isEditable() then return end   -- greyed: no toggling
    local row = self.items[idx].item

    for _, perm in ipairs(ORDER) do
        if math.abs(x - CX[perm]) <= HIT then
            local cur = cellChecked(self.source, row, perm)
            if row.public then
                sendCmd(self.source, "setpublic", { perm = perm, value = not cur })
            else
                sendCmd(self.source, "setperm", { target = row.username, perm = perm, value = not cur })
            end
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------
local function openWith(source, playerObj)
    if RCClaimGUI.instance then
        RCClaimGUI.instance:close()
        RCClaimGUI.instance = nil
    end
    local w, h = 470, 310
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = RCClaimGUI:new(x, y, w, h, source, playerObj)
    o:initialise()
    o:addToUIManager()
    RCClaimGUI.instance = o
    return o
end

-- At-the-car (radial / world menu): live vehicle.
function RCClaimGUI.open(vehicle, playerObj)
    return openWith(vehicleSource(vehicle, playerObj), playerObj)
end

-- Fleet panel: by claimId + the slice's perm snapshot (owner is the viewer).
function RCClaimGUI.openForClaim(claimId, snapshot, playerObj)
    snapshot = snapshot or {}
    snapshot.owner = snapshot.owner or (playerObj and playerObj:getUsername())
    return openWith(claimSource(claimId, snapshot, playerObj), playerObj)
end

function RCClaimGUI:new(x, y, w, h, source, playerObj)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title     = getText("IGUI_RC_ManageTitle")
    o.source    = source
    o.playerObj = playerObj
    o.resizable = false
    o.pin       = true   -- don't auto-collapse on mouse-leave (still hand-collapsible)
    return o
end

function RCClaimGUI:createChildren()
    ISCollapsableWindow.createChildren(self)

    local th = getTextManager():getFontHeight(UIFont.Small)
    local listW = self.width - PAD * 2
    local y = self:titleBarHeight() + PAD

    self.lblLegend = ISLabel:new(PAD, y, th, getText("IGUI_RC_Legend"), 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.lblLegend:initialise(); self:addChild(self.lblLegend)
    y = y + th + 6

    self.headerY = y
    y = y + th + 2

    self.grid = PermGrid:new(PAD, y, listW, 170)
    self.grid:initialise()
    self.grid.itemheight = th + 10
    self.grid.font = UIFont.Small
    self.grid.drawBorder = true
    self.grid.source = self.source
    self:addChild(self.grid)
    y = y + 170 + 6

    self.btnRevoke = ISButton:new(PAD, y, 120, BTN_H, getText("IGUI_RC_Revoke"), self, RCClaimGUI.onRevoke)
    self.btnRevoke:initialise(); self:addChild(self.btnRevoke)

    self.btnAddName = ISButton:new(PAD + 128, y, listW - 128, BTN_H, getText("IGUI_RC_AddByName"), self, RCClaimGUI.onAddByName)
    self.btnAddName:initialise(); self:addChild(self.btnAddName)

    self:refresh()
end

function RCClaimGUI:prerender()
    ISCollapsableWindow.prerender(self)
    if not self.headerY then return end
    local labels = {
        driver = getText("IGUI_RC_ColDriver"),
        passenger = getText("IGUI_RC_ColPassenger"),
        mechanic = getText("IGUI_RC_ColMechanic"),
        inventory = getText("IGUI_RC_ColInventory"),
    }
    for _, perm in ipairs(ORDER) do
        local txt = labels[perm]
        local w = getTextManager():MeasureStringX(UIFont.Small, txt)
        self:drawText(txt, PAD + CX[perm] - w / 2, self.headerY, 0.85, 0.85, 0.9, 1, UIFont.Small)
    end

    -- "Out of range" banner when the snapshot can't be edited (car unloaded).
    if not self.source.isEditable() then
        local txt = getText("IGUI_RC_OutOfRange")
        local w = getTextManager():MeasureStringX(UIFont.Small, txt)
        self:drawText(txt, self.width - PAD - w, self:titleBarHeight() + 2, 1, 0.55, 0.35, 1, UIFont.Small)
    end
end

-- Enable/disable the mutation buttons to match editability.
function RCClaimGUI:applyEditable()
    local ed = self.source.isEditable()
    if self.btnRevoke  then self.btnRevoke:setEnable(ed) end
    if self.btnAddName then self.btnAddName:setEnable(ed) end
end

function RCClaimGUI:refresh()
    if not self.grid then return end

    -- DFKit.refillList: a bare clear() leaves the scroll height behind and
    -- addItem stacks onto it, which eventually scrolls the list off its own
    -- rows. See that function's header.
    DFKit.refillList(self.grid, function(box)
        box:addItem(getText("IGUI_RC_Everyone"), { public = true })
        local map = self.source.getAllowedMap()
        local names = {}
        for nm in pairs(map) do names[#names + 1] = nm end
        table.sort(names)
        for _, nm in ipairs(names) do
            box:addItem(nm, { username = nm })
        end
    end)

    self:applyEditable()
end

local function selectedRowUsername(grid)
    if not grid or not grid.selected then return nil end
    local item = grid.items[grid.selected]
    local row = item and item.item
    if row and not row.public then return row.username end
    return nil
end

function RCClaimGUI:onRevoke()
    if not self.source.isEditable() then return end
    local name = selectedRowUsername(self.grid)
    if name then sendCmd(self.source, "deny", { target = name }) end
end

-- ISTextBox OK/CANCEL callback. The source travels through as param1.
function RCClaimGUI.onAddNameClick(target, button, source)
    if button.internal ~= "OK" then return end
    if not source.isEditable() then return end
    local txt = button.parent.entry:getInternalText()
    if txt and txt ~= "" then sendCmd(source, "allow", { target = txt }) end
end

function RCClaimGUI:onAddByName()
    if not self.source.isEditable() then return end
    local w, h = 300, 130
    local playerIndex = self.playerObj and self.playerObj:getPlayerNum() or 0
    local modal = ISTextBox:new(
        getCore():getScreenWidth() / 2 - w / 2,
        getCore():getScreenHeight() / 2 - h / 2,
        w, h,
        getText("IGUI_RC_AddByNamePrompt"), "", nil,
        RCClaimGUI.onAddNameClick, playerIndex, self.source)
    modal:initialise()
    modal:addToUIManager()
end

function RCClaimGUI:close()
    RCClaimGUI.instance = nil
    ISCollapsableWindow.close(self)
end

-- ---------------------------------------------------------------------------
-- Server -> client refresh.
--   live source     -> ClaimUpdate (cells read live synced modData).
--   snapshot source -> the enriched My Vehicles slice: find our claim, update
--                       the snapshot in place (perms + loaded), re-render. If our
--                       claim is gone from the slice (released/expired), close.
-- ---------------------------------------------------------------------------
local function onServerCommand(module, command, args)
    if module ~= M then return end
    local inst = RCClaimGUI.instance
    if not inst then return end

    if command == "ClaimUpdate" and inst.source.mode == "live" then
        if not args or args.vehicleId == nil or args.vehicleId == inst.source.vehicleId then
            inst:refresh()
        end
    elseif command == "MyVehicles" and inst.source.mode == "snapshot" then
        local cid = inst.source.claimId
        for _, rec in ipairs((args and args.list) or {}) do
            if rec.claimId == cid then
                local snap = inst.source.snap
                snap.loaded  = rec.loaded
                snap.allowed = rec.allowed or {}
                snap.public  = rec.public or {}
                inst:refresh()
                return
            end
        end
        inst:close()  -- claim no longer ours: nothing to manage
    end
end
Events.OnServerCommand.Add(onServerCommand)
