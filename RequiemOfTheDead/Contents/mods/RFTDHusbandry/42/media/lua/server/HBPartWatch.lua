-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBPartWatch - server record of animal parts entering the world.
--
-- WHY: the engine's item log is one-sided. Picking a world item UP writes
-- "floor -1" (RemoveItemFromSquarePacket.java:124); nothing anywhere writes a
-- "floor +1". A plain client drop travels as AddItemToMapPacket, which the
-- server relays without logging, and whose only Lua event trigger sits in
-- processClient - it fires on OTHER clients, never on the server
-- (AddItemToMapPacket.java:59-96, sole OnObjectAdded trigger site :90). So the
-- server could see who removed a planted head, never who planted it. This file
-- closes that for the four lanes the server itself executes, and receives the
-- client's report for the one it cannot see.
--
-- The four server lanes are NetTimedAction complete() bodies - the server runs
-- them, a modified client cannot suppress them. Mechanism pinned by the
-- 2026-08-21 crash trace: zombie.core.NetTimedAction.perform ->
-- Lua(Vanilla).complete(ISDropAnimalCorpseAndThen.lua:56).
--
--   corpse_drop  ISDropAnimalCorpseAndThen:complete
--                (shared/TimedActions/Animals/, :54-76)
--   place_item   ISDropWorldItemAction:complete - the B42 "Place Item" cursor,
--                the deliberate-arrangement lane; constructed only by
--                ISPlace3DItemCursor (:30, :41)
--                (shared/TimedActions/ISDropWorldItemAction.lua:49-113)
--   hook_hang    ISPutAnimalOnHook:complete (:65-94) - a body onto a butcher
--                hook
--   hook_remove  ISRemoveAnimalFromHook:complete (:62-76) - unhooking stands
--                a corpse back onto the ground at the hook
--                (ButcheringUtil.onRemoveCorpseFromHook, :585-610)
--   item_drop    client-asserted, sent by HBPartDropClient and registered on
--                RDNet by HBCommands, which gates and rate-limits it before
--                onClientReport below ever runs

if not isServer() then return end

require "HBParts"
require "RDLog"
require "TimedActions/Animals/ISDropAnimalCorpseAndThen"
require "TimedActions/ISDropWorldItemAction"
require "TimedActions/Animals/ISPutAnimalOnHook"
require "TimedActions/Animals/ISRemoveAnimalFromHook"

HBPartWatch = HBPartWatch or {}

local forensic = RDLog.channel(HBParts.STREAM, HBParts.MODULE)

local function squarePos(sq)
    return math.floor(sq:getX()), math.floor(sq:getY()), math.floor(sq:getZ())
end

-- Chained override of a NetTimedAction complete(). snapshot(self) runs FIRST
-- because corpse_drop's original consumes the item (inventory Remove then
-- tryAddCorpseToWorld, ISDropAnimalCorpseAndThen.lua:55-57); it returns the
-- payload, or nil to skip the lane. Recording is skipped when the original
-- REFUSES (returns false - the hook lanes decline a contested hook without
-- changing the world, ISPutAnimalOnHook.lua:66-80).
--
-- The pcall is a foreign-Lua chain boundary: complete() is vanilla Lua, the
-- lane that genuinely throws - this exact body did on 2026-08-21 - and a throw
-- mid-complete may have half-executed the placement. The record must survive
-- the throw (stamped fault=true) and the throw must survive us: inspect,
-- record, rethrow.
local function hookComplete(class, snapshot)
    local original = class.complete
    class.complete = function(self)
        local payload = snapshot(self)
        local ok, result = pcall(original, self)
        if payload and (not ok or result ~= false) then
            if not ok then payload.fault = true end
            forensic(HBParts.EVENT, self.character, payload)
        end
        if not ok then error(result, 0) end
        return result
    end
end

-- ---- server-observed snapshots --------------------------------------------
-- Field reads are bare on purpose: every receiver below is one the vanilla
-- complete() itself dereferences unguarded (item via isValid's contains,
-- sq at ISDropWorldItemAction.lua:81, hook/body at ISPutAnimalOnHook.lua:66-88,
-- body via isValid at ISRemoveAnimalFromHook.lua:10), so the preconditions are
-- established before we run and a broken one should throw loudly, not vanish.

local function snapCorpseDrop(self)
    local fullType = self.item:getFullType()
    if not HBParts.isWatched(fullType) then return nil end
    local ch = self.character
    return {
        path = "corpse_drop", fullType = fullType, name = self.item:getName(),
        x = math.floor(ch:getX()), y = math.floor(ch:getY()),
        z = math.floor(ch:getZ()),
    }
end

