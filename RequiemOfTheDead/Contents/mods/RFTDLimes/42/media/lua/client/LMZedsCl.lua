-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMZedsCl.lua - the client half of `zeds`: clearing what the server already removed.
--
-- WHY THIS FILE EXISTS AT ALL. LMZeds removes zombies server-side and cannot
-- tell anyone. The engine's own removal paths call
-- NetworkZombiePacker.deleteZombie(z) BEFORE removeFromWorld - that order is
-- load-bearing, because removeFromWorld nulls onlineId to -1
-- (IsoZombie:3569) and the delete record captures that id
-- (NetworkZombiePacker:69) - and NetworkZombiePacker is not exposed to Lua. It
-- is absent from LuaManager's setExposed list and no vanilla Lua calls it, so
-- ZombieDeleteOnClient is a packet no mod can send.
--
-- Birth suppression does not need one: a zombie removed inside OnZombieCreate
-- was never transmitted, so no client ever had a copy. The standing SWEEP does.
-- It removes zombies that are on somebody's screen, and with no delete packet
-- those clients keep drawing them until the chunk re-streams - which for a
-- feature whose whole design is that removal is invisible would read as the
-- sweep simply not working.
--
-- SO EACH MACHINE SWEEPS ITS OWN WORLD, from its own replicated copy of the
-- store, when the server says it has just swept. The wire carries one small
-- message per admin-driven zone event and no zombie identities at all: both
-- halves apply the same rule to the same data at the same moment. That is the
-- same shape §7.4 gives zone stats, for the same reason - the alternative is
-- inventing an id channel for something the store already describes.
--
-- WHY ONLY ON THE BROADCAST, and never on a timer. A client must remove only
-- what the SERVER has already removed. A zombie that walked into a remove-zone
-- between sweeps is legitimately there - the server still owns it, and a client
-- deleting it locally would simply be sent it again on the next update, which
-- is a flicker rather than a fix. Mirroring the server's sweep is the only
-- moment the two are guaranteed to agree.
--
-- `none` zones are not swept here, exactly as they are not swept on the server:
-- a zone that only promised not to SPAWN zombies has not promised to remove one
-- that walked in.
--
-- DELETE THIS FILE and the server still enforces; ghosts simply linger until
-- the chunk re-streams. Nothing else changes.

if isServer() then return end

require "LMCore"

LMZedsCl = LMZedsCl or {}

local MODE_REMOVE = "remove"

-- The engine's own client-side removal, which is what the real delete packet
-- ends up calling: VirtualZombieManager.removeZombieFromWorld unregisters the
-- sound emitter first, then removes from world and square
-- (VirtualZombieManager:80-86, ZombieDeleteOnClientPacket:42). Doing it by hand
-- and forgetting the emitter leaves a zombie you can hear but not see.
local function cull(z)
    if VirtualZombieManager and VirtualZombieManager.instance then
        local vm = VirtualZombieManager.instance
        -- pcall: engine removal mutates world state and must not half-happen
        -- unguarded; direct form, this runs per swept zombie.
        if pcall(vm.removeZombieFromWorld, vm, z) then return end
    end
    -- pcall: getEmitter() is a field read (IsoGameCharacter:1348) but the
    -- emitter may be null, and unregister() is not in the decompile at all.
    pcall(function() z:getEmitter():unregister() end)
    -- pcall: IsoZombie.removeFromWorld:3550 chains into IsoMovingObject:688,
    -- which calls getCell().isSafeToAdd() with no guard.
    pcall(z.removeFromWorld, z)
    -- No guard: IsoMovingObject.removeFromSquare:702 null-checks every field
    -- it touches, and it is the last step so nothing follows it to skip.
    z:removeFromSquare()
end

local function modeAt(x, y)
    if not x or not y then return nil end
    local zone = Limes.getLocation(x, y)
    if not zone or not zone.fields then return nil end
    return zone.fields.zeds
end

-- Returns how many it removed. Collected first, culled second: cull() mutates
-- the very list being walked, and an index walk would skip one entry per
-- removal - the same trap as the server's sweep.
function LMZedsCl.sweep()
    -- Stepped through IsoWorld.instance rather than getCell(): the global
    -- dereferences the instance unconditionally, so it throws before the world
    -- is up; this form just yields nil then. getZombieList is a field return
    -- (IsoCell:2339) and the rest is java.util.ArrayList walked in bounds.
    local world = IsoWorld and IsoWorld.instance
    local cell = world and world:getCell()
    local list = cell and cell:getZombieList() or nil
    if not list then return 0 end

    local hits = {}
    local n = list:size()
    for i = 0, n - 1 do
        local z = list:get(i)
        if z then
            local x, y = z:getX(), z:getY()
            if modeAt(math.floor(x), math.floor(y)) == MODE_REMOVE then
                hits[#hits + 1] = z
            end
        end
    end
    for i = 1, #hits do cull(hits[i]) end
    return #hits
end

-- The store may not have caught up. The server broadcasts the sweep and the
-- zone delta separately, and nothing orders them: sweeping against a store that
-- does not yet know about the zone would find nothing and report success. So a
-- sweep that comes up empty is retried once on the next store change, which is
-- when the delta has landed.
local pending = false

local function runSweep(why)
    local removed = LMZedsCl.sweep()
    if removed > 0 then
        pending = false
        print("[Limes] zeds: cleared " .. removed .. " zombie(s) locally (" .. tostring(why) .. ")")
    end
    return removed
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "RFTDLimes" or command ~= "zedsSweep" then return end
    local name = (type(args) == "table" and args.name) or "?"
    if runSweep(name) == 0 then pending = true end
end)

-- The retry, and only ever one: `pending` clears whether or not the second pass
-- found anything, so a zone that genuinely has no zombies near this client does
-- not leave a sweep armed forever, re-walking the cell on every future store
-- change for nothing.
Limes.onChanged(function()
    if not pending then return end
    pending = false
    runSweep("store caught up")
end)

return LMZedsCl

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
