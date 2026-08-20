-- SPDX-License-Identifier: GPL-3.0-or-later
-- LJWeight.lua - Lumberjack: wooden things weigh what you decide they weigh.
--
-- Hauling building material is the complaint. A Log is 9.0 and a Plank 3.0, so
-- a load of timber is most of an inventory before you carry anything useful.
-- This scales that, per sandbox dial.
--
-- WHAT IT EDITS, AND WHY THAT IS ENOUGH. Weight lives on the item INSTANCE
-- (InventoryItem.actualWeight, a plain field) and is copied from the script
-- item at creation - Item.java:1842, `item.setActualWeight(this.actualWeight)`.
-- The obvious worry is that a script edit therefore cannot reach the logs
-- already sitting in a save. It can: `actualWeight` appears in InventoryItem
-- exactly three times - the field, the getter, the setter - and in NEITHER
-- save() nor load(). It is not serialised. Saved items are rebuilt from the
-- script on load, so they pick up the new value at the next world load, and
-- there is no need to walk containers fixing instances up. That was worth
-- proving before writing a sweeper that would have done nothing.
--
-- IDEMPOTENT, WHICH THE OBVIOUS IMPLEMENTATION IS NOT. The tempting version
-- reads the item's CURRENT weight, multiplies, and writes it back. Fire that
-- twice and the weights compound - and it does fire twice, because a player
-- who returns to the main menu and rejoins without quitting the process keeps
-- the same ScriptManager while the world-load events run again. So originals
-- are captured once, and every application recomputes from the ORIGINAL. Any
-- number of runs converge on the same answer.
--
-- Because the originals are kept, the dial is also reversible: set it back to
-- 1.0, or switch the module off, and the vanilla weights return exactly - no
-- drift, no restart.
--
-- SCOPE IS DELIBERATELY NARROW. There is no engine-side "this is wood": items
-- carry Material = Glass or Metal and nothing else, and the makewoodcharcoal
-- tags reach about twenty items. So identification has to be a list, and a
-- 200-name list of every wooden object in the game is a maintenance burden
-- that mostly exists to make baseball bats lighter. The bulk set below is the
-- material you actually haul; the charcoal-tagged set is everything the game
-- itself agrees is burnable wood, which modded items opt into for free.
-- Widening it is adding names to BULK - the machinery does not care how long
-- the list is.
--
-- Runs on both sides: each process has its own ScriptManager, so the client
-- and the server must each scale their own copy or the weights disagree.

require "OEShared"

Lumberjack = Lumberjack or {}
local LJ = Lumberjack

-- Original actual weights, by item full name. Captured on first touch and
-- never overwritten - this table is the only reason repeat runs are safe.
LJ.original = LJ.original or {}

-- The haul: what fills an inventory when you are building. Names verified
-- against the 42.20 scripts.
LJ.BULK = {
    "Base.Log", "Base.LogStacks", "Base.Plank",
    "Base.Firewood", "Base.FirewoodBundle", "Base.Twigs",
}

-- Everything the game itself calls burnable wood. Tag-derived rather than
-- listed, so a mod that tags its own timber is covered without us knowing it
-- exists.
LJ.WOOD_TAGS = {
    "makewoodcharcoalsmall", "makewoodcharcoalmedium", "makewoodcharcoallarge",
    "log",
}

function LJ.isEnabled()
    return OEShared.enabled("LumberjackEnable")
end

local function dial(name, fallback)
    local sv = SandboxVars and SandboxVars.RFTDOddsAndEnds
    local v = sv and tonumber(sv[name])
    -- The declared custom-double contract is 0.05..5.0. Validate it here as
    -- well: DoubleConfigOption rejects ordinary out-of-range values but its
    -- comparisons do not reject NaN (DoubleConfigOption.java:95-105).
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge
        or v < 0.05 or v > 5.0 then
        return fallback
    end
    return v
end

