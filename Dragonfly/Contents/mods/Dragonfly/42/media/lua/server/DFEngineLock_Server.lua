-- DFEngineLock_Server - server-side log mirror for engine-parts pulls.
--
-- The block in client/DFEngineLock.lua stops non-admin players from taking engine
-- parts, but PZ vehicle mechanics are client-authoritative and expose no server-side
-- Lua event for part removal, so the server cannot independently observe a pull. This
-- module receives a client command fired at the moment parts are obtained (downstream
-- of the block) and prints it to the server log.
--
-- Read the log to audit pulls. Because the block should prevent any non-admin from
-- reaching this point, a line with admin=false is a direct signal that someone
-- bypassed the restriction (e.g. a modified client). Caveat: a client running with
-- Dragonfly fully removed will not send the command at all - no pure-Lua mod can
-- detect that server-side without an engine change.

local LOG_MODULE = "DFEngineLock" -- must match client/DFEngineLock.lua

local function cfg() return SandboxVars.RFTDDragonfly or {} end

local function onClientCommand(module, command, player, args)
    if module ~= LOG_MODULE or command ~= "pull" then return end
    args = args or {}

    local user      = (player and player:getUsername()) or "?"
    local isAdminPull = args.admin == true
    -- A non-admin pull while the lock is enabled means the block was bypassed.
    local bypass    = (not isAdminPull) and (cfg().EngineLockEnabled ~= false)
    local tag       = bypass and "BYPASS - block defeated" or (isAdminPull and "admin" or "lock disabled")

    print(string.format(
        "[DFEngineLock] ENGINE PARTS PULLED by %s (%s) vehicle=%s id=%s at (%s,%s,%s)",
        user, tag,
        tostring(args.vehicle), tostring(args.vid),
        tostring(args.x), tostring(args.y), tostring(args.z)))
end

Events.OnClientCommand.Add(onClientCommand)

print("[DFEngineLock] server log mirror loaded")
