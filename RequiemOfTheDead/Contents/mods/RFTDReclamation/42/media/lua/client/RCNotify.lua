-- RCNotify - server -> client halo feedback channel.
--
-- The server sends { key, error } under a "Notify" command; we resolve the
-- translation key and float it over the local player. Green for success, red
-- for a denial. This is the only feedback path for claim/deny/expiry results.

if isServer() and not isClient() then return end

RCNotify = RCNotify or {}

local function onServerCommand(module, command, args)
    if module ~= RCShared.MODULE then return end
    if command ~= "Notify" then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local key = (args and args.key) or "IGUI_RC_Generic"
    RCShared.halo(player, getText(key), args and args.error)
end

Events.OnServerCommand.Add(onServerCommand)
