-- test_stickyheadwear.lua - authority and lifecycle fixtures for Sticky Headwear.
--
-- The production bug was invisible in single-player: SHClient changed the local
-- Clothing instance, while multiplayer helmetFall reads a separate server-owned
-- instance. These fixtures load both runners as separate processes and require
-- each one to change the item it actually owns. They also pin the restoration
-- contract that the original worn-only sweep could not satisfy after unequip.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_stickyheadwear.lua <repo-root>

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
             .. "/42/media/lua/"
local ANCHOR = BASE .. "shared/StickyHeadwear/SHAnchor.lua"
local CLIENT = BASE .. "client/StickyHeadwear/SHClient.lua"
local SERVER = BASE .. "server/StickyHeadwear/SHServer.lua"

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

local function jlist(values)
    return {
        size = function() return #values end,
        get = function(_, index) return values[index + 1] end,
    }
end

local function location(name)
    return setmetatable({ name = name }, {
        __tostring = function(value) return value.name end,
    })
end

local HAT, EYES, SHIRT = location("base:hat"), location("base:eyes"), location("base:shirt")

local scripts = {
    { chance = 80, slot = HAT },
    { chance = 50, slot = EYES },
    { chance = 10, slot = HAT }, -- duplicate slot must be indexed once
    { chance = 0, slot = SHIRT },
}
for _, script in ipairs(scripts) do
    function script:getChanceToFall() return self.chance end
    function script:getBodyLocation() return self.slot end
end

local manager = { getAllItems = function() return jlist(scripts) end }
getScriptManager = function() return manager end

local enabled = true
OEShared = {
    enabled = function(flag)
        eq("the established sandbox key is used", flag, "StickyHeadwearEnable")
        return enabled
    end,
}
require = function() end

local nextItemID = 100
local function item(chance)
    nextItemID = nextItemID + 1
    local value = {
        id = nextItemID,
        chance = chance,
        writes = {},
    }
    function value:getID() return self.id end
    function value:getChanceToFall() return self.chance end
    function value:setChanceToFall(newChance)
        self.chance = newChance
        self.writes[#self.writes + 1] = newChance
    end
    return value
end

local function character(name)
    local value = { name = name, worn = {} }
    function value:getWornItem(slot) return self.worn[slot] end
    return value
end

local function resetEvents()
    local handlers = { clothing = {}, start = {}, tick = {} }
    Events = {
        OnClothingUpdated = { Add = function(fn) handlers.clothing[#handlers.clothing + 1] = fn end },
        OnGameStart = { Add = function(fn) handlers.start[#handlers.start + 1] = fn end },
        OnTick = { Add = function(fn) handlers.tick[#handlers.tick + 1] = fn end },
    }
    return handlers
end

-- ---------------------------------------------------------------------------
-- Client / single-player authority
-- ---------------------------------------------------------------------------

local handlers = resetEvents()
local localPlayer = character("local")
local hat, glasses, shirt = item(80), item(50), item(25)
localPlayer.worn[HAT] = hat
localPlayer.worn[EYES] = glasses
localPlayer.worn[SHIRT] = shirt

getPlayer = function() return localPlayer end
isServer = function() return false end

StickyHeadwear = nil
local SH = dofile(ANCHOR)
dofile(CLIENT)

eq("client registers clothing reconciliation", #handlers.clothing, 1)
eq("client registers startup reconciliation", #handlers.start, 1)
eq("client watches live sandbox changes", #handlers.tick, 1)
handlers.start[1]()

eq("single-player authority pins a hat", hat.chance, 0)
eq("single-player authority pins glasses", glasses.chance, 0)
eq("a non-fall-capable script slot is untouched", shirt.chance, 25)
eq("script definitions remain unchanged", scripts[1].chance, 80)
eq("duplicate definitions produce two indexed slots", SH.indexLocations(), 2)
eq("two changed instances are tracked", SH.trackedCount(), 2)

localPlayer.worn[HAT] = nil
handlers.clothing[1](localPlayer)
eq("unequipping restores the actual item", hat.chance, 80)
eq("only the still-worn item remains tracked", SH.trackedCount(), 1)

local replacement = item(10)
localPlayer.worn[HAT] = replacement
handlers.clothing[1](localPlayer)
eq("a newly worn replacement is pinned", replacement.chance, 0)

enabled = false
handlers.tick[1]()
eq("a live disable restores the replacement", replacement.chance, 10)
eq("a live disable restores glasses", glasses.chance, 50)
eq("a live disable clears tracking", SH.trackedCount(), 0)

-- ---------------------------------------------------------------------------
-- Dedicated-server authority
-- ---------------------------------------------------------------------------

handlers = resetEvents()
enabled = true
isServer = function() return true end

ISWearClothing = {
    complete = function(action)
        action.character.worn[HAT] = action.item
        return true
    end,
}
ISClothingExtraAction = {
    complete = function(action)
        action.character.worn[EYES] = action.item
        return true
    end,
}

local serverPlayer = character("server")
local serverHat, serverGlasses = item(80), item(50)
serverPlayer.worn[HAT] = serverHat
serverPlayer.worn[EYES] = serverGlasses
local online = { serverPlayer }
getOnlinePlayers = function() return jlist(online) end

StickyHeadwear = nil
SH = dofile(ANCHOR)
dofile(SERVER)

eq("server registers one authoritative reconciler", #handlers.tick, 1)
local actionHat, actionGlasses = item(35), item(25)
ISWearClothing.complete({ character = serverPlayer, item = actionHat })
eq("a completed wear action pins before the next tick", actionHat.chance, 0)
eq("a wear action restores the replaced item", serverHat.chance, 80)
ISClothingExtraAction.complete({ character = serverPlayer, item = actionGlasses })
eq("a clothing conversion pins before the next tick", actionGlasses.chance, 0)
eq("a clothing conversion restores the replaced item", serverGlasses.chance, 50)
serverHat, serverGlasses = actionHat, actionGlasses
handlers.tick[1]()
eq("the server-owned hat instance is pinned", serverHat.chance, 0)
eq("the server-owned glasses instance is pinned", serverGlasses.chance, 0)
eq("the client fixture's item remains restored", hat.chance, 80)

serverPlayer.worn[HAT] = nil
handlers.tick[1]()
eq("server unequip restores the removed instance", serverHat.chance, 35)
eq("the remaining server item stays pinned", serverGlasses.chance, 0)

online = {}
handlers.tick[1]()
eq("disconnect releases a pinned instance", serverGlasses.chance, 25)
eq("disconnect releases strong tracking records", SH.trackedCount(), 0)

online = { serverPlayer }
serverPlayer.worn[HAT] = serverHat
handlers.tick[1]()
eq("reconnect pins current authoritative wear", serverHat.chance, 0)
enabled = false
handlers.tick[1]()
eq("server-side disable restores authoritative wear", serverHat.chance, 35)

print(string.format("StickyHeadwear: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
