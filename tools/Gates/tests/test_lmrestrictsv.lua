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
local broadcasts = {}
RDNet = {
    reply = function(...)
        replies[#replies + 1] = { ... }
    end,
    broadcast = function(...)
        broadcasts[#broadcasts + 1] = { ... }
    end,
    register = function() end,
}

LMRestrictShared = {
    denied = function(_, _, flag)
        if flag == "nobuilding" then return true, "The Vault" end
        if flag == "nosafehouse" then return true, "Excl" end
        return false, nil
    end,
    -- The rect form the sweep asks for since the client learned to refuse a
    -- claim up front. The five-point geometry is pinned in
    -- test_lmrestrictshared; here it only has to answer for the flag.
    rectDenied = function(_, _, _, _, flag)
        return LMRestrictShared.denied(nil, nil, flag)
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

-- One claim sitting inside a nosafehouse zone, and a live list that shrinks
-- when the sweep removes it - getSafehouseList returns the LIVE list
-- (SafeHouse.java:582-584), which is why the production walk runs backwards.
local removed = {}
local claims = {
    -- onlineId is derived from the rectangle in the constructor
    -- (SafeHouse.java:519), not allocated, which is what makes it safe to send
    -- to clients as the handle on this row.
    { x = 100, y = 200, w = 10, h = 10, owner = "Alice", id = 7734 },
}
local function mkClaim(c)
    return {
        getX = function() return c.x end, getY = function() return c.y end,
        getW = function() return c.w end, getH = function() return c.h end,
        getOwner = function() return c.owner end,
        getOnlineID = function() return c.id end,
    }
end
SafeHouse = {
    getSafehouseList = function()
        local rows = {}
        for i = 1, #claims do rows[i] = mkClaim(claims[i]) end
        return {
            size = function() return #rows end,
            get  = function(_, i) return rows[i + 1] end,
        }
    end,
    removeSafeHouse = function(sh)
        removed[#removed + 1] = sh:getOwner()
        table.remove(claims, 1)
    end,
}

-- The owner, online. getOnlinePlayers is the server-side lookup
-- (LuaManager.java:3823-3832); getPlayerFromUsername answers nil on a dedi.
local owner = { getUsername = function() return "Alice" end }
function getOnlinePlayers()
    return { size = function() return 1 end, get = function(_, i) return i == 0 and owner or nil end }
end

-- Every handler the file installs, captured so the test can FIRE them - the
-- bug this pins was an installed listener on an event that never fires.
local handlers = {}
-- Dot call in production (Events.X.Add(fn)), so fn is the FIRST argument.
local function sink(name)
    return { Add = function(fn) handlers[name] = fn end }
end
Events = {
    OnServerStarted      = sink("OnServerStarted"),
    OnNewFire            = sink("OnNewFire"),
    OnSafehousesChanged  = sink("OnSafehousesChanged"),
    EveryOneMinute       = sink("EveryOneMinute"),
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

-- ---------------------------------------------------------------------------
-- nosafehouse runs off the CLOCK, not off OnSafehousesChanged.
--
-- Both of that event's trigger sites are inside `if (GameClient.client)`
-- (SafeHouse.java:82-84, :301-303) and the third is in processClient
-- (SafehouseSyncPacket:95), so on a dedicated server it never fires and the
-- veto did nothing at all - a claim inside a nosafehouse zone simply stood.
-- These pins fail if the clock listener is ever dropped back to event-only.
-- ---------------------------------------------------------------------------
local function isFn(x) return type(x) == "function" end
eq("a clock listener is installed", isFn(handlers.EveryOneMinute), true)
eq("the event listener is kept for client-hosted", isFn(handlers.OnSafehousesChanged), true)

-- Firing the CLOCK alone must revert the claim: that is the dedicated-server
-- path, and the event will never arrive there to help it.
handlers.EveryOneMinute()
eq("the clock sweep removed the claim", #removed, 1)
eq("...and named the owner", removed[1], "Alice")
eq("...and told the owner why", #replies, 2)
local told = replies[2] or {}
eq("...through the restricted reply", told[3], "restricted")
eq("...naming the flag", told[4] and told[4].flag, "nosafehouse")
eq("...naming the zone", told[4] and told[4].zone, "Excl")
eq("...and wrote a forensic record", #forensicCalls, 2)

-- ---------------------------------------------------------------------------
-- ...and told every CLIENT to drop the row.
--
-- SafeHouse.removeSafeHouse only mutates the server's own list; its
-- notification is behind `if (GameClient.client)` (SafeHouse.java:297-303),
-- and no Lua-reachable call sends the vanilla packet - every sendSafehouse*
-- global is client-gated (LuaManager.java:4311-4372). Without this broadcast
-- the claim stays visible and enforced on every connected client until relog.
-- ---------------------------------------------------------------------------
eq("the sweep told every client to drop it", #broadcasts, 1)
local gone = broadcasts[1] or {}
eq("...on the Limes token", gone[1], "RFTDLimes")
eq("...as safehouseGone", gone[2], "safehouseGone")
eq("...naming the row by its derived id", gone[3] and gone[3].id, 7734)

-- Idempotent: nothing left to revert, so a second minute is silent. A sweep
-- that re-fired on an empty list would spam the owner every game minute.
handlers.EveryOneMinute()
eq("a second sweep removes nothing", #removed, 1)
eq("...and does not re-notify", #replies, 2)
eq("...and does not re-broadcast", #broadcasts, 1)

print(string.format("test_lmrestrictsv: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
