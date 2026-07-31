-- RLClient.lua - Reliquary: client UI (context menu, fill window, loot-UI lockout).
--
-- Pure front-end: it only ASKS, through RDNet.send, and never mutates the
-- world. Every gate it applies is cosmetic - the server re-checks all of them,
-- and RDNet rejects an unregistered or under-privileged command before a
-- handler sees it. Hiding an option here is about not offering an admin a
-- button that will fail; it is not the security boundary.
--
-- The one exception worth naming is the loot-UI lockout at the bottom, which
-- IS client-side only. A determined client could restore the container button
-- and see the contents. That is acceptable for what a Reliquary holds (staff
-- put it there deliberately, and every transfer is logged with a name); if it
-- ever holds something worth hiding properly, the container must not exist on
-- unauthorized clients at all, which is a server change.

if isServer() then return end

require "ISUI/ISCollapsableWindow"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTextBox"
require "ISUI/ISRichTextPanel"
require "RDNet"
require "OEShared"
require "Reliquary/RLShared"

Reliquary = Reliquary or {}
local RL = Reliquary

local function send(command, args)
    RDNet.send(OEShared.MODULE, command, args)
end

-- ---------------------------------------------------------------------------
-- Server feedback. Core's DFFeedback owns the HaloText wrappers but consumes
-- Result events only on Dragonfly's token, by design - so this mod carries the
-- four lines that route its own token into the same two functions rather than
-- borrowing Dragonfly's wire.
-- ---------------------------------------------------------------------------

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= OEShared.MODULE or command ~= "Result" then return end
    args = args or {}
    if args.ok then
        if args.message then DFFeedback.good(args.message) end
    else
        DFFeedback.bad(args.reason or ("Action failed: " .. tostring(args.action or "?")))
    end
end)

-- ---------------------------------------------------------------------------
-- Fill window: a small multiline entry for the "qty;fulltype, ..." list
-- ---------------------------------------------------------------------------

RLFillWindow = ISCollapsableWindow:derive("RLFillWindow")

function RLFillWindow:new(square)
    local w, h = 420, 260
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() / 2 - h / 2
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.sq = square
    o.title = "Reliquary - fill"
    o:setResizable(false)
    return o
end

function RLFillWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local pad, th = 12, self:titleBarHeight()

    self.help = ISRichTextPanel:new(pad, th + 6, self.width - pad * 2, 46)
    self.help:initialise()
    self.help.background = false
    self.help.autosetheight = false
    self:addChild(self.help)
    self.help.text = "Enter a comma-separated list as <RGB:1,1,0.6>qty;fulltype<RGB:1,1,1>, e.g.\n" ..
                     "<RGB:0.7,0.9,1>5;Base.Nails, 10;Base.ScrapSword<RGB:1,1,1>"
    self.help:paginate()

    local entryY = th + 58
    local entryH = self.height - entryY - 44
    self.entry = ISTextEntryBox:new("", pad, entryY, self.width - pad * 2, entryH)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry:setMultipleLine(true)
    self.entry:setMaxLines(40)
    self.entry.background = true
    self:addChild(self.entry)

    local bw, bh = 120, 28
    self.spawnBtn = ISButton:new(self.width - pad - bw, self.height - 36, bw, bh, "Spawn Items", self, RLFillWindow.onOK)
    self.spawnBtn:initialise(); self:addChild(self.spawnBtn)

    self.cancelBtn = ISButton:new(self.width - pad - bw * 2 - 8, self.height - 36, bw, bh, "Cancel", self, RLFillWindow.onCancel)
    self.cancelBtn:initialise(); self:addChild(self.cancelBtn)
end

function RLFillWindow:onOK()
    local parsed = RL.parseList(self.entry:getText() or "")
    if #parsed.errors > 0 then
        DFFeedback.bad("Skipped malformed: " .. table.concat(parsed.errors, " | "))
    end
    if #parsed.entries > 0 then
        send("reliquaryFill", { x = self.sq:getX(), y = self.sq:getY(), z = self.sq:getZ(), entries = parsed.entries })
    end
    self:close()
end

function RLFillWindow:onCancel()
    self:close()
end

function RLFillWindow:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

-- ---------------------------------------------------------------------------
-- Simple single-line username prompt (place whitelist + set-access)
-- ---------------------------------------------------------------------------

local function promptUsername(square, command, label, prefill)
    local x = getCore():getScreenWidth() / 2 - 175
    local y = getCore():getScreenHeight() / 2 - 90
    local modal = ISTextBox:new(x, y, 350, 180, label, prefill or "",
        { sq = square, command = command }, function(target, button)
            if button.internal ~= "OK" then return end
            local name = button.parent.entry:getText() or ""
            send(target.command, {
                x = target.sq:getX(), y = target.sq:getY(), z = target.sq:getZ(),
                whitelist = name,
            })
        end, getPlayer():getPlayerNum())
    modal:initialiseAndAddToUIManager()
end

-- ---------------------------------------------------------------------------
-- Context menu (staff with AddItem). The player a Reliquary is addressed to
-- never sees a menu at all - they just open the container like any locker.
-- ---------------------------------------------------------------------------

-- Context-menu callbacks receive option.target as their FIRST arg (square here).
local function openFill(square)
    local win = RLFillWindow:new(square)
    win:initialiseAndAddToUIManager()
end

local function onPreFill(player, context, worldobjects, test)
    if test then return true end
    if not RL.isEnabled() then return end
    local pl = getSpecificPlayer(player)
    if not pl or not RL.mayManage(pl) then return end

    local square, box
    for _, o in ipairs(worldobjects) do
        if o.getSquare and o:getSquare() then square = square or o:getSquare() end
        if RL.getData(o) then box = o end
    end
    if not square then return end

    if box then
        local data = RL.getData(box)
        local sub = context:getNew(context)
        local opt = context:addOptionOnTop("Reliquary", nil, nil)
        context:addSubMenu(opt, sub)
        sub:addOption("Fill...", box:getSquare(), openFill)
        sub:addOption("Set authorized player...", box:getSquare(), function(sq)
            promptUsername(sq, "reliquarySetPlayer",
                "Authorized player (blank = staff only):", data.whitelist or "")
        end)
    else
        context:addOptionOnTop("Place Reliquary here", square, function(sq)
            promptUsername(sq, "reliquaryPlace",
                "Authorized player username (blank = staff only):", "")
        end)
    end
end
Events.OnPreFillWorldObjectContextMenu.Add(onPreFill)

-- ---------------------------------------------------------------------------
-- Loot-UI lockout: hide a Reliquary's container from anyone not authorized, so
-- an unaddressed, non-staff player cannot see (let alone loot) it.
-- ---------------------------------------------------------------------------

if ISInventoryPage and ISInventoryPage.addContainerButton then
    local _origAdd = ISInventoryPage.addContainerButton
    function ISInventoryPage:addContainerButton(container, texture, name, tooltip)
        local parent = container and container.getParent and container:getParent()
        local data = parent and RL.getData(parent)
        if data and not RL.isAuthorized(getSpecificPlayer(self.player), data) then
            return -- skip: container never appears in this player's loot panel
        end
        return _origAdd(self, container, texture, name, tooltip)
    end
end
