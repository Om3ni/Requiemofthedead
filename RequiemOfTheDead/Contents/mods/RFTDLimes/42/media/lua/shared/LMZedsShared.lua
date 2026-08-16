-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMZedsShared - one removal, used by both sides of the zed suppression.
--
-- LMZeds (server, at the birth hook) and LMZedsCl (client, the standing sweep)
-- delete zombies for the same reason and must delete them the same WAY. They
-- carried byte-identical copies of this function; two copies of a world-mutating
-- removal is precisely the kind of pair that drifts silently, and the failure
-- mode is a zombie you can hear but not see.
--
-- WHY THE ENGINE'S OWN METHOD FIRST, and why the hand-rolled path stays:
-- VirtualZombieManager.removeZombieFromWorld unregisters the sound emitter,
-- then removes from world and square, in that order (VirtualZombieManager:80-86)
-- - the same call the real delete packet ends up making
-- (ZombieDeleteOnClientPacket:42). Doing it by hand and forgetting the emitter
-- is the audible-ghost bug. The manual path stays as a fallback because a
-- removal that half-happens is worse than either outcome, and this must not
-- depend on one symbol resolving.
--
-- VirtualZombieManager is Lua-exposed and `instance` is a public STATIC field,
-- which Kahlua does expose - unlike instance fields.
--
-- Engine-coupled by nature, so it lives here rather than in LMCore, which is
-- deliberately engine-free so run-tests can exercise it.
--
-- HISTORY, kept because it is the reason the shape is what it is (corrected
-- 2026-08-06, when this lived in LMZeds): it first mirrored RPCore.cullZombie -
-- removeFromSquare, removeFromWorld, then prune the cell list by hand. Two
-- things were wrong with that, both read from the decompile rather than
-- reasoned about:
--
--   * removeFromWorld ALREADY does the cell-list removal (IsoZombie:3573), so
--     the third step was never doing anything.
--   * it leaks the sound emitter. Skip the unregister and the zombie is gone
--     from the world while its emitter is still registered - a zombie you can
--     hear standing in an empty safe zone, which for a feature whose selling
--     point is silence is the worst possible artefact.

LMZedsShared = LMZedsShared or {}

function LMZedsShared.cull(z)
    if VirtualZombieManager and VirtualZombieManager.instance then
        local vm = VirtualZombieManager.instance
        -- pcall: engine removal mutates world state and must not half-happen
        -- unguarded; direct form, this runs per removed zombie on both sides.
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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
