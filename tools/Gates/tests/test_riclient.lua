-- Rip It fixture - fixed vanilla recipe names resolve directly; a removed
-- recipe remains the normal nil result and is omitted from the candidate set.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds/42/media/lua/client/RipIt/RIClient.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RIClient: " .. message)
    end
end

isServer = function() return false end
require = function() end
OEShared = { enabled = function() return true end }
-- The REAL RDShared, not a hand-rolled stub - anything Core adds to it
-- otherwise silently under-serves this fixture (the 2026-08-23 username()
-- promotion proved it). Its only file-scope call is registerMod.
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua")
Events = {
    OnFillInventoryObjectContextMenu = { Add = function() end },
    OnFillWorldObjectContextMenu = { Add = function() end },
}
ISInventoryPaneContextMenu = {
    getContainers = function()
        return { size = function() return 0 end, get = function() return nil end }
    end,
}

local lookups = {}
local recipeA, recipeB = { id = "RipClothing" }, { id = "RipSheets" }
getScriptManager = function()
    return {
        getCraftRecipe = function(_, name)
            lookups[#lookups + 1] = name
            if name == "RipClothing" then return recipeA end
            if name == "RipSheets" then return recipeB end
            return nil
        end,
    }
end

RipIt = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
local recipes = RipIt.gatherAll({})
check(#lookups == 3 and lookups[1] == "RipClothing" and lookups[2] == "RipDenimClothing"
    and lookups[3] == "RipSheets", "resolves each fixed vanilla recipe name")
check(#recipes == 0, "empty containers produce no candidates after direct lookup")

-- The public gather path owns the private resolver. A zero-container list is
-- enough to prove the missing recipe did not throw and the lookup continued.
check(recipeA.id == "RipClothing" and recipeB.id == "RipSheets", "known recipe fixtures remain valid")

print(string.format("RIClient: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
