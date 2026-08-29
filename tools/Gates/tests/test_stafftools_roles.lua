-- test_stafftools_roles.lua - persisted role reapplication contract.
--
-- A connected player receives the persisted live Role exactly once. Role lookup
-- and assignment are authoritative state, not ModData: transmitting ObjectModData
-- cannot synchronize a role (IsoObject.java:4470-4480; GameServer.java:2666-2671).

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDStaffTools"
             .. "/42/media/lua/server/DFPlayerRoles_Server.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

isServer = function() return true end
require = function() end
-- The REAL RDShared, not a hand-rolled stub - anything Core adds to it
-- otherwise silently under-serves this fixture (the 2026-08-23 username()
-- promotion proved it). Its only file-scope call is registerMod.
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua")

local userRole = { getName = function() return "user" end }
local adminRole = { getName = function() return "admin" end }
DFRoleShared = {
    findRole = function(name)
        if name == "admin" then return adminRole end
        return nil
    end,
}

local player = { role = userRole, setCalls = 0 }
function player:getRole() return self.role end
function player:setRole(role)
    self.role = role
    self.setCalls = self.setCalls + 1
end
-- Deliberately no transmitModData stub: a role reapply must not send ObjectModData.

getPlayerFromUsername = function(username)
    if username == "Omen" then return player end
end
getOnlinePlayers = function()
    return {
        size = function() return 1 end,
        get = function(_, index) if index == 0 then return player end end,
    }
end
function player:getUsername() return "Omen" end

getFileReader = function()
    local lines, index = { "Omen\tadmin" }, 0
    return {
        readLine = function()
            index = index + 1
            return lines[index]
        end,
        close = function() end,
    }
end
getFileWriter = function() return nil end

local serverStarted
local function event(add)
    return { Add = add }
end
Events = {
    OnServerStarted = event(function(fn) serverStarted = fn end),
    OnPlayerConnect = event(function() end),
    OnClientConnect = event(function() end),
    OnConnected = event(function() end),
    OnCreatePlayer = event(function() end),
}

dofile(SRC)
eq("registers the server-start reapply hook", type(serverStarted), "function")

serverStarted()
eq("applies the persisted role", player.role, adminRole)
eq("applies it once", player.setCalls, 1)

serverStarted()
eq("does not reapply an already-correct role", player.setCalls, 1)

print(string.format("Staff Tools roles: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
