-- SPDX-License-Identifier: GPL-3.0-or-later
-- SHServer.lua - authoritative Sticky Headwear reconciliation for multiplayer.
--
-- There is no server-side Lua clothing-change event in 42.20.2. Normal wear and
-- clothing-conversion actions finish in LuaTimedActionNew.complete
-- (LuaTimedActionNew.java:155-160), after IngameState fires OnTick but before the
-- next world update (IngameState.java:1545-1650). Narrow completion hooks close
-- that one-tick fall window. The bounded OnTick pass remains the backstop for
-- login, SyncClothingPacket's direct WornItems mutation (lines 173-223), admin
-- changes, and third-party equip paths without adding another network command.

if not isServer() then return end

require "OEShared"
require "StickyHeadwear/SHAnchor"
require "TimedActions/ISClothingExtraAction"
require "TimedActions/ISWearClothing"
local SH = StickyHeadwear

local active = {}
local announced = false

local function reconcileAfter(original)
    return function(action)
        local completed = original(action)
        if completed then SH.reconcile(action.character) end
        return completed
    end
end

-- Both originals have a single boolean return in 42.20.2. Install once so a
-- server-side Lua reload cannot wrap the same completion path repeatedly.
if not SH.serverHooksInstalled then
    SH.serverHooksInstalled = true
    ISWearClothing.complete = reconcileAfter(ISWearClothing.complete)
    ISClothingExtraAction.complete = reconcileAfter(ISClothingExtraAction.complete)
end

local function reconcilePlayers()
    for player in pairs(active) do active[player] = nil end

    local players = getOnlinePlayers()
    if players then
        for i = 0, players:size() - 1 do
            local player = players:get(i)
            if player then
                active[player] = true
                SH.reconcile(player)
            end
        end
    end
    SH.releaseMissing(active)

    if not announced then
        announced = true
        print("[RFTDOddsAndEnds] Sticky Headwear server authority active; wear actions covered and "
            .. tostring(SH.indexLocations()) .. " fall-capable worn slots indexed.")
    end
end

Events.OnTick.Add(reconcilePlayers)

return SH

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
