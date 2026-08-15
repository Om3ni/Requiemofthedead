-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFZombiesTab_Server - handlers for the basic Zombies tab actions.
--
-- Same capability gate Reaper would use later (ChangeWeather as a stand-in
-- admin proxy until we wire a dedicated cap). All three actions use the
-- same loaded-zombie iteration: walk every online player's cell, dedupe by
-- OnlineID. Lifted from Reaper's RPCore.forEachLoadedZombie pattern - kept
-- inline here so Dragonfly doesn't need Reaper to function.

if not isServer() then return end

local CAP = Capability.ChangeWeather

local function isValidId(id) return id and id ~= 0 and id ~= -1 end

local function forEachLoadedZombie(visitor)
    -- Snapshot into a plain Lua array BEFORE visiting. The visitor often culls,
    -- which mutates the cell's zombie list mid-iteration and corrupts indices
    -- (IndexOutOfBoundsException from java.util.ArrayList). Snapshot dodges it.
    local players = getOnlinePlayers()
    if not players then return end
    local seen, snapshot = {}, {}
    for pi = 0, players:size() - 1 do
        local p = players:get(pi)
        if p then
            local cell = p:getCell()
            if cell then
                local zlist = cell:getZombieList()
                if zlist then
                    local n = zlist:size()
                    for zi = 0, n - 1 do
                        local z = zlist:get(zi)
                        if z then
                            local id = z:getOnlineID()
                            if isValidId(id) and not seen[id] then
                                seen[id] = true
                                snapshot[#snapshot + 1] = { z = z, id = id }
                            end
                        end
                    end
                end
            end
        end
    end
    for i = 1, #snapshot do
        -- pcall: visitor containment - one zombie's error must not abort the
        -- rest of the snapshot walk mid-cull.
        local ok, err = pcall(visitor, snapshot[i].z, snapshot[i].id)
        if not ok then print("[Dragonfly] visitor error: " .. tostring(err)) end
    end
end

-- Same three-step removal Reaper uses. removeFromSquare + removeFromWorld
-- alone leave the zombie inside the cell's java zombie list - so the next
-- scan still sees it and visually it persists. Explicit list:remove(z) wipes
-- the dangling reference too. Matches RPCore.cullZombie exactly.
local function cull(z)
    z:removeFromSquare()
    -- pcall: IsoZombie.removeFromWorld - the super chains getCell():isSafeToAdd()
    -- unguarded, and getCell derefs IsoWorld.instance (IsoObject:1842).
    pcall(z.removeFromWorld, z)
    -- Stepped through IsoWorld.instance rather than z:getCell(): IsoObject.getCell
    -- derefs the instance unconditionally (:1842), this form yields nil instead.
    -- getZombieList is a field return (IsoCell:2339) and remove(Object) on the
    -- backing java.util.ArrayList cannot throw.
    local world = IsoWorld and IsoWorld.instance
    local cell = world and world:getCell()
    local list = cell and cell:getZombieList()
    if list then list:remove(z) end
end

local function chunkOf(x, y)
    return math.floor(x / 10), math.floor(y / 10)
end

DFServer.registerHandler{
    action     = "removeChunkZombies",
    capability = CAP,
    run = function(player, args)
        local px, py = player:getX(), player:getY()
        local cx, cy = chunkOf(px, py)
        local found, removed = 0, 0
        forEachLoadedZombie(function(z)
            local sq = z:getSquare()
            if not sq then return end
            local zcx, zcy = chunkOf(sq:getX(), sq:getY())
            if zcx == cx and zcy == cy then
                found = found + 1
                cull(z)
                removed = removed + 1
            end
        end)
        print(string.format("[Dragonfly] removeChunkZombies player=(%d,%d) chunk=(%d,%d) found=%d removed=%d",
            math.floor(px), math.floor(py), cx, cy, found, removed))
        DFCore.audit("removeChunkZombies", player,
            string.format("chunk=(%d,%d) removed=%d", cx, cy, removed))
        return { ok = true,
            message = string.format("Removed %d zombies in chunk (%d,%d).", removed, cx, cy) }
    end,
}

DFServer.registerHandler{
    action     = "removeRadiusZombies",
    capability = CAP,
    run = function(player, args)
        local radius = tonumber(args.radius) or 25
        if radius < 1 then radius = 1 end
        if radius > 500 then radius = 500 end
        local px, py = player:getX(), player:getY()
        local r2 = radius * radius
        local removed = 0
        forEachLoadedZombie(function(z)
            local sq = z:getSquare()
            if not sq then return end
            local dx, dy = sq:getX() - px, sq:getY() - py
            if dx * dx + dy * dy <= r2 then
                cull(z)
                removed = removed + 1
            end
        end)
        DFCore.audit("removeRadiusZombies", player,
            string.format("radius=%d removed=%d", radius, removed))
        return { ok = true,
            message = string.format("Removed %d zombies within %d tiles.", removed, radius) }
    end,
}

DFServer.registerHandler{
    action     = "removeAllLoadedZombies",
    capability = CAP,
    run = function(player, args)
        local removed = 0
        forEachLoadedZombie(function(z) cull(z); removed = removed + 1 end)
        DFCore.audit("removeAllLoadedZombies", player, "removed=" .. removed)
        return { ok = true, message = string.format("Removed %d loaded zombies.", removed) }
    end,
}

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
