-- DFPlayersTab_Server - handlers for the Players tab.
--
-- One server-side action:
--   playersList  - snapshot online players for the tab list
--
-- Kick / ban / teleport stay client-side via SendCommandToServer chat
-- commands (matches DFScoreboard's pattern). Vanilla already permission-gates
-- those server-side, and the client emits a parallel auditOnly event so the
-- audit line still broadcasts to every admin's Console tab.
--
-- setRoleForUser was deliberately removed along with the tab's role dropdown:
-- in-panel role assignment double-dutied with vanilla's role management,
-- leaving two sources of truth for a player's role. NOTE: DFPlayerRoles_Server
-- stays - existing assignments in Dragonfly_PlayerRoles.txt still re-apply on
-- connect, and deleting that engine before migrating them to vanilla's DB
-- would silently revert those players' roles.

if not isServer() then return end

local function roleName(target)
    local ok, name = pcall(function()
        local role = target:getRole()
        return role and role:getName() or "-"
    end)
    return ok and name or "-"
end

local function accessLevel(target)
    local ok, lvl = pcall(function() return target:getAccessLevel() end)
    return ok and lvl or "none"
end

local function isGod(target)
    local ok, v = pcall(function() return target:isGodMod() end)
    return ok and v or false
end

local function isInvis(target)
    local ok, v = pcall(function() return target:isInvisible() end)
    return ok and v or false
end

local function displayName(target)
    local ok, name = pcall(function() return target:getDisplayName() end)
    if ok and name and name ~= "" then return name end
    return target:getUsername()
end

local function serializePlayer(target)
    local ok, x, y, z = pcall(function()
        return target:getX(), target:getY(), target:getZ()
    end)
    if not ok then x, y, z = 0, 0, 0 end
    return {
        username = target:getUsername(),
        display  = displayName(target),
        role     = roleName(target),
        access   = accessLevel(target),
        god      = isGod(target),
        invis    = isInvis(target),
        x = math.floor(x), y = math.floor(y), z = math.floor(z),
    }
end

-- DFServer.lua loads after this file alphabetically (P < S), so DFServer is
-- nil at top-of-file execution. Defer registration until the whole server
-- script set has loaded. OnServerStarted is the right gate - clients can't
-- send commands until after it fires anyway.
Events.OnServerStarted.Add(function()
    if not DFServer or not DFServer.registerHandler then
        print("[Dragonfly] DFPlayersTab_Server: DFServer missing, handlers not registered")
        return
    end

    DFServer.registerHandler{
        action     = "playersList",
        capability = Capability.KickUser,
        run = function(player, args)
            local out = {}
            local players = getOnlinePlayers()
            if players then
                for i = 0, players:size() - 1 do
                    local p = players:get(i)
                    if p then out[#out + 1] = serializePlayer(p) end
                end
            end
            pcall(sendServerCommand, player, DFCore.MODULE, "PlayersList",
                { players = out })
            return { ok = true }  -- silent success; PlayersList drives UI
        end,
    }

    -- setAccessLevelForUser used to live here, but server-side
    -- target:setAccessLevel doesn't persist to the whitelist DB - on
    -- reconnect vanilla snapped them back to the saved access. Client now
    -- routes access changes through `SendCommandToServer("/setaccesslevel ...")`
    -- instead so vanilla's command handler does the DB write. No handler
    -- here; the client emits auditOnly so the action still broadcasts to
    -- every admin's Console tab.

    print("[Dragonfly] DFPlayersTab_Server handlers registered")
end)

print("[Dragonfly] DFPlayersTab_Server loaded (registration deferred to OnServerStarted)")

-- Dragonfly v0.2.0
