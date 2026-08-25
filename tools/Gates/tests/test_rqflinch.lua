-- RQFlinch fixture - the mechanism half of stagger immunity.
--
-- WHY THIS FILE EXISTS. Three attempts at stagger immunity failed while
-- looking correct in Lua, and all three would still pass a fixture that only
-- checked "did we call the setter". So the thing pinned here is the CONTRACT
-- BETWEEN THE LUA AND THE XML: the variable name RQFlinch writes must be the
-- one every node in media/AnimSets/zombie/*/RQFlinch.xml keys on, and each
-- node must still carry the events its state depends on. A mismatch fails
-- SILENTLY in game - the node never wins, flinches look normal, and nothing
-- logs - which is precisely the failure mode this suite exists to make loud.
--
-- The XML block at the bottom reads every shipped node and compares it to the
-- Lua. That is deliberate: it is the only part of this feature a Lua-only test
-- can prove, and it is the part most likely to rot.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQFlinch.lua"
local ANIMSETS = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/AnimSets/zombie/"

-- Every node in the family, with the per-node expectations that must not
-- drift. `fallOnFront` mirrors vanilla exactly - it is what routes onground
-- into the matching getup - and `cancelKnockDown` states which value the node
-- carries (bwd's false is vanilla's own, and a no-op by
-- ZombieHitReactionState.java:103).
local NODES = {
    { path = "hitreaction/RQFlinch.xml",
      cancelKnockDown = "true" },
    { path = "hitreaction-shothead-fwd/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "true" },
    { path = "hitreaction-shothead-fwd02/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "true" },
    { path = "hitreaction-shothead-bwd/RQFlinch.xml",
      cancelKnockDown = "false", fallOnFront = "false" },
    { path = "getup-fromOnBack/RQFlinch.xml",  setOnFloor = true },
    { path = "getup-fromOnFront/RQFlinch.xml", setOnFloor = true },
}

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

local startHooks = {}
Events = { OnGameStart = { Add = function(fn) startHooks[#startHooks + 1] = fn end } }

function require(name)
    if name == "RQCommon" then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQFlinch = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- The fake implements the VERIFIED engine surface and nothing else, so a call
-- to a method the engine does not expose fails here rather than in game
-- (CLAUDE.md section 2). Every method below was read out of the 42.20.3
-- decompile: setVariable/getVariableBoolean on IsoGameCharacter,
-- getCurrentActionContextStateName at :1473, setStateEventDelayTimer at
-- IsoMovingObject.java:1960.
local function makeZombie()
    return {
        vars = {}, state = "idle", timer = 30.0,
        staggered = false, reaction = "",
        setVariable = function(self, k, v) self.vars[k] = v end,
        getVariableBoolean = function(self, k) return self.vars[k] == true end,
        getCurrentActionContextStateName = function(self) return self.state end,
        setStateEventDelayTimer = function(self, v) self.timer = v end,
        isStaggerBack  = function(self) return self.staggered end,
        getHitReaction = function(self) return self.reaction end,
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
-- isReacting - BOTH lanes
-- ---------------------------------------------------------------------------
-- The bug that cost the first shipped attempt. CombatManager resolves a hit
-- into EITHER a named reaction OR a stagger, never both (:2410-2417). A bullet
-- always takes the reaction branch, so watching staggerBack alone sees
-- nothing at all from gunfire.
local r = makeZombie()
check(RQFlinch.isReacting(r) == false, "an untouched zombie is not reacting")

r.staggered = true
check(RQFlinch.isReacting(r) == true, "the melee lane: staggerBack counts")
r.staggered = false

r.reaction = "ShotChestStepL"
check(RQFlinch.isReacting(r) == true, "the gunfire lane: a hit reaction counts")

r.reaction = ""
check(RQFlinch.isReacting(r) == false,
    "an EMPTY reaction string is not a reaction - the engine clears it to \"\" on exit")

-- ---------------------------------------------------------------------------
-- releaseStagger - the melee lane
-- ---------------------------------------------------------------------------
-- stateEventDelayTimer is a GENERIC countdown. ZombieEatBodyState:55 and
-- ZombieIdleState:81 wait on the same field, so zeroing it outside staggerback
-- would cut short unrelated behaviour - including our own Gluttons mid-meal.
-- The narrow gate is the whole safety argument and is pinned here.
local s = makeZombie()
s.state = "idle"
check(RQFlinch.releaseStagger(s) == false, "an idle zombie is refused")
check(s.timer == 30.0, "and its timer is untouched")

s.state = "eatbody"
RQFlinch.releaseStagger(s)
check(s.timer == 30.0, "a Glutton mid-meal keeps its timer - this is the dangerous case")

s.state = "staggerback"
check(RQFlinch.releaseStagger(s) == true, "a staggering zombie is released")
check(s.timer == 0.0, "by zeroing the timer its exit transition waits on")

-- The state name comes from a folder name and vanilla compares these with
-- equalsIgnoreCase throughout (PlayerSitOnFurnitureState.java:120).
local s2 = makeZombie()
s2.state = "StaggerBack"
check(RQFlinch.releaseStagger(s2) == true, "the state name is matched case-insensitively")

-- ---------------------------------------------------------------------------
-- observe - the witness
-- ---------------------------------------------------------------------------
-- Measures how long a reaction LASTS, which is the effect we care about
-- rather than a proxy for it. A vanilla reaction animation runs about a
-- second, so a span of one or two frames can only mean our node won.
RQFlinch.reset()
local o = makeZombie()
check(RQFlinch.observe(o, 1000) == nil, "a quiet zombie produces no span")

o.reaction = "ShotChestStepL"
check(RQFlinch.observe(o, 1000) == nil, "the frame a reaction STARTS produces nothing")
check(RQFlinch.observe(o, 1016) == nil, "nor does one still in progress")

o.reaction = ""
local span = RQFlinch.observe(o, 1032)
check(span ~= nil, "the frame it ENDS produces the completed span")
check(span.frames == 2, "with every reacting frame counted: " .. tostring(span and span.frames))
check(span.ms == 32, "and the wall-clock duration: " .. tostring(span and span.ms))
check(RQFlinch.stats.spans == 1, "the span is counted")
check(RQFlinch.stats.longest == 32, "and tracked as the worst so far")

check(RQFlinch.observe(o, 1100) == nil, "a closed span is not reported twice")

-- A longer reaction must displace the record; that is the number that tells
-- the owner whether the node is winning.
o.reaction = "ShotChestStepL"
RQFlinch.observe(o, 2000)
o.reaction = ""
local slow = RQFlinch.observe(o, 3200)
check(slow.ms == 1200, "a full-speed reaction is measured too")
check(RQFlinch.stats.longest == 1200, "and becomes the new worst case")

-- ---------------------------------------------------------------------------
-- Nil safety
-- ---------------------------------------------------------------------------
-- Called from a per-frame path over a weak table; a collected zombie must not
-- take the update pass down with it.
check(RQFlinch.set(nil, true) == false, "a nil zombie is refused rather than raising")
check(RQFlinch.isSet(nil) == false, "isSet on nil is false, not an error")
check(RQFlinch.isReacting(nil) == false, "isReacting on nil is false")
check(RQFlinch.releaseStagger(nil) == false, "releaseStagger on nil is false")
check(RQFlinch.observe(nil, 0) == nil, "observe on nil is nil")

-- ---------------------------------------------------------------------------
-- Counters and lifecycle
-- ---------------------------------------------------------------------------
RQFlinch.reset()
local z3 = makeZombie()
RQFlinch.set(z3, true)
RQFlinch.set(z3, true)
RQFlinch.set(z3, false)
check(RQFlinch.stats.set == 2 and RQFlinch.stats.cleared == 1,
    "set and cleared are counted separately")

check(#startHooks == 1, "the module registers exactly one game-start hook")
local hookOk, hookErr = pcall(startHooks[1])
check(hookOk, "and it runs cleanly: " .. tostring(hookErr))
check(RQFlinch.stats.set == 0 and RQFlinch.stats.spans == 0,
    "the game-start hook resets the counters for the new session")

-- ---------------------------------------------------------------------------
-- THE LUA/XML CONTRACT
-- ---------------------------------------------------------------------------
-- The half that actually breaks. If these drift, the feature silently does
-- nothing in game and no log line appears anywhere.
for _, node in ipairs(NODES) do
    local label = node.path
    local f = io.open(ANIMSETS .. node.path, "r")
    check(f ~= nil, label .. " ships alongside the module")
    if f then
        local xml = f:read("*a")
        f:close()
        check(xml:find("<m_Name>" .. RQFlinch.VARIABLE .. "</m_Name>", 1, true) ~= nil,
            label .. " keys on exactly the variable RQFlinch writes ("
            .. tostring(RQFlinch.VARIABLE) .. ")")
        check(xml:find("<m_Type>BOOL</m_Type>", 1, true) ~= nil,
            label .. ": the condition is typed BOOL, matching setVariable(key, boolean)")

        -- Selection is abstract-ness, then priority, then condition count
        -- (AnimNode.compareSelectionConditions:287-301), and AnimState.addNode
        -- (:78-91) inserts highest-first. Vanilla zombie nodes leave the
        -- priority at its 0 default (AnimNode.java:45-46), so any positive
        -- value wins; the assertion is that we did not ship a zero.
        local priority = tonumber(xml:match("<m_ConditionPriority>(%d+)</m_ConditionPriority>") or "0")
        check(priority > 0, label .. ": positive priority outranks vanilla: " .. priority)

        check(xml:find("<m_AnimName>", 1, true) ~= nil,
            label .. " names a real animation - an abstract node would lose selection outright")

        -- m_SpeedScale is the entire mechanism: every covered state exits on
        -- <eventOccurred>ActiveAnimFinishing</eventOccurred>, so a fast
        -- animation is a short state. Shipping a 1.0 would load, win, and do
        -- nothing.
        local speed = tonumber(xml:match("<m_SpeedScale>([%d%.]+)</m_SpeedScale>") or "1")
        check(speed >= 5, label .. ": the speed scale actually shortens the state: " .. speed)

        -- THE KNOCKDOWN HALF. ZombieHitReactionState.animEvent (:103-109) is
        -- the only thing that floors a zombie during a hit reaction, and it is
        -- driven entirely by these events. No node of ours may request one.
        check(xml:find("<m_EventName>KnockDown</m_EventName>", 1, true) == nil,
            label .. " never REQUESTS a knockdown")
        if node.cancelKnockDown then
            check(xml:find("<m_EventName>CancelKnockDown</m_EventName>%s*<m_Time>Start</m_Time>%s*"
                    .. "<m_ParameterValue>" .. node.cancelKnockDown .. "</m_ParameterValue>") ~= nil,
                label .. ": CancelKnockDown carries vanilla's value (" .. node.cancelKnockDown .. ")")
        end

        -- FallOnFront routes onground into the MATCHING getup
        -- (actiongroups/zombie/onground/to_getup-fromOn*.xml condition
        -- fallOnFront); flipping it would play a back-getup from a front fall.
        if node.fallOnFront then
            check(xml:find("<m_EventName>FallOnFront</m_EventName>%s*<m_Time>Start</m_Time>%s*"
                    .. "<m_ParameterValue>" .. node.fallOnFront .. "</m_ParameterValue>") ~= nil,
                label .. ": FallOnFront matches vanilla (" .. node.fallOnFront .. ")")
        end

        -- SetOnFloor(false) is what actually clears bOnFloor on the way up; a
        -- getup node without it leaves the zombie logically on the floor.
        if node.setOnFloor then
            check(xml:find("<m_EventName>SetOnFloor</m_EventName>", 1, true) ~= nil,
                label .. " keeps the SetOnFloor event that clears bOnFloor")
        end
    end
end

print(string.format("RQFlinch: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
