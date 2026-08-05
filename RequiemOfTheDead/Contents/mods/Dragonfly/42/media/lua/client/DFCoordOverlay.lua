-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFCoordOverlay - small always-visible HUD with location and world state.
--
-- Top-left of screen. Shows X/Y/Z, chunk coords, hydro power, temperature.
-- State is cached on a tick counter; reading every frame is wasteful and
-- ChunkAdminControl's overlay (which we cribbed the shape from) was visibly
-- expensive for the same reason. Toggle via DFCoordOverlay.toggle() - the
-- chrome toolbar button calls into this.

if isServer() then return end

require "ISUI/ISPanel"

DFCoordOverlay = ISPanel:derive("DFCoordOverlay")
DFCoordOverlay.instance = nil
DFCoordOverlay.lastX = nil   -- remembered drag position (session)
DFCoordOverlay.lastY = nil

local REFRESH_TICKS = 30
local WIDTH         = 280
local HEIGHT        = 76

function DFCoordOverlay:new(x, y)
    local o = ISPanel:new(x, y, WIDTH, HEIGHT)
    setmetatable(o, self)
    self.__index = self
    o.background      = true
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.55 }
    o.borderColor     = { r = 1, g = 1, b = 1, a = 0.4 }
    o.moveWithMouse   = true   -- drag anywhere on the HUD to reposition it
    o.tick            = 0
    o.cache           = { coord = "X:- Y:- Z:-", chunk = "Chunk:-", status = "World:-" }
    return o
end

local function readState()
    local player = getPlayer()
    if not player then return nil end

    local x, y, z = 0, 0, 0
    pcall(function()
        x = math.floor(player:getX() or 0)
        y = math.floor(player:getY() or 0)
        z = math.floor(player:getZ() or 0)
    end)

    local chunkX, chunkY = math.floor(x / 10), math.floor(y / 10)

    local powerOn
    pcall(function() powerOn = getSandboxOptions():getElecShutModifier() <= 0 end)

    local tempC
    pcall(function()
        local cm = getClimateManager()
        if cm then tempC = cm:getTemperature() end
    end)

    return {
        coord  = string.format("X:%d  Y:%d  Z:%d", x, y, z),
        chunk  = string.format("Chunk: %d, %d", chunkX, chunkY),
        status = string.format("Power: %s  |  Temp: %s",
            (powerOn == nil) and "?" or (powerOn and "ON" or "OFF"),
            tempC and (math.floor(tempC) .. " C") or "?"),
    }
end

function DFCoordOverlay:prerender()
    self.tick = self.tick + 1
    if self.tick >= REFRESH_TICKS then
        self.tick = 0
        local fresh = readState()
        if fresh then self.cache = fresh end
    end

    ISPanel.prerender(self)
    self:drawText("Dragonfly", 10, 6,  0.7, 0.85, 0.95, 1, UIFont.Small)
    self:drawText(self.cache.coord,  10, 22, 1, 1, 1, 1, UIFont.Small)
    self:drawText(self.cache.chunk,  10, 38, 0.85, 0.85, 0.85, 1, UIFont.Small)
    self:drawText(self.cache.status, 10, 54, 0.85, 0.85, 0.85, 1, UIFont.Small)
end

function DFCoordOverlay.open()
    if DFCoordOverlay.instance then
        DFCoordOverlay.instance:setVisible(true)
        DFCoordOverlay.instance:addToUIManager()
        return
    end
    DFCoordOverlay.instance = DFCoordOverlay:new(
        DFCoordOverlay.lastX or 20, DFCoordOverlay.lastY or 100)
    DFCoordOverlay.instance:initialise()
    DFCoordOverlay.instance:addToUIManager()
end

function DFCoordOverlay.close()
    if DFCoordOverlay.instance then
        -- Remember where the admin dragged it so reopening keeps the spot.
        DFCoordOverlay.lastX = DFCoordOverlay.instance:getX()
        DFCoordOverlay.lastY = DFCoordOverlay.instance:getY()
        DFCoordOverlay.instance:removeFromUIManager()
        DFCoordOverlay.instance = nil
    end
end

function DFCoordOverlay.isOpen()
    return DFCoordOverlay.instance ~= nil
        and DFCoordOverlay.instance:getIsVisible()
end

function DFCoordOverlay.toggle()
    if DFCoordOverlay.isOpen() then
        DFCoordOverlay.close()
    else
        DFCoordOverlay.open()
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
