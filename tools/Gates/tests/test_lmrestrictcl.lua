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
Events = {
    OnServerCommand = { Add = function() end },
    OnGameStart = { Add = function() end },
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
}
package.preload.LMRestrictShared = function() return LMRestrictShared end

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

print(string.format("Limes restriction client: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
