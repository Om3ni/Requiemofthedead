-- HBPartDropClient fixture - the transfer chain and what gets reported.
--
-- The predecessor's failure is the thing to pin: RQD_Menagerie's logger
-- completed the transfer, passed the floor test, and then discarded the event
-- for lack of a context-menu mark. So the assertions here are about what a
-- completed floor transfer SENDS, with no gate a drop path can fail to take:
-- batch capture before the original consumes it, floor-only, watchlist-only,
-- one command per perform, original's return value untouched.

local ROOT = arg[1] or "."
local MOD = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL HBPartDropClient: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

require = function() return true end
print = function() end

local clientAnswer = true
function isClient() return clientAnswer end

local sent = {}
function sendClientCommand(player, module, command, args)
    sent[#sent + 1] = { player = player, module = module, command = command, args = args }
end

HBCmd = { PART_PLACED = "hbPartPlaced" }

local gameStart
Events = { OnGameStart = { Add = function(fn) gameStart = fn end } }

RDEvents = { registerNamespace = function() return true end }
AnimalPartsDefinitions = { animals = {
    doewhitetailed = { head = "Base.Deer_Doe_Head" },
} }

-- ---- fakes ---------------------------------------------------------------

local function fakeItem(fullType, name)
    return {
        getFullType = function() return fullType end,
        getName = function() return name end,
    }
end

local function fakeSquare(x, y, z)
    return {
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
    }
end

local function floorContainer(sq)
    return {
        getType = function() return "floor" end,
        getSourceGrid = function() return sq end,
    }
end

local player = {
    getX = function() return 11.9 end,
    getY = function() return 22.1 end,
    getZ = function() return 0 end,
}

-- ---- load ----------------------------------------------------------------

local performRuns = 0
ISInventoryTransferAction = { perform = function(self)
    performRuns = performRuns + 1
    return "vanilla-result"
end }
local vanillaPerform = ISInventoryTransferAction.perform

HBParts = nil
local ok, err = pcall(dofile, MOD .. "/shared/HBParts.lua")
check(ok, "HBParts loads: " .. tostring(err))

HBPartDropClient = nil
ok, err = pcall(dofile, MOD .. "/client/HBPartDropClient.lua")
check(ok, "HBPartDropClient loads: " .. tostring(err))
check(type(gameStart) == "function", "nothing subscribed to OnGameStart")

-- loading must not touch the vanilla table - the chain waits for OnGameStart
check(ISInventoryTransferAction.perform == vanillaPerform,
    "perform was wrapped at load time, underneath other mods' overrides")

-- in SP (isClient false) the hook stays out: no server listens
clientAnswer = false
gameStart()
check(ISInventoryTransferAction.perform == vanillaPerform,
    "the hook installed in SP, where no server receives the report")

clientAnswer = true
gameStart()
check(ISInventoryTransferAction.perform ~= vanillaPerform, "the hook never installed")

-- ---- a watched floor drop reports ------------------------------------------

local sq = fakeSquare(500, 600, 0)
local action = {
    character = player,
    destContainer = floorContainer(sq),
    queueList = { { items = {
        fakeItem("Base.Deer_Doe_Head", "Doe Head"),
        fakeItem("Base.Axe", "Axe"),
    } } },
}
sent = {}
local r = ISInventoryTransferAction.perform(action)
check(r == "vanilla-result", "the original's return value was not handed back")
check(performRuns == 1, "the original perform did not run")
check(#sent == 1, "a mixed batch sent " .. #sent .. " commands, wanted 1")
local s = sent[1] or {}
check(s.module == "RFTDHusbandry" and s.command == "hbPartPlaced",
    "wrong wire address: " .. tostring(s.module) .. "/" .. tostring(s.command))
check(s.player == player, "sent as the wrong player")
check(s.args and s.args.x == 500 and s.args.y == 600 and s.args.z == 0,
    "coordinates are not the floor container's square")
check(s.args and #s.args.items == 1
    and s.args.items[1].fullType == "Base.Deer_Doe_Head"
    and s.args.items[1].name == "Doe Head",
    "the watched item did not survive filtering, or the unwatched one did")

-- ---- what must NOT report --------------------------------------------------

-- unwatched-only batch: silence
sent = {}
ISInventoryTransferAction.perform{
    character = player, destContainer = floorContainer(sq),
    queueList = { { items = { fakeItem("Base.Axe", "Axe") } } },
}
check(#sent == 0, "an unwatched-only batch sent a report")

-- non-floor destination: silence, original untouched
sent = {}
local bag = { getType = function() return "Bag" end,
              getSourceGrid = function() return sq end }
ISInventoryTransferAction.perform{
    character = player, destContainer = bag,
    queueList = { { items = { fakeItem("Base.Deer_Doe_Head", "Doe Head") } } },
}
check(#sent == 0, "a bag transfer sent a report")

-- no destination at all (vanilla builds these with maxTime=0): no fault
sent = {}
local okNil = pcall(ISInventoryTransferAction.perform,
    { character = player, queueList = {} })
check(okNil, "a destContainer-less action faulted the chain")
check(#sent == 0, "a destContainer-less action sent a report")

-- ---- degenerate shapes -----------------------------------------------------

-- single-item action with no queueList batch
sent = {}
ISInventoryTransferAction.perform{
    character = player, destContainer = floorContainer(sq),
    queueList = {}, item = fakeItem("Base.Deer_Doe_Head", "Doe Head"),
}
check(#sent == 1 and #sent[1].args.items == 1,
    "a bare .item action was not reported")

-- floor container that has no square yet: player position stands in, floored
sent = {}
ISInventoryTransferAction.perform{
    character = player, destContainer = floorContainer(nil),
    queueList = { { items = { fakeItem("Base.Deer_Doe_Head", "Doe Head") } } },
}
check(#sent == 1 and sent[1].args.x == 11 and sent[1].args.y == 22,
    "the player-position fallback is wrong")

-- an oversized batch is capped client-side to the server's cap
local big = {}
for i = 1, 30 do big[#big + 1] = fakeItem("Base.Deer_Doe_Head", "Doe Head") end
sent = {}
ISInventoryTransferAction.perform{
    character = player, destContainer = floorContainer(sq),
    queueList = { { items = big } },
}
check(#sent == 1 and #sent[1].args.items == 20,
    "the client does not cap at 20 - the server would truncate anyway, so an "
    .. "uncapped send is pure wire weight")

-- install is idempotent
local wrapped = ISInventoryTransferAction.perform
HBPartDropClient.install()
check(ISInventoryTransferAction.perform == wrapped,
    "a second install double-wrapped perform")

print = realPrint
print(string.format("HBPartDropClient: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
