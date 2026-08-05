-- SPDX-License-Identifier: GPL-3.0-or-later
-- SHClient.lua - Sticky Headwear: your hat stays on your head.
--
-- Vanilla knocks headwear off when you take a hit. This pins it, and does so
-- on the WORN ITEM rather than the item script - which is the whole design
-- argument, so it is worth spelling out.
--
-- chanceToFall is read from two entirely different places in 42.20:
--
--   * IsoGameCharacter.java:7552-7556 reads it off the Clothing INSTANCE:
--         int chanceToFall = clothing.getChanceToFall();
--         if (clothing.getChanceToFall() <= 0 || Rand.Next(100) > chanceToFall) continue;
--     That is the one that decides whether the hat on your head comes off.
--
--   * IsoZombie.java:4934 and PersistentOutfits.java:314 read it off the
--     SCRIPT item, to decide which clothing a spawning zombie is MISSING.
--
-- The common approach - walk getAllItems() and DoParam("ChanceToFall = 0") -
-- edits the script table, so it hits the second path as well as the first.
-- Zombies then spawn with their headwear intact, every time, changing both the
-- look of a horde and the amount of loot on it. Nobody asks for that when they
-- ask for their hat to stay on. It also cannot help the hat you are ALREADY
-- wearing, because the instance took its copy of the value at creation
-- (Item.java:1626) and a later script edit never reaches it.
--
-- So this touches instances only. Precise, reversible within the session, and
-- it works on a save you have been playing for a month. The cost is that it
-- must be re-applied when the worn set changes, which is what the event hooks
-- below are for - cheap, since it only ever walks what one character wears.
--
-- Client-side by nature: the check at IsoGameCharacter:7552 runs against the
-- character's own worn items, and each client owns its player. Nothing here
-- needs the server, and nothing here trusts another client.

if isServer() then return end

require "OEShared"

StickyHeadwear = StickyHeadwear or {}
local SH = StickyHeadwear

function SH.isEnabled()
    return OEShared.enabled("StickyHeadwearEnable")
end

-- Remember what each item's chance WAS, so switching the sandbox option off
-- mid-session restores the vanilla value instead of leaving everything pinned
-- until a restart. Keyed by item id; weak-valued so dropped items do not hold
-- their own memory open.
SH.original = SH.original or {}

-- getChanceToFall/setChanceToFall live on Clothing (Clothing.java:872), and a
-- worn slot can hold something that is not Clothing. Test for the METHOD
-- before calling rather than letting pcall catch the miss: a caught error is
-- still an error to the engine, and PZ's poller logged one per non-clothing
-- worn item on every clothing change - a wall of "Tried to call nil" from code
-- that was technically working.
local function chanceOf(item)
    if not item or not item.getChanceToFall then return nil end
    local ok, chance = pcall(function() return item:getChanceToFall() end)
    if not ok or type(chance) ~= "number" then return nil end
    return chance
end

local function pin(item)
    local chance = chanceOf(item)
    if not chance or chance <= 0 then return end   -- already sticky, or no such behaviour
    if not item.setChanceToFall then return end
    local id = item:getID()
    if SH.original[id] == nil then SH.original[id] = chance end
    pcall(function() item:setChanceToFall(0) end)
end

local function unpin(item)
    if not item or not item.setChanceToFall then return end
    local id = item:getID()
    local was = SH.original[id]
    if was == nil then return end
    pcall(function() item:setChanceToFall(was) end)
    SH.original[id] = nil
end

-- Walk what the character is wearing. In vanilla, chanceToFall is only set on
-- head and face items, so filtering by "is it headwear" would just be a second
-- guess at the same set - a nonzero chance to fall IS the definition of the
-- thing this module is for, including anything modded that opts in.
local function sweep(character, apply)
    if not character then return end
    local ok, worn = pcall(function() return character:getWornItems() end)
    if not ok or not worn then return end
    for i = 0, worn:size() - 1 do
        local entry = worn:get(i)
        local item = entry and entry.getItem and entry:getItem()
        if item then apply(item) end
    end
end

function SH.apply()
    local player = getPlayer()
    if not player then return end
    if SH.isEnabled() then
        sweep(player, pin)
    else
        sweep(player, unpin)
    end
end

-- Re-apply whenever the worn set can have changed. OnClothingUpdated is the
-- direct signal (vanilla fires it on every equip, unequip and patch job);
-- OnGameStart covers the hat you logged in already wearing, which is the case
-- the script-editing approach can never reach.
Events.OnClothingUpdated.Add(function(character)
    if character ~= getPlayer() then return end
    SH.apply()
end)
Events.OnGameStart.Add(SH.apply)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
