-- SPDX-License-Identifier: GPL-3.0-or-later
-- SHClient.lua - local lifecycle for Sticky Headwear.
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
-- it works on a save you have been playing for a month. SHAnchor centralizes
-- that contract; this file only feeds it local lifecycle changes.
--
-- SHAnchor owns the mutation. This runner covers single-player (where this
-- process is authoritative) and keeps the local multiplayer copy consistent;
-- SHServer owns the dedicated server instance that decides helmetFall.

if isServer() then return end

require "OEShared"
require "StickyHeadwear/SHAnchor"
local SH = StickyHeadwear

local lastEnabled = nil

function SH.apply(character)
    local player = character or getPlayer()
    if not player then return end
    SH.reconcile(player)
    lastEnabled = SH.isEnabled()
end

-- Re-apply whenever the worn set can have changed. OnClothingUpdated is the
-- direct signal (vanilla fires it on every equip, unequip and patch job);
-- OnGameStart covers the hat you logged in already wearing, which is the case
-- the script-editing approach can never reach.
Events.OnClothingUpdated.Add(function(character)
    if character ~= getPlayer() then return end
    SH.apply(character)
end)
Events.OnGameStart.Add(SH.apply)

-- LuaEventManager has no sandbox-changed event. Compare the one boolean so a
-- live disable restores pinned instances even if no clothing event follows.
Events.OnTick.Add(function()
    local enabled = SH.isEnabled()
    if lastEnabled == nil then
        lastEnabled = enabled
    elseif enabled ~= lastEnabled then
        SH.apply()
    end
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