local function snapPlaceItem(self)
    -- Pre-swap read is fine: the only mid-complete rebind of self.item is the
    -- lit-candle/lantern swap (ISDropWorldItemAction.lua:50-79), and no
    -- watched part is a lit candle.
    local fullType = self.item:getFullType()
    if not HBParts.isWatched(fullType) then return nil end
    local x, y, z = squarePos(self.sq)
    return {
        path = "place_item", fullType = fullType, name = self.item:getName(),
        x = x, y = y, z = z,
    }
end

local function snapHookHang(self)
    -- Every body a hook takes is animal materiel; no watchlist filter.
    -- The body is an IsoDeadBody from the ground, the hanging IsoAnimal, or an
    -- inventory corpse item - the same three shapes vanilla dispatches on
    -- (ButcheringUtil.createCorpseFromItem, :551-557). All three carry the
    -- animal in modData (:560-570).
    local x, y, z = squarePos(self.hook:getSquare())
    local body = self.body
    local md = body:getModData()
    local p = {
        path = "hook_hang", x = x, y = y, z = z,
        animalType = md.AnimalType, breed = md.AnimalBreed,
    }
    if not (instanceof(body, "IsoDeadBody") or instanceof(body, "IsoAnimal")) then
        p.fullType = body:getFullType()   -- the inventory-item lane
    end
    return p
end

local function snapHookRemove(self)
    local x, y, z = squarePos(self.hook:getSquare())
    return {
        path = "hook_remove", x = x, y = y, z = z,
        -- def key like "doewhitetailed"; vanilla reads it on this exact
        -- receiver (ISRemoveAnimalFromHook.lua:100)
        animal = self.body:getTypeAndBreed(),
    }
end

-- ---- client report intake --------------------------------------------------

-- One perform() transfers one queueList batch; vanilla bulk-merges at 20 per
-- type (ISInventoryTransferAction.lua:724-739), so 20 is the honest ceiling.
local MAX_ITEMS = 20
local MAX_STR   = 80

local function cleanString(s)
    if type(s) ~= "string" then return nil end
    if #s > MAX_STR then return string.sub(s, 1, MAX_STR) end
    return s
end

-- args off the wire, untrusted (CLAUDE.md sect. 13): shape and coordinates
-- bounded, every row re-checked against the watchlist so a forged report can
-- only say something a real drop could have said. The coordinates remain the
-- client's claim about itself - that is what item_drop MEANS; the four lanes
-- above are the server-observed ones, and Guardian holds the raw command if a
-- record is ever doubted. Refusals print (bounded by the rate window) rather
-- than vanish.
--
-- THE RATE LIMIT IS NOT HERE ANY MORE (2026-08-25). It was written inline
-- because this command entered through Husbandry's legacy OnClientCommand
-- dispatcher, which had no per-command limiter of its own. The token now goes
-- through RDNet, whose bucket is already scoped to (token, command) and
-- carries the same 4/sec on the registration (HBCommands.lua). Keeping both
-- would have been two limiters draining on the same traffic - the exact shape
-- RDRate.allow's own header warns about - so the surviving one is the
-- declared, greppable one next to the capability decision.
function HBPartWatch.onClientReport(player, args)
    if type(args) ~= "table" or type(args.items) ~= "table" then
        print("[HB] PART_PLACED: refused malformed report from "
            .. tostring(player and player:getUsername()))
        return
    end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not (x and y and z) then
        print("[HB] PART_PLACED: refused non-numeric location from "
            .. tostring(player and player:getUsername()))
        return
    end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    if x < 0 or x > 100000 or y < 0 or y > 100000 or z < -32 or z > 32 then
        print("[HB] PART_PLACED: refused out-of-world location from "
            .. tostring(player and player:getUsername()))
        return
    end
    local accepted = 0
    for i = 1, #args.items do
        if accepted >= MAX_ITEMS then break end
        local row = args.items[i]
        local fullType = type(row) == "table" and cleanString(row.fullType) or nil
        if fullType and HBParts.isWatched(fullType) then
            accepted = accepted + 1
            forensic(HBParts.EVENT, player, {
                path = "item_drop", fullType = fullType,
                name = cleanString(row.name),
                x = x, y = y, z = z,
            })
        end
    end
end

-- ---- install ---------------------------------------------------------------

local installed = false

function HBPartWatch.install()
    if installed then return end
    installed = true
    hookComplete(ISDropAnimalCorpseAndThen, snapCorpseDrop)
    hookComplete(ISDropWorldItemAction,     snapPlaceItem)
    hookComplete(ISPutAnimalOnHook,         snapHookHang)
    hookComplete(ISRemoveAnimalFromHook,    snapHookRemove)
    print("[HB] part watch installed (corpse_drop, place_item, hook_hang, hook_remove)")
end

-- After every mod's load pass (GameServer.java:1446), so the chain lands on
-- top of any other mod's complete() override rather than underneath it. No
-- pcall wrapper: listeners are already isolated per-listener by the engine
-- (Event.java:53-63), and an install fault should be loud.
Events.OnServerStarted.Add(HBPartWatch.install)

return HBPartWatch

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
