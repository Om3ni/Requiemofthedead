-- RCEternalTorch fixture - the toggle speaks only when it actually moved, and
-- the refill skips a torch that has no uses to refill.
--
-- WHY THIS EXISTS. Vanilla's Admin Powers SAVE button does not apply "the
-- option you changed" - it walks EVERY registered option and calls setValue
-- with that box's current state (ISAdminPowerUI.lua:397-403). So a setCheat
-- that halos unconditionally announces blowtorches every time an admin toggles
-- invisibility, which is what live play reported on 2026-08-19. That coupling
-- is invisible from inside this file, so nothing but a test keeps it fixed.
--
-- The refill stub deliberately models the ENGINE's split: predicateTorch matches
-- on tag OR type, so an item can satisfy it and still not be a
-- DrainableComboItem - and a DrainableComboItem is the only thing carrying
-- getCurrentUses. A stub where every torch has uses would pass a version that
-- throws in game.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rceternaltorch.lua <repo-root>

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/client/RCEternalTorch.lua"

local realPrint = print
local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        realPrint("FAIL RCEternalTorch: " .. message)
    end
end

function isServer() return false end
function isClient() return true end

-- Halo calls are the thing under test, so they are recorded rather than voided.
local halos = {}
RCShared = {
    isAdmin = function() return true end,
    halo    = function(_, text) halos[#halos + 1] = text end,
    dbg     = function() end,
}

ItemTag = { BLOW_TORCH = "BlowTorch" }
Capability = { UseMechanicsCheat = "UseMechanicsCheat" }

-- One registered option, captured so the test can drive setValue exactly the
-- way vanilla's SAVE loop does.
local option
ISAdminPowerUI = {
    OptionById = {},
    AddOption = function(id, side, cap, get, set)
        option = { id = id, get = get, set = set }
        ISAdminPowerUI.OptionById[id] = option
    end,
}

-- Inventory: a real drainable torch, plus a modded one that is TAGGED a
-- blowtorch but carries none of the drainable surface.
local realTorch = {
    uses = 2, max = 10,
    hasTag        = function(_, t) return t == "BlowTorch" end,
    getType       = function() return "BlowTorch" end,
    getCurrentUses = function(self) return self.uses end,
    getMaxUses     = function(self) return self.max end,
    setCurrentUses = function(self, v) self.uses = v end,
}
local moddedTorch = {
    hasTag  = function(_, t) return t == "BlowTorch" end,
    getType = function() return "ModdedTorch" end,
    -- no getCurrentUses / getMaxUses / setCurrentUses, on purpose
}

local carried = { realTorch, moddedTorch }
local player = {
    modData = {},
    getModData  = function(self) return self.modData end,
    getInventory = function()
        return {
            getAllEvalRecurse = function()
                return {
                    size = function() return #carried end,
                    get  = function(_, i) return carried[i + 1] end,
                }
            end,
        }
    end,
}

function getPlayer() return player end

local gameStart
Events = { OnGameStart = { Add = function(fn) gameStart = fn end },
           OnPlayerUpdate = { Add = function() end } }

print = function() end
dofile(SOURCE)
print = realPrint

gameStart()
check(option ~= nil, "the Admin Powers option registered")

local function save(selected)
    -- exactly what ISAdminPowerUI:onClick does on SAVE
    option.set({ player = player }, selected)
end

-- ---------------------------------------------------------------------------
-- The halo only fires on a real change
-- ---------------------------------------------------------------------------

halos = {}
save(true)
check(#halos == 1, "turning it ON says so once, got " .. #halos)
check(RCEternalTorch.cheat == true, "ON sets the flag")
check(player.modData.RC_EternalTorch == true, "ON persists to modData")

-- The spam case: vanilla re-applies EVERY option on every SAVE, so this is
-- what an admin toggling some unrelated power actually triggers.
halos = {}
save(true); save(true); save(true)
check(#halos == 0, "re-saving an unchanged ON box is silent, got " .. #halos)
check(RCEternalTorch.cheat == true, "unchanged saves leave the flag ON")
check(player.modData.RC_EternalTorch == true, "unchanged saves keep modData")

halos = {}
save(false)
check(#halos == 1, "turning it OFF says so once, got " .. #halos)
check(RCEternalTorch.cheat == false, "OFF clears the flag")
check(player.modData.RC_EternalTorch == nil, "OFF clears modData rather than storing false")

halos = {}
save(false); save(false)
check(#halos == 0, "re-saving an unchanged OFF box is silent, got " .. #halos)

-- A full cycle still speaks both times - the fix must not mute the feature.
halos = {}
save(true); save(false)
check(#halos == 2, "a real toggle cycle still confirms twice, got " .. #halos)

-- ---------------------------------------------------------------------------
-- The refill skips what it cannot refill
-- ---------------------------------------------------------------------------

realTorch.uses = 3
save(false)          -- reset to a known OFF state without a refill
save(true)           -- ON refills immediately
check(realTorch.uses == 10, "enabling tops the drainable torch to max, got " .. tostring(realTorch.uses))

-- The modded torch has no drainable surface at all; reaching it must not throw.
-- If this file ever calls getCurrentUses unguarded again, dofile-time is clean
-- but THIS is where it blows up.
realTorch.uses = 1
local ok = pcall(save, false)
check(ok, "an OFF save with a non-drainable torch carried does not throw")
ok = pcall(save, true)
check(ok, "an ON save with a non-drainable torch carried does not throw")
check(realTorch.uses == 10, "the drainable torch is still refilled alongside it")

-- An already-full torch is left alone rather than rewritten (the idle steady
-- state must not sync every half second).
realTorch.uses = 10
local writes = 0
local realSet = realTorch.setCurrentUses
realTorch.setCurrentUses = function(self, v) writes = writes + 1; realSet(self, v) end
save(false); save(true)
check(writes == 0, "a full torch is not rewritten, got " .. writes .. " write(s)")

realPrint(string.format("RCEternalTorch: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
