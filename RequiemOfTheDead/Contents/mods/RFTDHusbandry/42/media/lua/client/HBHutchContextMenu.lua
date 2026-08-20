-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBHutchContextMenu - right-click "Add Hay Bedding" on a hutch.
--
-- Player-facing diegetic path: if you have a HayTuft (gathered from hay), you
-- can pour it into a coop/hutch as bedding. Runs HBAddHayAction, which consumes
-- the hay and asks the server to top up the hutch's bedding charge (HBBedding
-- continuously eats dirt while bedding lasts, then it decays).
--
-- Uses OnPreFillWorldObjectContextMenu, NOT OnFillWorldObjectContextMenu: in
-- B42 the non-pre event is gated (safehouse-interact + Java early-returns) and
-- can be swallowed on claimed buildings. The PRE event fires unconditionally
-- for every world right-click with the same signature. (See Sandman's
-- SMBedAction for the same rationale.)

if isServer() then return end

require "ISUI/ISToolTip"
require "TimedActions/ISTimedActionQueue"
require "HBHayward"

-- A COOP IS NOT ONE TILE, WHICH IS THE WHOLE OF THIS PROBLEM. IsoHutch's
-- constructor walks the def's extraSprites table and spawns a SECOND IsoHutch
-- on each offset square (IsoHutch:110-121), linked back to the first; isSlave()
-- is literally `linkedX > 0 && linkedY > 0` (:827). Only the master carries the
-- animals, the dirt, the nest boxes and the bedding - the slave is a sprite.
--
-- This used to SKIP slaves and look no further, so right-clicking the far half
-- of a two-tile coop resolved to nothing and the Add Hay option never appeared,
-- with nothing on screen to say why. That is the "hay does nothing on that one"
-- report. getHutch (:127) is the engine's own answer: a master hands back
-- itself, a slave follows its link home, so either half now answers the same.
local function masterHutchOf(object)
    if not object or not instanceof(object, "IsoHutch") then return nil end
    -- nil when a slave's linked square is not loaded - the caller keeps looking.
    return object:getHutch()
end

local function masterHutchUnderCursor(worldobjects)
    if not worldobjects then return nil end
    local squares = {}
    for i = 1, #worldobjects do
        local o = worldobjects[i]
        if o then
            local master = masterHutchOf(o)
            if master then return master end
            local sq = o:getSquare()   -- IsoObject:1126, field return
            if sq then squares[sq] = true end
        end
    end
    for sq in pairs(squares) do
        local objs = sq:getObjects()
        if objs then
            for k = 0, objs:size() - 1 do
                local master = masterHutchOf(objs:get(k))
                if master then return master end
            end
        end
    end
    return nil
end

Events.OnPreFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test then return end

    local hutch = masterHutchUnderCursor(worldobjects)
    if not hutch then return end

    local player = getSpecificPlayer(playerNum)
    if not player or player:isDead() then return end

    -- Need hay in inventory to offer the option at all.
    local hay = HBHayward.find(player)
    if not hay then return end

    local max     = (HBBedding and HBBedding.MAX) or 100
    local bedding = (HBBedding and HBBedding.getAmount and HBBedding.getAmount(hutch)) or 0

    local option = context:addOption("Add Hay Bedding", worldobjects, function()
        ISTimedActionQueue.add(HBAddHayAction:new(player, hutch, hay))
    end)

    -- Bedding already full → show it, greyed, so it's discoverable but inert.
    if bedding >= max then
        option.onSelect = nil
        option.notAvailable = true
        local tip = ISToolTip:new()
        tip:setName("Add Hay Bedding")
        tip.description = "Bedding is already full."
        option.toolTip = tip
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
