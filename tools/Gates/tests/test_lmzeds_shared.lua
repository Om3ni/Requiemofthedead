-- LMZedsShared fixture - server and client both use the engine's atomic cull.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMZedsShared.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL LMZedsShared: " .. message) end
end

local calls = 0
local received = nil
VirtualZombieManager = {
    instance = {
        removeZombieFromWorld = function(_, zombie)
            calls = calls + 1
            received = zombie
        end,
    },
}
LMZedsShared = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))

local zombie = {}
LMZedsShared.cull(zombie)
check(calls == 1 and received == zombie,
    "cull delegates once to VirtualZombieManager's atomic removal path")

print(string.format("LMZedsShared: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
