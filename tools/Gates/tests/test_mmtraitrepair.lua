-- test_mmtraitrepair.lua - live shadowed-trait repair transaction.
--
-- A repair is safe only when it either makes every requested swap and pushes the
-- resulting authoritative list, or returns an explicit partial failure without
-- synchronizing a character whose final trait set is uncertain.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir/42/media/lua/server/Memoirs/MMTraitRepair.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

function isServer() return true end
require = function() end
Events = { OnServerStarted = { Add = function() end } }
Capability = { CanModifyPlayerStatsInThePlayerStatsUI = "cap" }

local base = { id = "base:organized" }
local shadow = { id = "seinar:organized" }
MMShared = {
    fqid = function(trait) return trait and trait.id end,
    findTrait = function(id)
        if id == "base:organized" then return base end
        return nil
    end,
    autoFixShadowedTraits = function() return false end,
}
CharacterTraitDefinition = {
    getCharacterTraitDefinition = function(trait)
        if trait == shadow then
            return { getCost = function() return 0 end, isFree = function() return true end }
        end
        return nil
    end,
}
local active, syncs, warnings = nil, 0, {}
MMRoster = { findOnline = function(name)
    if active and active:getUsername() == name then return active end
    return nil
end }
function sendSyncPlayerFields() syncs = syncs + 1 end
function MMwarn(message) warnings[#warnings + 1] = tostring(message) end
function MMname(player) return player:getUsername() end

local function player(name, options)
    options = options or {}
    local known = { shadow }
    local function remove(trait)
        for i = #known, 1, -1 do
            if known[i] == trait then table.remove(known, i) end
        end
    end
    local function add(trait)
        if options.failAdd then error("simulated trait add failure") end
        if options.silentAdd then return end
        for _, present in ipairs(known) do
            if present == trait then return end
        end
        known[#known + 1] = trait
    end
    local traits = {
        getKnownTraits = function()
            return {
                size = function() return #known end,
                get = function(_, index) return known[index + 1] end,
            }
        end,
        remove = function(_, trait) remove(trait) end,
        add = function(_, trait) add(trait) end,
    }
    return {
        getUsername = function() return name end,
        isDead = function() return false end,
        getCharacterTraits = function() return traits end,
        modifyTraitXPBoost = function() end,
        has = function(_, trait)
            for _, present in ipairs(known) do
                if present == trait then return true end
            end
            return false
        end,
    }
end

local okLoad, loadErr = pcall(dofile, TARGET)
if not okLoad then
    print("FATAL: could not load " .. TARGET)
    print("  " .. tostring(loadErr))
    os.exit(2)
end

local function reset(options)
    syncs, warnings = 0, {}
    active = player("alice", options)
end

-- The default remains a non-mutating inspection, even though the target is live.
reset()
local result = MMTraitRepair.runOne("admin", "alice", false)
eq("dry run succeeds", result.ok, true)
eq("dry run reports one candidate", result.found, 1)
eq("dry run performs no repair", result.repaired, 0)
eq("dry run leaves shadow in place", active:has(shadow), true)
eq("dry run does not sync", syncs, 0)

-- A complete swap is verified before its one client sync.
reset()
result = MMTraitRepair.runOne("admin", "alice", true)
eq("complete swap succeeds", result.ok, true)
eq("complete swap reports repair", result.repaired, 1)
eq("complete swap removes shadow", active:has(shadow), false)
eq("complete swap adds vanilla", active:has(base), true)
eq("complete swap syncs once", syncs, 1)

-- A failure after removal is not retryable: the server must report partial state
-- and must not push an uncertain list to the client.
reset({ failAdd = true })
result = MMTraitRepair.runOne("admin", "alice", true)
eq("late add failure is refused", result.ok, false)
eq("late add failure is partial", result.partial, true)
eq("late add failure reports no completed swap", result.repaired, 0)
eq("late add failure leaves no shadow", active:has(shadow), false)
eq("late add failure does not sync", syncs, 0)

-- Engine add is normally deterministic, but exact verification makes an
-- integration fault that silently drops the vanilla replacement visible too.
reset({ silentAdd = true })
result = MMTraitRepair.runOne("admin", "alice", true)
eq("silent replacement loss is refused", result.ok, false)
eq("silent replacement loss is partial", result.partial, true)
eq("silent replacement loss names verification", warnings[1]:find("phase=verify", 1, true) ~= nil, true)
eq("silent replacement loss does not sync", syncs, 0)

print(string.format("MMTraitRepair: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
