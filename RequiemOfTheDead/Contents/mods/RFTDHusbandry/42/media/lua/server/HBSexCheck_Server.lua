-- HBSexCheck_Server — server side of the sex-check diagnostic.
--
-- Handles "RQ"/"hbSexCheck": dumps the definition table to the server log,
-- reports the server-authoritative sex for the requested OID, and replies to
-- the requesting admin via the existing hbDebugProbeResult channel so the
-- result also surfaces in the panel log. Admin-gated like the other probes.

if not isServer() then return end

local function isAdminLike(player)
    if not player then return false end
    if isDebugEnabled and isDebugEnabled() then return true end
    local access = player:getAccessLevel()
    if access == nil or access == "None" then return false end
    return true
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "RQ" or command ~= "hbSexCheck" then return end
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
    pcall(function() sendServerCommand(player, "RQ", "hbDebugProbeResult", { line = line }) end)
end)

print("[HB] HBSexCheck_Server loaded")
