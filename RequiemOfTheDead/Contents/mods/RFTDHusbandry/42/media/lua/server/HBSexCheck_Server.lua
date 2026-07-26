-- HBSexCheck_Server - server side of the sex-check diagnostic.
--
-- Handles "RFTDHusbandry"/"hbSexCheck": dumps the definition table to the server log,
-- reports the server-authoritative sex for the requested OID, and replies to
-- the requesting admin via the existing hbDebugProbeResult channel so the
-- result also surfaces in the panel log. Admin-gated like the other probes.

if not isServer() then return end

-- Staff gate: RDAccess capability model (RFTDCore adoption). The old check
-- admitted ANY non-None access level; family policy is "any role holding at
-- least one capability". Debug-mode escape kept for SP/dev sessions.
local function isAdminLike(player)
    if not player then return false end
    if isDebugEnabled and isDebugEnabled() then return true end
    return RDAccess.hasAnyCapability(player)
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "RFTDHusbandry" or command ~= "hbSexCheck" then return end
    if not isAdminLike(player) then
        print("[HBSexCheck] rejected (not admin)")
        return
    end

    if HBSexCheck and HBSexCheck.dumpDefs then HBSexCheck.dumpDefs("server") end

    local oid = tonumber(args and args.id)
    if not oid then return end

    local line
    local a = getAnimal(oid)
    if a then
        local sex = "?"
        pcall(function() sex = a:isFemale() and "FEMALE" or "MALE" end)
        line = string.format("[HBSexCheck] server view: oid=%d sex=%s", oid, sex)
    else
        line = "[HBSexCheck] server: animal " .. tostring(oid) .. " not resolvable"
    end
    print(line)
    pcall(function() sendServerCommand(player, "RFTDHusbandry", "hbDebugProbeResult", { line = line }) end)
end)

print("[HB] HBSexCheck_Server loaded")
