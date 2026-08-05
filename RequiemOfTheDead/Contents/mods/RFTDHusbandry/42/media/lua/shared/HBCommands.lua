-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBCommands - command string constants and server dispatch shell.
-- Constants are shared; dispatch routes to HBData / HBAPIProbe.

-- LOAD ORDER (landmine, verified 42.19): the CLIENT walks media/lua/shared
-- ALPHABETICALLY ACROSS ALL MODS, so "HBCommands.lua" runs before Core's
-- "RDShared.lua" and RDShared would be nil below. require() pulls Core's file
-- forward; no-op if the walk already ran it. (The dedi loads Core first via
-- require=, so this only bites clients.)
require "RDShared"

RDShared.registerMod("RFTDHusbandry", "1.0.0")   -- keep in sync with mod.info

HBCmd = {}

HBCmd.ADD_SEEN           = "hbAddSeen"
HBCmd.REGISTER           = "hbRegister"
HBCmd.UNREGISTER         = "hbUnregister"
HBCmd.SYNC_ANIMAL        = "hbSyncAnimal"
HBCmd.DEBUG_PROBE        = "hbDebugProbe"
HBCmd.DEBUG_REFILL       = "hbDebugRefill"
HBCmd.DEBUG_PROBE_RESULT = "hbDebugProbeResult"
HBCmd.ADD_BEDDING        = "hbAddBedding"     -- player: add hay bedding to a hutch

if not isServer() then return end

print("[HB] server dispatch loaded (HBCommands)")

-- Admin gate. In SP, getAccessLevel() returns "" - treat as admin since the
-- local player has full server control. In MP, only "None" is rejected.
-- Errors LOG - the old pcall-everywhere pattern hid silent failures.
-- Staff gate: RDAccess capability model (RFTDCore adoption). The old check
-- admitted ANY non-None access level; family policy is "any role holding at
-- least one capability". Debug-mode escape kept for SP/dev sessions.
local function isAdminLike(player)
    if not player then return false end
    if isDebugEnabled and isDebugEnabled() then return true end
    return RDAccess.hasAnyCapability(player)
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "RFTDHusbandry" then return end

    print("[HB] cmd=" .. tostring(command)
        .. " access=" .. tostring(player and player:getAccessLevel())
        .. " args.id=" .. tostring(args and args.id))

    if command == HBCmd.ADD_SEEN then
        local animal = getAnimal(tonumber(args.id))
        if animal then HBData.addSeen(animal) end

    elseif command == HBCmd.REGISTER then
        local animal = getAnimal(tonumber(args.id))
        if animal then HBData.register(animal, player) end

    elseif command == HBCmd.UNREGISTER then
        local animal = getAnimal(tonumber(args.id))
        if animal then HBData.unregister(animal, player) end

    elseif command == HBCmd.DEBUG_PROBE then
        if not isAdminLike(player) then
            print("[HB] DEBUG_PROBE rejected (not admin)")
            return
        end
        if HBAPIProbe and HBAPIProbe.runOn then
            HBAPIProbe.runOn(tonumber(args.id), player)
        else
            print("[HB] DEBUG_PROBE: HBAPIProbe not loaded")
        end

    elseif command == HBCmd.DEBUG_REFILL then
        if not isAdminLike(player) then
            sendServerCommand(player, "RFTDHusbandry", HBCmd.DEBUG_PROBE_RESULT,
                { line = "[set] rejected (not admin)" })
            return
        end
        -- Bidirectional stat write. value=0 → fully fed/watered (refill);
        -- value≈0.9 → starving/parched (starve). Comma-separated OID batch.
        -- updateLastTimeSinceUpdate() resets the elapsed-time clock on the
        -- way down (refill) so chunk reload doesn't immediately re-drain;
        -- harmless on the way up.
        local oidStr = tostring(args and args.oids or "")
        local target = tonumber(args and args.value) or 0
        local count, errors, missing = 0, 0, 0
        for s in string.gmatch(oidStr, "[^,]+") do
            local oid = tonumber(s)
            local animal = oid and getAnimal(oid)
            if not animal then
                missing = missing + 1
            else
                local ok, err = pcall(function()
                    animal:getStats():set(CharacterStat.HUNGER, target)
                    animal:getStats():set(CharacterStat.THIRST, target)
                    animal:updateLastTimeSinceUpdate()
                end)
                if ok then
                    count = count + 1
                else
                    errors = errors + 1
                    print("[HB] set error on OID " .. tostring(oid) .. ": " .. tostring(err))
                end
            end
        end
        local label = (target <= 0.05) and "refill" or "starve"
        local msg = string.format("[%s value=%.2f] applied=%d  missing=%d  errors=%d",
            label, target, count, missing, errors)
        print("[HB] " .. msg)
        sendServerCommand(player, "RFTDHusbandry", HBCmd.DEBUG_PROBE_RESULT, { line = msg })

    elseif command == HBCmd.ADD_BEDDING then
        -- Add hay bedding to a hutch. Open to any player: the diegetic path is
        -- a client timed action that consumes a HayTuft and then sends this;
        -- the server just tops up the charge (capped at MAX). Not admin-gated.
        if not (HBBedding and HBBedding.resolveHutchAt) then
            print("[HB] ADD_BEDDING: HBBedding not loaded")
            return
        end
        local x = tonumber(args and args.x)
        local y = tonumber(args and args.y)
        local z = tonumber(args and args.z) or 0
        -- Ignore any client-supplied amount; the server decides the per-add
        -- value so a client can't inflate it (addBedding still caps at MAX).
        if not (x and y) then return end
        local hutch = HBBedding.resolveHutchAt(x, y, z)
        if not hutch then
            print(string.format("[HB] ADD_BEDDING: no hutch at %s,%s,%s", tostring(x), tostring(y), tostring(z)))
            return
        end
        local added = HBBedding.perAdd()
        local total = HBBedding.addBedding(hutch, added)
        print(string.format("[HB] ADD_BEDDING: +%.0f at %d,%d,%d -> %.0f/%d",
            added, x, y, z, total, HBBedding.MAX))
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
