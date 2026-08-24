-- RQSvScavenger fixture - the LOAD CONTRACT, nothing else yet.
--
-- WHY THIS FILE EXISTS. RQSvScavenger injects its state table into RQSvEating
-- at FILE SCOPE, and until 2026-08-24 it declared no dependency at all - it
-- loaded correctly only because RQServer happened to require RQSvEating first.
-- The Bulwark batch added RQBloodhound, which sorts ahead of RQSvEating in the
-- server's alphabetical walk and requires this file: the injection ran against
-- nil, the throw was swallowed by require's own protectedCall
-- (LuaManager.java:1391), and every Scavenger eaterArrived crashed for the
-- whole Mosaic session. This fixture pins the fix from both sides: the file
-- must DECLARE the dependency, and the injection must actually land.
--
-- SCOPE, stated honestly: rage, decay, eating phases and isEnraged carry no
-- assertions here - that behaviour debt predates this file and is recorded in
-- TODO.md. Do not read green here as "Scavenger is tested".

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvScavenger.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvScavenger: " .. message)
    end
end

function isServer() return true end
function getTimestampMs() return 0 end

-- Only the surface the file touches at LOAD time is real here; everything the
-- functions touch at call time stays absent on purpose, so any new file-scope
-- dereference fails this fixture instead of riding on an accidental stub.
local injectedState = nil
RQSvEating = {
    setScavengerState = function(tbl) injectedState = tbl end,
}

local demanded = {}
function require(name)
    demanded[name] = true
    if name ~= "RQSvEating" then
        error("unexpected fixture require: " .. tostring(name))
    end
end

RQSvScavenger = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(demanded["RQSvEating"] == true,
    "the file declares its RQSvEating dependency - load order is not a contract")
check(injectedState ~= nil and injectedState == RQSvScavenger.state,
    "the eating engine received this module's state table at load")

-- The surfaces the rest of the suite dispatches to must exist after a bare
-- load - RQSvHit calls onPlayerHit, RQBulwark and RQBloodhound call isEnraged,
-- RQServer calls tick and setActiveZombies.
check(type(RQSvScavenger.onPlayerHit) == "function", "onPlayerHit exists")
check(type(RQSvScavenger.isEnraged) == "function", "isEnraged exists")
check(type(RQSvScavenger.tick) == "function", "tick exists")
check(type(RQSvScavenger.setActiveZombies) == "function", "setActiveZombies exists")
check(type(RQSvScavenger.state) == "table", "state table exists")

print(string.format("RQSvScavenger: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
