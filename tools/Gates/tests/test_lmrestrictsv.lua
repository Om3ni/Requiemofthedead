-- test_lmrestrictsv.lua - pins the server restriction forensic contract.
--
-- LMRestrictSv used to call RDLog.forensic(event, payload), shifting every
-- argument left: the event became a stream name and the payload became a table
-- string in the envelope. This harness exercises one authoritative refusal and
-- proves the complete Core call shape without loading the game.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/server/LMRestrictSv.lua"

function isServer() return true end

local forensicCalls = {}
RDLog = {
    forensic = function(...)
        forensicCalls[#forensicCalls + 1] = { ... }
    end,
}

local replies = {}
RDNet = {
    reply = function(...)
        replies[#replies + 1] = { ... }
    end,
    register = function() end,
}

LMRestrictShared = {
    denied = function(_, _, flag)
        if flag == "nobuilding" then return true, "The Vault" end
        return false, nil
    end,
}

LMCore = {}
Actions = {
    build = function() error("denied build reached the original handler") end,
}
ISMoveableSpriteProps = {
    pickUpMoveableViaCursor = function() end,
    scrapObjectViaCursor = function() end,
    placeMoveableViaCursor = function() end,
}
SCampfireSystemCommand = function() end
IsoFireManager = { Remove = function() end }
SafeHouse = { getSafehouseList = function() return nil end }

Events = {
    OnServerStarted = { Add = function() end },
    OnNewFire = { Add = function() end },
    OnSafehousesChanged = { Add = function() end },
}

local realRequire = require
require = function(name)
    if name == "LMCore" then return LMCore end
    if name == "LMRestrictShared" then return LMRestrictShared end
    if name == "RDNet" then return RDNet end
    return realRequire(name)
end

local loaded, err = pcall(dofile, SRC)
require = realRequire
if not loaded then
    print("FATAL: could not load LMRestrictSv.lua: " .. tostring(err))
    os.exit(2)
end

local player = {
    getUsername = function() return "Alice" end,
}
Actions.build(player, { x = 10, y = 20 })

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

eq("one refusal writes one forensic record", #forensicCalls, 1)
local call = forensicCalls[1] or {}
eq("restriction record uses the limes stream", call[1], "limes")
eq("restriction record preserves its event", call[2], "LM.RESTRICT")
eq("restriction record carries the player subject", call[3], player)
eq("restriction record carries the flag", call[4] and call[4].flag, "nobuilding")
eq("restriction record carries the zone", call[4] and call[4].zone, "The Vault")
eq("restriction record names its producing mod", call[5], "RFTDLimes")
eq("refusal still explains itself to the player", #replies, 1)

print(string.format("test_lmrestrictsv: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
