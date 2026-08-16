-- test_rpgovernor.lua - LZI governor actuator contract.
--
-- Build 42.20 registers ZombieConfig.PopulationPeakMultiplier at 0..4
-- (SandboxOptions.java:1963). A low-Hz window must update that exact option,
-- mirror the value for Lua readers, and fire the LZI bridge port once.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReaper"
             .. "/42/media/lua/server/RPGovernor.lua"

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

local now = 100000
getTimestampMs = function() return now end

SandboxVars = {
    RFTDReaper = {
        LZIEnabled = true,
        LZILowWaterHz = 5,
        LZIHoldDownSec = 10,
        LZICooldownSec = 1,
        LZIStep = 0.25,
        LZIFloor = 1.0,
    },
    ZombieConfig = { PopulationPeakMultiplier = 1.5 },
}

local writes = {}
getSandboxOptions = function()
    return {
        set = function(_, name, value)
            writes[#writes + 1] = { name = name, value = value }
        end,
    }
end

local bridgeCalls = {}
setMinMaxZombiesPerChunk = function(minimum, maximum)
    bridgeCalls[#bridgeCalls + 1] = { minimum = minimum, maximum = maximum }
end

ModData = { getOrCreate = function() return {} end }
sendServerCommand = function() end

local tick
Events = { OnTick = { Add = function(fn) tick = fn end } }

dofile(SRC)
eq("registers an OnTick governor", type(tick), "function")

tick()                 -- establish the first sensor window
for _ = 1, 4 do
    now = now + 2500
    tick()             -- 4 ticks / 10 seconds: low water, not a process freeze
end

eq("writes the registered peak option", writes[1] and writes[1].name,
    "ZombieConfig.PopulationPeakMultiplier")
eq("trims by the configured step", writes[1] and writes[1].value, 1.25)
eq("keeps the Lua mirror synchronized", SandboxVars.ZombieConfig.PopulationPeakMultiplier, 1.25)
eq("fires the LZI bridge once", #bridgeCalls, 1)
eq("uses the native default min", bridgeCalls[1] and bridgeCalls[1].minimum, 0)
eq("uses the native default max", bridgeCalls[1] and bridgeCalls[1].maximum, 255)

print(string.format("Reaper governor: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
