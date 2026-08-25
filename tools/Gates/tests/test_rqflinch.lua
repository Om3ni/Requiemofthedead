-- RQFlinch fixture - the mechanism half of stagger immunity.
--
-- WHY THIS FILE EXISTS. Two earlier attempts at stagger immunity both failed
-- while looking correct in Lua, and both would still pass a fixture that only
-- checked "did we call the setter". So the thing pinned here is the CONTRACT
-- BETWEEN THE LUA AND THE XML: the variable name RQFlinch writes must be the
-- one media/AnimSets/zombie/hitreaction/RQFlinch.xml keys on. A mismatch fails
-- SILENTLY in game - the node never wins, flinches look normal, and nothing
-- logs - which is precisely the failure mode this suite exists to make loud.
--
-- The last assertion reads the shipped XML and compares it to the Lua. That is
-- deliberate: it is the only part of this feature a Lua-only test can actually
-- prove, and it is the part most likely to rot.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQFlinch.lua"
local NODE   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/AnimSets/zombie/hitreaction/RQFlinch.xml"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQFlinch: " .. message)
    end
end

function isServer() return false end
function isClient() return true end
RQCommon = { MODULE = "RFTDDirge" }

-- The module registers a game-start hook for its node diagnostic. Absent here
-- on purpose in one respect: RQConfig is NOT provided, so the hook must decide
-- it has no debug mode and do nothing rather than raising. Instrumentation must
-- never be the reason a client fails to start.
local startHooks = {}
Events = { OnGameStart = { Add = function(fn) startHooks[#startHooks + 1] = fn end } }

function require(name)
    if name == "RQCommon" then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQFlinch = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local function makeZombie()
    return {
        vars = {},
        setVariable = function(self, k, v) self.vars[k] = v end,
        getVariableBoolean = function(self, k) return self.vars[k] == true end,
    }
end

-- ---------------------------------------------------------------------------
-- Set and clear
-- ---------------------------------------------------------------------------
local z = makeZombie()
check(RQFlinch.set(z, true), "setting suppression reports success")
check(z.vars[RQFlinch.VARIABLE] == true, "the animation variable is set true")
check(RQFlinch.isSet(z) == true, "isSet reads it back")

check(RQFlinch.set(z, false), "clearing suppression reports success")
check(z.vars[RQFlinch.VARIABLE] == false,
    "clearing writes FALSE rather than nil - the graph reads a boolean")
check(RQFlinch.isSet(z) == false, "isSet reflects the clear")

-- A truthy non-boolean must still land as a real boolean, because the XML
-- condition compares against BOOL true.
local z2 = makeZombie()
RQFlinch.set(z2, "yes")
check(z2.vars[RQFlinch.VARIABLE] == true, "a truthy value is normalised to boolean true")

-- ---------------------------------------------------------------------------
-- Nil safety
-- ---------------------------------------------------------------------------
-- Called from a per-frame path over a weak table; a collected zombie must not
-- take the update pass down with it.
check(RQFlinch.set(nil, true) == false, "a nil zombie is refused rather than raising")
check(RQFlinch.isSet(nil) == false, "isSet on nil is false, not an error")

-- ---------------------------------------------------------------------------
-- Counters
-- ---------------------------------------------------------------------------
RQFlinch.reset()
local z3 = makeZombie()
RQFlinch.set(z3, true)
RQFlinch.set(z3, true)
RQFlinch.set(z3, false)
check(RQFlinch.stats.set == 2 and RQFlinch.stats.cleared == 1,
    "set and cleared are counted separately")

-- ---------------------------------------------------------------------------
-- THE LUA/XML CONTRACT
-- ---------------------------------------------------------------------------
-- The half that actually breaks. If these drift, the feature silently does
-- nothing in game and no log line appears anywhere.
local f = io.open(NODE, "r")
check(f ~= nil, "the AnimSets node ships alongside the module")
if f then
    local xml = f:read("*a")
    f:close()
    check(xml:find("<m_Name>" .. RQFlinch.VARIABLE .. "</m_Name>", 1, true) ~= nil,
        "the node keys on exactly the variable RQFlinch writes ("
        .. tostring(RQFlinch.VARIABLE) .. ")")
    check(xml:find("<m_Type>BOOL</m_Type>", 1, true) ~= nil,
        "the condition is typed BOOL, matching setVariable(key, boolean)")
    check(xml:find("<m_ConditionPriority>", 1, true) ~= nil,
        "the node states an explicit priority rather than relying on condition count")
    -- Selection is abstract-ness, then priority, then condition count
    -- (AnimNode.compareSelectionConditions:287-301). Vanilla zombie nodes carry
    -- no explicit priority, so any positive value wins; the assertion is that
    -- we did not ship a zero.
    local priority = tonumber(xml:match("<m_ConditionPriority>(%d+)</m_ConditionPriority>") or "0")
    check(priority > 0, "the priority is positive, so the node outranks vanilla: " .. priority)
    check(xml:find("<m_AnimName>", 1, true) ~= nil,
        "the node names a real animation - an abstract node would lose selection outright")
end

-- ---------------------------------------------------------------------------
-- The diagnostic must be harmless
-- ---------------------------------------------------------------------------
-- It reaches for DebugLog, which may not exist, may not expose getDebugTypes,
-- and may hand back something that is not a list. All three are survivable, and
-- a client that fails to boot because of a temporary probe would be a far worse
-- bug than the one it was added to find.
check(#startHooks == 1, "the module registers its diagnostic on game start")

local hookOk, hookErr = pcall(startHooks[1])
check(hookOk, "the game-start hook survives RQConfig being absent: " .. tostring(hookErr))

check(RQFlinch.armNodeDiagnostic() == false,
    "with no DebugLog at all, the diagnostic declines rather than raising")

DebugLog = { getDebugTypes = function() return nil end }
check(RQFlinch.armNodeDiagnostic() == false, "a nil type list is survivable")

DebugLog = { getDebugTypes = function() return "not a list" end }
check(RQFlinch.armNodeDiagnostic() == false, "a non-list is survivable")

local enabled = {}
local fakeType = setmetatable({}, { __tostring = function() return "Animation" end })
local otherType = setmetatable({}, { __tostring = function() return "Sound" end })
DebugLog = {
    getDebugTypes = function()
        local l = { otherType, fakeType }
        return { size = function() return #l end, get = function(_, i) return l[i + 1] end }
    end,
    setLogEnabled = function(t, on) enabled[tostring(t)] = on end,
}
check(RQFlinch.armNodeDiagnostic() == true, "with a real type list the diagnostic arms")
check(enabled["Animation"] == true, "and enables exactly the Animation channel")
check(enabled["Sound"] == nil, "leaving every other channel alone")

print(string.format("RQFlinch: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
