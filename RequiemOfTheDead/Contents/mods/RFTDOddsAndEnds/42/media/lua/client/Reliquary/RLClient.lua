-- RLClient.lua - Reliquary: client UI (item placement, management menu, lockout).
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

-- The Reliquary item awaiting the server's verdict on its placement.
-- Declared up here because the Result listener below consumes it.
local pendingPlacement

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= OEShared.MODULE or command ~= "Result" then return end
    args = args or {}
    if args.ok then
        -- The item is spent only now, on the server's word. A refused
        -- placement (bad square, one already there) leaves it in the bag.
        if args.action == "reliquaryPlace" and pendingPlacement then
            pcall(function()
                getPlayer():getInventory():Remove(pendingPlacement)
            end)
            pendingPlacement = nil
        end
        if args.message then DFFeedback.good(args.message) end
    else
        if args.action == "reliquaryPlace" then pendingPlacement = nil end
        DFFeedback.bad(args.reason or ("Action failed: " .. tostring(args.action or "?")))
    end
end)

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
    -- initialise() then addToUIManager(), NOT initialiseAndAddToUIManager():
    -- that convenience method does not exist anywhere in 42.20's UI classes.
    -- It was in the pre-migration BoonBox code and threw "Object tried to call
    -- nil" the first time this dialog was ever actually opened.
    modal:initialise()
    modal:addToUIManager()
end

-- Same shape as promptUsername, restricted to digits. The value travels as
-- `hours`, so the server never has to parse free text.
local function promptNumber(square, command, label, prefill)
    local x = getCore():getScreenWidth() / 2 - 175
    local y = getCore():getScreenHeight() / 2 - 90
    local modal = ISTextBox:new(x, y, 350, 180, label, prefill or "0",
        { sq = square, command = command }, function(target, button)
            if button.internal ~= "OK" then return end
            send(target.command, {
                x = target.sq:getX(), y = target.sq:getY(), z = target.sq:getZ(),
                hours = tonumber(button.parent.entry:getText()) or 0,
            })
        end, getPlayer():getPlayerNum())
    modal:initialise()
    modal:setOnlyNumbers(true)
    modal:addToUIManager()
end

-- ---------------------------------------------------------------------------
-- Context menu (staff with AddItem). The player a Reliquary is addressed to
-- never sees a menu at all - they just open the container like any locker.
--
-- PLACEMENT IS NOT HERE, deliberately (owner decision, 2026-07-30, before the
-- first Workshop push). A "Place Reliquary here" option on every square staff
-- right-clicked made placement something you could do by accident, on the
-- wrong tile, mid-conversation. A Reliquary is a deliberate act - a handover
-- to a named player - so it should be a deliberate object: spawned as an item
-- and placed on purpose.
--
-- Placement lives further down, on the ITEM's inventory menu. What is here is
-- management of a Reliquary that already exists: fill it, re-address it, set
-- how long it waits. Do not "restore" a world-menu placement option.
-- ---------------------------------------------------------------------------

-- Context-menu callbacks receive option.target as their FIRST arg (square here).
local function openFill(square)
    RLSpawner.open(square)
end

local function onPreFill(player, context, worldobjects, test)
    if test then return true end
    if not RL.isEnabled() then return end
    local pl = getSpecificPlayer(player)
    if not pl or not RL.mayManage(pl) then return end

    -- Only ever offers anything when the clicked square already HOLDS one.
    -- A square without a Reliquary gets no option at all.
    local box
    for _, o in ipairs(worldobjects) do
        if RL.getData(o) then box = o end
    end
    if not box then return end

    local data = RL.getData(box)
    local sub = context:getNew(context)
    local opt = context:addOptionOnTop("Reliquary", nil, nil)
    context:addSubMenu(opt, sub)
    sub:addOption("Fill...", box:getSquare(), openFill)
    sub:addOption("Set authorized player...", box:getSquare(), function(sq)
        promptUsername(sq, "reliquarySetPlayer",
            "Authorized player (blank = staff only):", data.whitelist or "")
    end)
    sub:addOption("Set timer...", box:getSquare(), function(sq)
        promptNumber(sq, "reliquarySetTimer",
            "Hours until it expires (0 = never):", tostring(RL.defaultHours()))
    end)
end
Events.OnPreFillWorldObjectContextMenu.Add(onPreFill)

-- ---------------------------------------------------------------------------
-- Placing one, from the item
--
-- The item IS the deliberateness. A Reliquary cannot appear because someone
-- right-clicked the wrong tile; it appears because staff spawned an object,
-- carried it, and chose where it goes and who it is for.
--
-- The item is destroyed CLIENT-SIDE ON THE SERVER'S OK, never optimistically.
-- Placement can legitimately fail - an invalid square, or a Reliquary already
-- on that tile - and losing the item to a refused placement would be the worst
-- possible outcome of an admin misclick.
-- ---------------------------------------------------------------------------

local function placeFromItem(item)
    local playerObj = getPlayer()
    if not playerObj then return end
    local sq = playerObj:getCurrentSquare()
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()

    local px = getCore():getScreenWidth() / 2 - 175
    local py = getCore():getScreenHeight() / 2 - 90
    local modal = ISTextBox:new(px, py, 350, 180,
        "Who is this Reliquary for? (blank = staff only):", "",
        nil, function(_, button)
            if button.internal ~= "OK" then return end
            pendingPlacement = item
            RDNet.send(OEShared.MODULE, "reliquaryPlace", {
                x = x, y = y, z = z,
                whitelist = button.parent.entry:getText() or "",
                hours = RL.defaultHours(),
            })
        end, getPlayer():getPlayerNum())
    modal:initialise()
    modal:addToUIManager()
end

local function onFillInventoryMenu(player, context, items)
    if not RL.isEnabled() then return end
    local playerObj = getSpecificPlayer(player)
    if not playerObj or not RL.mayManage(playerObj) then return end

    for _, entry in ipairs(items) do
        local item = (type(entry) == "table" and entry.items and entry.items[1]) or entry
        local ok, isReliquary = pcall(function() return item:getFullType() == RL.ITEM end)
        if ok and isReliquary then
            context:addOptionOnTop("Place Reliquary here", item, placeFromItem)
            return
        end
    end
end
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryMenu)

-- ---------------------------------------------------------------------------
-- No moving it. The server destroys any Reliquary that changes tile, which is
-- the rule; this is the courtesy that stops staff triggering it by accident.
-- ---------------------------------------------------------------------------

if ISMoveableSpriteProps and ISMoveableSpriteProps.canPickUpMoveable then
    local _origCanPickUp = ISMoveableSpriteProps.canPickUpMoveable
    function ISMoveableSpriteProps:canPickUpMoveable(character, square, object)
        if object and RL.getData(object) then return false end
        return _origCanPickUp(self, character, square, object)
    end
end

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
