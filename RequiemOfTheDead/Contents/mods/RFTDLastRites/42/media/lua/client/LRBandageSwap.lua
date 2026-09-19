-- SPDX-License-Identifier: GPL-3.0-or-later
-- LRBandageSwap.lua  (client)
--
-- "Replace Bandage" on the Health panel's body-part menu: one pick that takes
-- the old bandage off and puts a fresh one on, where vanilla needs Remove
-- Bandage and then a second trip through the same menu for Bandage.
--
-- NOTHING NEW RUNS ON THE SERVER. The pick queues vanilla's own timed actions -
-- an inventory transfer if the bandage is in a bag, ISApplyBandage with
-- doIt=false, ISApplyBandage with doIt=true - so authority, the per-part
-- manipulating-username lock (ISApplyBandage.lua:44-48, :102) and the
-- syncBodyPart broadcast (:148) are vanilla's, unchanged. Treating another
-- player works the same way vanilla's options do: the panel's doctor/patient
-- split is read exactly as BaseHandler reads it (ISHealthPanel.lua:1137-1143).
--
-- WHY A HealthPanelAction AND NOT A PRE-BUILT CHAIN: the pick queues vanilla's
-- HealthPanelAction (ISHealthPanel.lua:982-1018), whose only contract is
-- handler:isValid(args) and handler:perform(previousAction, args). It runs
-- when the queue reaches it, so the bandage is looked up again at that moment
-- rather than trusted from the moment the menu opened - the player may have
-- dropped it, used it, or walked off from the container since. That is the
-- same guarantee vanilla's own Bandage option gets. Vanilla's BaseHandler
-- itself is file-local (:1020) and is deliberately NOT copied: this object
-- implements the two methods the action calls and nothing more.
--
-- WHY WRAP doBodyPartContextMenu: vanilla builds the menu from a fixed local
-- handler list (:1796-1818) with no registration point. We let it run, then
-- append to the same menu - ISContextMenu.get hands back the player's one
-- reused menu, getPlayerContextMenu(player) (ISContextMenu.lua:1166-1167), so
-- no global needs swapping to reach it.

if isServer() then return end

require "XpSystem/ISUI/ISHealthPanel"

LRBandageSwapState = LRBandageSwapState or { wrapped = false }

-- A dirty bandage applies with zero life (ISApplyBandage.lua:113-115), so
-- swapping one on only trades a dirty bandage for a dirty bandage. Same test
-- the action uses, so the two can never disagree about what "dirty" means.
local function isCleanBandage(item)
    return item:getBandagePower() > 0 and not string.match(item:getType(), "Dirty")
end

-- The doctor's reachable containers plus one level of bags inside them - the
-- same reach as vanilla's BaseHandler:checkItems (ISHealthPanel.lua:1036-1057),
-- which is what decides whether vanilla's own Bandage option can see an item.
local function collectBandages(doctor)
    local out = {}
    local containers = ISInventoryPaneContextMenu.getContainers(doctor)
    if not containers then return out end

    local done = {}
    local function scan(container, children)
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:IsInventoryContainer() then
                if children then children[#children + 1] = item:getInventory() end
            elseif isCleanBandage(item) then
                out[#out + 1] = item
            end
        end
    end

    for i = 0, containers:size() - 1 do
        local container = containers:get(i)
        done[container] = true
        local children = {}
        scan(container, children)
        for _, child in ipairs(children) do
            if not done[child] then
                done[child] = true
                scan(child, nil)
            end
        end
    end
    return out
end

local function firstOfType(items, fullType)
    for _, item in ipairs(items) do
        if item:getFullType() == fullType then return item end
    end
    return nil
end

-- ── the handler HealthPanelAction drives ──────────────────
local Swap = {}
Swap.__index = Swap

function Swap.new(panel, bodyPart)
    return setmetatable({
        panel    = panel,
        bodyPart = bodyPart,
        doctor   = panel.otherPlayer or panel.character,
        patient  = panel.character,
    }, Swap)
end

function Swap:isValid(fullType)
    return self.bodyPart:bandaged()
       and firstOfType(collectBandages(self.doctor), fullType) ~= nil
end

-- Fetch, then strip, then dress: the transfer goes FIRST so the wound is bare
-- only for the length of the apply itself, never while the doctor digs in a bag.
-- perform runs straight after isValid passed on the same tick
-- (HealthPanelAction:update force-completes, :994-996), so the item is there.
function Swap:perform(previousAction, fullType)
    local item = firstOfType(collectBandages(self.doctor), fullType)
    local last = previousAction

    local inventory = self.doctor:getInventory()
    if item:getContainer() ~= inventory then
        local transfer = ISInventoryTransferUtil.newInventoryTransferAction(
            self.doctor, item, item:getContainer(), inventory)
        ISTimedActionQueue.addAfter(last, transfer)
        -- The panel shows a pending action's progress on its body-part row by
        -- looking the queue head up here (ISHealthPanel.lua:601); vanilla's
        -- toPlayerInventory records transfers the same way (:1129-1131).
        self.panel.actions = self.panel.actions or {}
        self.panel.actions[transfer] = self.bodyPart
        last = transfer
    end

    local strip = ISApplyBandage:new(self.doctor, self.patient, nil, self.bodyPart, false)
    ISTimedActionQueue.addAfter(last, strip)
    ISTimedActionQueue.addAfter(strip,
        ISApplyBandage:new(self.doctor, self.patient, item, self.bodyPart, true))
end

function Swap:onPick(fullType)
    ISTimedActionQueue.add(HealthPanelAction:new(self.doctor, self, fullType))
end

-- ── the menu ──────────────────────────────────────────────
local function addReplaceOption(panel, bodyPart, context)
    if not bodyPart:bandaged() then return end

    local swap = Swap.new(panel, bodyPart)

    local types, firstItem = {}, {}
    for _, item in ipairs(collectBandages(swap.doctor)) do
        local fullType = item:getFullType()
        if not firstItem[fullType] then
            firstItem[fullType] = item
            types[#types + 1] = fullType
        end
    end
    if #types == 0 then return end

    local option = context:addOption(getText("IGUI_LR_ReplaceBandage"), nil)
    -- The worn bandage's icon, as vanilla's Remove Bandage shows it (:1204-1210).
    local worn = bodyPart:getBandageType()
    if worn then option.itemForTexture = instanceItem(worn) end

    local subMenu = context:getNew(context)
    context:addSubMenu(option, subMenu)
    for _, fullType in ipairs(types) do
        local item = firstItem[fullType]
        local pick = subMenu:addOption(item:getName(), swap, Swap.onPick, fullType)
        pick.itemForTexture = item
    end
end

if not LRBandageSwapState.wrapped then
    LRBandageSwapState.wrapped = true

    local _origDoBodyPartContextMenu = ISHealthPanel.doBodyPartContextMenu
    function ISHealthPanel:doBodyPartContextMenu(bodyPart, x, y)
        _origDoBodyPartContextMenu(self, bodyPart, x, y)

        -- Same player index vanilla opened the menu for (ISHealthPanel.lua:1797).
        local playerNum = self.otherPlayer and self.otherPlayer:getPlayerNum()
                          or self.character:getPlayerNum()
        local context = getPlayerContextMenu(playerNum)
        -- Vanilla hides the menu when it is empty or the panel is showing a
        -- blocking message (:1873-1875); an option on a hidden menu is a lie.
        if not context or not context:getIsVisible() then return end

        addReplaceOption(self, bodyPart, context)
    end
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
