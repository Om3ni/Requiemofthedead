-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBAddHayAction - player times action: pour one HayTuft into a hutch as
-- bedding. Consumes the hay item on completion (client-side, the standard PZ
-- inventory path) and tells the server to top up the hutch's bedding charge
-- via HBCmd.ADD_BEDDING. Mirrors STA Better Hutches' "add woodchips" action.

require "TimedActions/ISBaseTimedAction"

HBAddHayAction = ISBaseTimedAction:derive("HBAddHayAction")

function HBAddHayAction:isValid()
    return self.hutch ~= nil
        and self.item ~= nil
        and self.character:getInventory():contains(self.item)
end

function HBAddHayAction:waitToStart()
    self.character:faceThisObject(self.hutch)
    return self.character:shouldBeTurning()
end

function HBAddHayAction:update()
    self.character:faceThisObject(self.hutch)
    self.item:setJobDelta(self:getJobDelta())
end

function HBAddHayAction:start()
    self.item:setJobType("Adding bedding")
    self.item:setJobDelta(0.0)
end

function HBAddHayAction:stop()
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.stop(self)
end

function HBAddHayAction:perform()
    self.item:setJobDelta(0.0)
    ISBaseTimedAction.perform(self)
end

function HBAddHayAction:complete()
    -- Consume one hay (client inventory; replicated the standard way).
    local inv = self.character:getInventory()
    sendRemoveItemFromContainer(inv, self.item)
    inv:Remove(self.item)

    -- Server tops up the hutch's bedding charge (server-authoritative write).
    local sq
    pcall(function() sq = self.hutch:getSquare() end)
    if sq then
        sendClientCommand(self.character, "RFTDHusbandry", HBCmd.ADD_BEDDING,
            { x = sq:getX(), y = sq:getY(), z = sq:getZ() })
    end
    return true
end

function HBAddHayAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 120
end

function HBAddHayAction:new(character, hutch, item)
    local o = ISBaseTimedAction.new(self, character)
    o.hutch      = hutch
    o.item       = item
    o.maxTime    = o:getDuration()
    o.stopOnWalk = true
    o.stopOnRun  = true
    return o
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
