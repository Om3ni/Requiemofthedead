-- RQSvEating fixture - corpse removal uses explicit live-square preconditions.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvEating.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvEating: " .. message)
    end
end

function isServer() return true end
function instanceof(value, className) return value and value.className == className end

RQSvShared = {
    broadcast = function() end,
    makeCastArgs = function() return {} end,
    getSvConfig = function() return {} end,
    COLORS = {},
    SCAV_CORPSE_RADIUS = 8,
}
RQDirgeLog = { write = function() end }

local function javaList(values)
    return {
        size = function() return #values end,
        get = function(_, index) return values[index + 1] end,
    }
end

local bodies = {}
local removeCalls = 0
local square = {
    getX = function() return 10 end,
    getY = function() return 20 end,
    getZ = function() return 0 end,
    getDeadBodys = function() return javaList(bodies) end,
    removeCorpse = function(_, body, remote)
        removeCalls = removeCalls + 1
        check(body == bodies[1] and remote == false, "direct removal preserves the engine call contract")
    end,
}

local function corpse(cell, ownerSquare)
    return {
        className = "IsoDeadBody",
        getCell = function() return cell end,
        getSquare = function() return ownerSquare end,
    }
end

RQSvEating = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))

bodies = { corpse({}, square) }
check(RQSvEating.svRemoveCorpse(bodies[1], square) == true and removeCalls == 1,
    "a live corpse is removed directly")

bodies = { corpse(nil, square) }
check(RQSvEating.svRemoveCorpse(bodies[1], square) == false and removeCalls == 1,
    "a corpse without a live cell is treated as stale")

bodies = { corpse({}, {}) }
check(RQSvEating.svRemoveCorpse(bodies[1], square) == false and removeCalls == 1,
    "a corpse owned by another square is not removed")

bodies = { corpse({}, square) }
local zombieTarget = { className = "IsoZombie" }
check(RQSvEating.svRemoveCorpse(zombieTarget, square) == true and removeCalls == 2,
    "a transitioned zombie target resolves through the square corpse list")

square.removeCorpse = function() error("fixture removal fault") end
local faultVisible = not pcall(RQSvEating.svRemoveCorpse, bodies[1], square)
check(faultVisible, "an unexpected removal fault is not swallowed")

print(string.format("RQSvEating: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

