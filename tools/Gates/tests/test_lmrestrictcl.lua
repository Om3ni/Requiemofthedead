-- Restriction bounce: a player entering a noplayers zone returns to the last
-- valid position on both axes. IsoMovingObject.setX/setY update current and
-- next coordinates (IsoMovingObject.java:478-498); there is no setLx/setLy.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes"
             .. "/42/media/lua/client/LMRestrictCl.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

local update
local onCommand
local onGameStart = {}
Events = {
    OnServerCommand = { Add = function(fn) onCommand = fn end },
    OnGameStart = { Add = function(fn) onGameStart[#onGameStart + 1] = fn end },
    OnPlayerUpdate = { Add = function(fn) update = fn end },
}
isServer = function() return false end
package.preload.LMCore = function() return {} end

local deniedNow = false
LMRestrictShared = {
    denied = function()
        return deniedNow, deniedNow and "Closed" or nil
    end,
    -- The bounce asks the per-player variant since noplayersPass (2026-08-27);
    -- this fixture's stub has no pass list, so it defers to the flag answer.
    deniedFor = function(_, x, y, flag)
        return LMRestrictShared.denied(x, y, flag)
    end,
    -- The area form the safehouse gate asks. Its five-point geometry is pinned
    -- in test_lmrestrictshared; here the flag answer is all that matters.
    rectDenied = function()
        return deniedNow, deniedNow and "Closed" or nil
    end,
}
package.preload.LMRestrictShared = function() return LMRestrictShared end

-- The claim path. sendSafehouseClaim is a Java-exposed global
-- (LuaManager.java:4361-4366) and the gate wraps it, so it has to exist
-- BEFORE the module loads or the wrap declines to install.
local claimsSent = {}
function sendSafehouseClaim(square, player, title)
    claimsSent[#claimsSent + 1] = { square = square, player = player, title = title }
end

-- addSafeHouse derives the rect from the building def, padded two on each side
-- (SafeHouse.java:89-91). getDef is a method; the `def` field is not exposed.
local function mkSquare(bx, by, bw, bh)
    local def = {
        getX = function() return bx end, getY = function() return by end,
        getW = function() return bw end, getH = function() return bh end,
    }
    local building = { getDef = function() return def end }
    return { getBuilding = function() return building end }
end

-- The client's own copy of the safehouse list, which the server's removal
-- never reaches on its own (SafeHouse.java:297-303).
local clientList = { [7734] = { id = 7734 } }
local droppedLocally = {}
SafeHouse = {
    getSafeHouse = function(id) return clientList[id] end,
    removeSafeHouse = function(sh)
        droppedLocally[#droppedLocally + 1] = sh.id
        clientList[sh.id] = nil
    end,
}

local player = { x = 10, y = 20 }
function player:getX() return self.x end
function player:getY() return self.y end
function player:setX(x) self.x = x; self.nextX = x end
function player:setY(y) self.y = y; self.nextY = y end
getSpecificPlayer = function() return player end
getTimestampMs = function() return 10000 end

dofile(SRC)
eq("registers player update", type(update), "function")

update(player)
deniedNow = true
player.x, player.y = 50, 60
update(player)
eq("bounce restores X", player.x, 10)
eq("bounce restores Y", player.y, 20)
eq("bounce synchronizes next X", player.nextX, 10)
eq("bounce synchronizes next Y", player.nextY, 20)

-- ---------------------------------------------------------------------------
-- nosafehouse, the client half: refuse the claim BEFORE the packet is sent.
--
-- There is no pre-claim hook anywhere in the engine - SafehouseClaimPacket
-- .processServer adds the row and only then can the server take it back - so
-- without this the player watches a claim succeed and vanish a game minute
-- later. The server's revert remains the authority; this is the honest half.
-- ---------------------------------------------------------------------------
-- The gate installs on OnGameStart, never at file scope: it must sit OUTSIDE
-- Core's DFSendWatch wrapper on the same global, or a refused claim gets
-- ledgered as one that was sent. Nothing is wrapped until the event runs.
local engineClaim = sendSafehouseClaim
for i = 1, #onGameStart do onGameStart[i]() end
eq("the claim global is only wrapped on game start", sendSafehouseClaim ~= engineClaim, true)

deniedNow = false
sendSafehouseClaim(mkSquare(300, 400, 8, 6), player, "Alice")
eq("a claim outside every zone goes through", #claimsSent, 1)

deniedNow = true
sendSafehouseClaim(mkSquare(300, 400, 8, 6), player, "Alice")
eq("a claim inside a nosafehouse zone is never sent", #claimsSent, 1)

-- No building means no rectangle to test, and no claim the engine would
-- accept either (SafehouseClaimPacket.isConsistent:65-68). It goes through to
-- the refusal that already exists rather than being silently eaten here.
sendSafehouseClaim({ getBuilding = function() return nil end }, player, "Alice")
eq("a buildingless claim is left to the engine", #claimsSent, 2)

-- ---------------------------------------------------------------------------
-- ...and the reverted claim is dropped from this client's list.
--
-- removeSafeHouse on the server notifies nobody and server Lua cannot send the
-- vanilla packet, so the row survived on every client until relog. The server
-- names it; the client drops its own copy.
-- ---------------------------------------------------------------------------
eq("the command handler is registered", type(onCommand), "function")

onCommand("RFTDLimes", "safehouseGone", { id = 7734 })
eq("a named row is dropped locally", droppedLocally[1], 7734)

onCommand("RFTDLimes", "safehouseGone", { id = 7734 })
eq("a row this client never had is a no-op", #droppedLocally, 1)

onCommand("RFTDOddsAndEnds", "safehouseGone", { id = 99 })
eq("another mod's module is ignored", #droppedLocally, 1)

print(string.format("Limes restriction client: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