-- Two decimals, without depending on the `round` global in env.lua. Weight is
-- displayed to one or two places, so more precision is noise that only makes
-- the numbers look untidy in a tooltip.
local function round2(v)
    return math.floor(v * 100 + 0.5) / 100
end

-- ItemTag and ResourceLocation are exported to Lua in 42.20.2. These fixed,
-- non-empty identifiers cannot fail ResourceLocation.of (ResourceLocation.java:
-- 29-37), while ItemTag.get is one registry map lookup that returns nil for a
-- missing tag (ItemTag.java:478-480; Registry.java:46-48). Item:getTags()
-- remains a Java Set Kahlua cannot iterate, so hasTag with a resolved tag is
-- the correct route.
local tagCache = {}
local function tagFor(name)
    if tagCache[name] ~= nil then return tagCache[name] or nil end
    local tag = ItemTag.get(ResourceLocation.of("base:" .. name))
    tagCache[name] = tag or false
    return tagCache[name] or nil
end

local function isTaggedWood(item)
    for _, name in ipairs(LJ.WOOD_TAGS) do
        local tag = tagFor(name)
        if tag and item:hasTag(tag) then return true end
    end
    return false
end

-- Resolve the two groups to script items. Rebuilt per application rather than
-- cached: cheap next to the pass itself, and it means a mod loaded later is
-- picked up without a special case.
local function targets()
    local sm = getScriptManager()
    if not sm then return {}, {} end
    local bulk, other = {}, {}

    local bulkSet = {}
    for _, full in ipairs(LJ.BULK) do
        local item = sm:getItem(full)
        if item then
            table.insert(bulk, item)
            bulkSet[full] = true
        end
    end

    local all = sm:getAllItems()
    if all then
        for i = 0, all:size() - 1 do
            local item = all:get(i)
            local full = item and item:getFullName()
            if full and not bulkSet[full] and isTaggedWood(item) then
                table.insert(other, item)
            end
        end
    end
    return bulk, other
end

local function scale(item, factor)
    local full = item:getFullName()
    if not full then return end

    if LJ.original[full] == nil then
        local w = item:getActualWeight()
        if type(w) ~= "number" or w ~= w or w == math.huge or w == -math.huge then return end
        LJ.original[full] = w
    end

    local target = round2(LJ.original[full] * factor)
    -- A valid Item script weight is a finite float. The validated dial above
    -- and current float source make this a deterministic Weight parameter:
    -- setActualWeight clamps/writes a field (Item.java:563-568), and DoParam's
    -- exact Weight branch only Float.parseFloats this finite value (Item.java:
    -- 1929-1942, 2099-2104). No exception boundary has useful recovery here.
    if target ~= target or target == math.huge or target == -math.huge
        or target > 3.4028235e38 then
        return
    end
    item:setActualWeight(target)
    -- Both paths: setActualWeight moves the field the instance copies, DoParam
    -- keeps the script's own Weight parameter in step so later script readers
    -- see the same number.
    item:DoParam("Weight = " .. tostring(target))
end

function LJ.apply()
    local on = LJ.isEnabled()
    local bulkFactor  = on and dial("LumberjackBulkWeight", 1.0) or 1.0
    local otherFactor = on and dial("LumberjackWoodWeight", 1.0) or 1.0

    local bulk, other = targets()
    for _, item in ipairs(bulk) do scale(item, bulkFactor) end
    for _, item in ipairs(other) do scale(item, otherFactor) end

    print("[RFTDOddsAndEnds] Lumberjack applied (" .. (isServer() and "server" or "client/SP")
        .. "; bulk x" .. tostring(bulkFactor) .. " over " .. tostring(#bulk)
        .. ", wood x" .. tostring(otherFactor) .. " over " .. tostring(#other) .. ").")
end

-- Same timing as ActionSpeed, and for the same reason: SandboxVars do not
-- exist at OnGameBoot, so the earliest honest moment is world load. Firing on
-- both is safe here by construction.
Events.OnGameStart.Add(LJ.apply)
if isServer() then
    Events.OnServerStarted.Add(LJ.apply)
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
