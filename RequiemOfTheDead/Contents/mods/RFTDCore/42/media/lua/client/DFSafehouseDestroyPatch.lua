-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFSafehouseDestroyPatch - folded in from the standalone Ladybug mod (now deprecated).
--
-- Vanilla SledgehammerOnlyInSafehouse rule, as written in ISDestroyCursor, has two
-- problems:
--   1. :create() (the click handler reached via tryBuild) never consults :isValid(),
--      so the safehouse rule colours the cursor but doesn't gate destruction - the
--      original bug griefers exploit.
--   2. Vanilla's intent is "destruction allowed ONLY inside safehouses you belong to" -
--      wild/unclaimed squares paint the cursor red too, blocking destruction-gated loot
--      points in the open world.
--
-- Patch semantic: destruction is blocked only when the target square - or, for
-- walls/doors/windows/door-frames, a cardinal neighbour - is inside a safehouse the
-- player isn't a member of. Open-world and own-safehouse destruction stay allowed and
-- the cursor stays green there.
--
-- In B42 ISDestroyCursor.lua lives in media/lua/server/, not visible during the client
-- load pass on MP connect, so we defer install to OnGameStart once the global exists.

local DEBUG = false -- flip true for verbose [DF-Safehouse] tracing

local function dbg(fmt, ...)
    if not DEBUG then return end
    -- string.format throws on a specifier/argument mismatch; the raw format
    -- string is an acceptable trace line when it does
    local ok, msg = pcall(string.format, fmt, ...)
    print("[DF-Safehouse] " .. (ok and msg or fmt))
end

local BLOCKED_MSG = "Cannot destroy here - safehouse protected."

local function squareDesc(square)
    if not square then return "nil" end
    return string.format("(%d,%d,%d)", square:getX(), square:getY(), square:getZ())
end

local function safehouseBlocks(square, character)
    if not square or not character then return false end
    local safe = SafeHouse.getSafeHouse(square)
    if not safe then return false end
    return not safe:playerAllowed(character)
end

local NEIGHBOUR_DIRS = { IsoDirections.N, IsoDirections.W, IsoDirections.S, IsoDirections.E }

local function selectionIsWallLike(self)
    local obj = self:getObjectList()[self.objectIndex]
    if not obj then return false end
    return instanceof(obj, "IsoWindow")
        or instanceof(obj, "IsoDoor")
        or self:_isWall(obj)
        or self:_isDoorFrame(obj)
end

local function findBlockingSquare(self, square, character, includeNeighbours)
    if safehouseBlocks(square, character) then return square end
    if includeNeighbours then
        for i = 1, #NEIGHBOUR_DIRS do
            local n = square:getAdjacentSquare(NEIGHBOUR_DIRS[i])
            if safehouseBlocks(n, character) then return n end
        end
    end
    return nil
end

local function notify(character)
    if HaloTextHelper and HaloTextHelper.addBadText then
        HaloTextHelper.addBadText(character, BLOCKED_MSG)
    end
end

local function ruleActive(self)
    return not self.dismantle
        and isClient()
        and not isAdmin()
        and getServerOptions():getBoolean("SledgehammerOnlyInSafehouse")
end

local hooksInstalled = false
local lastOverrideKey = nil

local function installHooks()
    if hooksInstalled then return end
    if not ISDestroyCursor then
        dbg("installHooks: ISDestroyCursor still nil - aborting")
        return
    end
    hooksInstalled = true

    local origIsValid = ISDestroyCursor.isValid
    function ISDestroyCursor:isValid(square)
        if not ruleActive(self) or not square then
            return origIsValid(self, square)
        end
        local blocker = findBlockingSquare(self, square, self.character, selectionIsWallLike(self))
        if blocker then
            local key = squareDesc(square) .. "->" .. squareDesc(blocker)
            if key ~= lastOverrideKey then
                lastOverrideKey = key
                dbg("isValid blocked: hovered=%s blocked-by=%s", squareDesc(square), squareDesc(blocker))
            end
            return false
        end
        lastOverrideKey = nil
        self.renderX = square:getX()
        self.renderY = square:getY()
        self.renderZ = square:getZ()
        return #self:getObjectList() > 0
    end

    local origCreate = ISDestroyCursor.create
    function ISDestroyCursor:create(x, y, z, north, sprite)
        if not ruleActive(self) then
            return origCreate(self, x, y, z, north, sprite)
        end
        local target = getCell():getGridSquare(x, y, z)
        if not target then
            return origCreate(self, x, y, z, north, sprite)
        end
        local blocker = findBlockingSquare(self, target, self.character, selectionIsWallLike(self))
        if blocker then
            dbg("create() BLOCKED hovered=%s blocked-by=%s", squareDesc(target), squareDesc(blocker))
            notify(self.character)
            return
        end
        return origCreate(self, x, y, z, north, sprite)
    end
end

if ISDestroyCursor then
    installHooks()
else
    Events.OnGameStart.Add(installHooks)
end

-- Admin-panel status badge (native now - Dragonfly owns this fix).
Events.OnGameStart.Add(function()
    if DFRegistry and DFRegistry.registerStatusBadge then
        DFRegistry.registerStatusBadge{
            id   = "safehouseDestroyFix",
            text = "Safehouse-destroy anti-grief patch active",
        }
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
