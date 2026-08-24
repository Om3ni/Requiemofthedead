-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBPartDropClient - client report of watched items dropped to the floor.
--
-- The one lane the server cannot observe: a plain inventory drop travels as
-- AddItemToMapPacket, which the server relays without running any Lua
-- (AddItemToMapPacket.java:59-96 - its OnObjectAdded trigger is in
-- processClient, other people's clients). So this report is client-asserted by
-- construction; the server-observed lanes live in HBPartWatch and this one is
-- corroboration, not authority.
--
-- Hooked at the TRANSFER, not at a context-menu mark: RQD_Menagerie gated its
-- logger on an ISInventoryPaneContextMenu.dropItem mark and then discarded
-- every completed floor transfer that lacked one - drag-and-drop, unequip
-- chains, modded drop paths - which is how it logged 141 events across the
-- server's entire history. Everything that reaches the floor reaches
-- ISInventoryTransferAction:perform.
--
-- Deliberately NOT gated on destContainer:contains() after the fact: on an MP
-- client perform() does not move the item locally - the server does, then
-- syncs (ISInventoryTransferAction.lua:501-503, transaction created at
-- :306-314) - so a contains() test here races the sync and a lost race is a
-- silently missing record, the exact RQD failure shape. A cancelled action
-- never reaches perform(), so the attempt report is right or seconds early,
-- never fabricated.

require "HBParts"
require "TimedActions/ISInventoryTransferAction"

HBPartDropClient = HBPartDropClient or {}

local MAX_ITEMS = 20   -- matches the server's cap in HBPartWatch.onClientReport

local function dropSquare(action)
    -- The floor container knows its square; vanilla reads it the same way
    -- (ISInventoryTransferAction.lua:123). Drops can land one tile adjacent
    -- (getNotFullFloorSquare, :611-631), so the fallback to where the dropper
    -- stands is at worst a tile off - inside any radius query.
    local sq = action.destContainer:getSourceGrid()
    if sq ~= nil then
        return math.floor(sq:getX()), math.floor(sq:getY()), math.floor(sq:getZ())
    end
    local ch = action.character
    return math.floor(ch:getX()), math.floor(ch:getY()), math.floor(ch:getZ())
end

-- The batch this perform() is about to transfer: queueList[1].items, the same
-- slot vanilla consumes (:487), built as {items={...}, time, type} (:739);
-- degenerate actions carry only .item.
local function pendingItems(action)
    local batch = type(action.queueList) == "table" and action.queueList[1] or nil
    if type(batch) == "table" and type(batch.items) == "table" then
        return batch.items
    end
    if action.item ~= nil then return { action.item } end
    return {}
end

local function reportDrops(action, candidates)
    local dest = action.destContainer
    if dest == nil or dest:getType() ~= "floor" then return end
    local rows
    for i = 1, #candidates do
        local item = candidates[i]
        if HBParts.isWatched(item:getFullType()) then
            rows = rows or {}
            if #rows < MAX_ITEMS then
                rows[#rows + 1] = { fullType = item:getFullType(), name = item:getName() }
            end
        end
    end
    if rows == nil then return end
    local x, y, z = dropSquare(action)
    sendClientCommand(action.character, "RFTDHusbandry", HBCmd.PART_PLACED,
        { x = x, y = y, z = z, items = rows })
end

local installed = false

function HBPartDropClient.install()
    if installed then return end
    installed = true
    local original = ISInventoryTransferAction.perform
    ISInventoryTransferAction.perform = function(self)
        -- Captured before: perform consumes queueList[1] (:487). No guard
        -- around the original - if the vanilla transfer throws, nothing landed
        -- on the floor and a report would fabricate; the engine already logs
        -- the throw at throw time (KahluaThread.java:865).
        local candidates = pendingItems(self)
        local result = original(self)
        reportDrops(self, candidates)
        return result
    end
end

-- OnGameStart runs after every mod's load pass, so the chain lands on top of
-- any other mod's perform override instead of underneath it. MP only: in SP
-- there is no server to receive the report and no RDLog to hold it.
Events.OnGameStart.Add(function()
    if isClient() then HBPartDropClient.install() end
end)

return HBPartDropClient

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
