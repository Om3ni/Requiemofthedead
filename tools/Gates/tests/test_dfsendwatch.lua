-- DFSendWatch fixture - one observer boundary must never cost the wrapped
-- engine action, while ordinary faction-tag reports preserve their exact tag.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFSendWatch.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL DFSendWatch: " .. message)
    end
end

isServer = function() return false end
isClient = function() return true end
require = function() end
RDShared = { MODULE = "RFTDCore" }
SandboxVars = { RFTDCore = { SendWatchEnabled = true } }

local onGameStart
Events = { OnGameStart = { Add = function(fn) onGameStart = fn end } }
local reports = {}
getPlayer = function() return { getUsername = function() return "Omen" end } end
sendClientCommand = function(player, module, command, args)
    reports[#reports + 1] = { player = player, module = module, command = command, args = args }
end

local originalCalls = 0
sendFactionChangeTag = function(faction)
    originalCalls = originalCalls + 1
    return faction and "engine tag changed" or "engine refused"
end
sendSafehouseRelease = function(safehouse)
    originalCalls = originalCalls + 1
    return safehouse and "engine safehouse released" or "engine refused"
end

DFSendWatch = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(type(onGameStart) == "function", "registers its deferred installer")
onGameStart()

local faction = {
    getName = function() return "Foundry" end,
    getTag = function() return "RFD" end,
}
check(sendFactionChangeTag(faction) == "engine tag changed" and originalCalls == 1,
    "tag change preserves the original engine result")
check(#reports == 1 and reports[1].module == "RFTDCore"
    and reports[1].command == "lifecycleReport"
    and reports[1].args.text == "changed tag of faction [Foundry] to [RFD]",
    "tag report uses the direct engine field value")

local safehouse = {
    getTitle = function() return "Hayward" end,
    getX = function() return 10 end,
    getY = function() return 20 end,
    getX2 = function() return 13 end,
    getY2 = function() return 25 end,
}
check(sendSafehouseRelease(safehouse) == "engine safehouse released" and originalCalls == 2,
    "safehouse release preserves the original engine result")
check(#reports == 2 and reports[2].args.text == "released safehouse [Hayward] at [10,20..13,25]",
    "safehouse report reads direct title and bounds")

-- The observer wrapper, not a nested accessor guard, owns the optional
-- telemetry recovery. An unexpected description failure skips the report but
-- cannot cost the actual faction action.
local broken = { getTag = function() error("unexpected faction proxy") end }
check(sendFactionChangeTag(broken) == "engine tag changed" and originalCalls == 3
    and #reports == 2,
    "a failed description still preserves the wrapped engine action")

print(string.format("DFSendWatch: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
