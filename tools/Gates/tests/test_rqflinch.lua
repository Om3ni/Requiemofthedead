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
local LEDGER = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDLedger.lua"
local ANIMSETS = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/AnimSets/zombie/"

-- Every node in the family, with the per-node expectations that must not
-- drift. `fallOnFront` is what routes onground into the matching getup, so it
-- mirrors vanilla in every case. `cancelKnockDown` states the value OUR node
-- carries, which is usually vanilla's and deliberately is not in two places:
-- shothead-bwd keeps vanilla's false (a no-op by
-- ZombieHitReactionState.java:103), while the two leg knockdowns pass true
-- where vanilla passes false - leaving the flag set is what lets the next hit
-- chain another knockdown, which is the thing being prevented.
--
-- GREW FROM SIX TO FIFTEEN on 2026-08-25 (floor-state enumeration): the three
-- floor states a shot can land in while the zombie is already down or getting
-- up, and the six knockdown states a SIDELONG crit can reach without ever
-- touching the shothead chain. The completeness check at the bottom of this
-- file exists because of that growth - a node not listed here is a node no
-- assertion in this file ever reads.
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

    -- shot while already down / mid-getup. Vanilla's nodes here emit KnockDown
    -- and run unscaled, so these two states were the live re-arm path.
    { path = "hitreaction-onfloor/RQFlinchBack.xml",
      cancelKnockDown = "true" },
    { path = "hitreaction-onfloor/RQFlinchFront.xml",
      cancelKnockDown = "true",  fallOnFront = "true" },
    { path = "hitreaction-gettingUp/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "true" },

    -- the sidelong-crit knockdown lane
    { path = "knockeddown-shotChestL/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "false", setOnFloor = true },
    { path = "knockeddown-shotChestR/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "false", setOnFloor = true },
    { path = "knockeddown-shotLegL/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "true",  setOnFloor = true },
    { path = "knockeddown-shotLegR/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "true",  setOnFloor = true },
    { path = "knockeddown-shotShoulderL/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "false" },
    { path = "knockeddown-shotShoulderR/RQFlinch.xml",
      cancelKnockDown = "true",  fallOnFront = "false" },
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
    -- The REAL ledger, not a stub: RQFlinch's span table now depends on its
    -- liveness semantics, and a stub that merely stored rows would let a
    -- lifetime regression pass green here - which is the whole failure mode
    -- the ledger exists to end.
    if name == "RDLedger" then dofile(LEDGER) return end
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
        staggered = false, reaction = "", dead = false,
        -- The span ledger's liveness rule calls this, so the fake implements
        -- it. A fixture that omitted it would fail loudly here rather than
        -- quietly in game, which is the point of modelling the real surface.
        isDead = function(self) return self.dead end,
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
-- observe - the ROUTE
-- ---------------------------------------------------------------------------
-- A duration alone says the suppression lost; it does not say where. The route
-- names the action-context states the zombie actually passed through, which is
-- the only evidence that can settle whether a suppressed hit reaction leaves
-- `hitreaction` for the knockdown lane - a question the animation graph cannot
-- answer, because vanilla's own node cancels the knockdown while vanilla still
-- ships six populated knockdown states. See hitreaction/RQFlinch.xml.
RQFlinch.reset()
local rt = makeZombie()
rt.reaction = "ShotChestStepL"

rt.state = "hitreaction"          ; RQFlinch.observe(rt, 0)
rt.state = "hitreaction"          ; RQFlinch.observe(rt, 16)   -- unchanged, not re-recorded
rt.state = "knockeddown-shotChestL"; RQFlinch.observe(rt, 32)
rt.state = "onground"             ; RQFlinch.observe(rt, 48)
rt.reaction = ""
local routed = RQFlinch.observe(rt, 64)

check(routed ~= nil, "a routed span still completes")
check(#routed.route == 3,
    "one entry per state CHANGE, not per frame: " .. tostring(routed and #routed.route))
check(RQFlinch.routeText(routed) == "hitreaction, knockeddown-shotChestL, onground",
    "the route reads as the lane it took: " .. tostring(RQFlinch.routeText(routed)))

-- The whole reason this instrumentation exists: a knockdown inside a
-- suppressed reaction is NAMED, not merely long.
check(RQFlinch.routeText(routed):find("knockeddown", 1, true) ~= nil,
    "a knockdown in the route is visible in the text")

-- BOUNDED. A reaction that somehow never ends must not accumulate one entry
-- per frame - the row is per-zombie and lives until the span closes.
RQFlinch.reset()
local runaway = makeZombie()
runaway.reaction = "ShotChestStepL"
for i = 1, 40 do
    runaway.state = "state" .. i
    RQFlinch.observe(runaway, i * 16)
end
runaway.reaction = ""
local capped = RQFlinch.observe(runaway, 1000)
check(#capped.route == 8,
    "the route is capped rather than unbounded: " .. tostring(capped and #capped.route))

-- A zombie whose state machine has no current state yet must not poison the
-- route with a nil, and must not stop the span being measured.
RQFlinch.reset()
local quiet = makeZombie()
quiet.getCurrentActionContextStateName = function() return nil end
quiet.reaction = "ShotChestStepL"
RQFlinch.observe(quiet, 0)
quiet.reaction = ""
local noRoute = RQFlinch.observe(quiet, 32)
check(noRoute ~= nil and noRoute.ms == 32, "a span with no readable state still measures")
check(#noRoute.route == 0, "and records no route entries")
check(RQFlinch.routeText(noRoute) == nil,
    "routeText answers nil for an empty route so the caller can omit the clause")
check(RQFlinch.routeText(nil) == nil, "and nil for no span at all")

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

-- ---------------------------------------------------------------------------
-- COMPLETENESS - every shipped node is listed above
-- ---------------------------------------------------------------------------
-- The loop above is driven by NODES, so a node added to the artifact without a
-- row here is a node that NOTHING checks: it could emit KnockDown, ship a 1.0
-- speed scale, or key on a misspelled variable, and this file would stay green
-- while the feature quietly stopped working for that state. That was a
-- tolerable hole at six nodes and is not at fifteen.
--
-- io.popen because Lua 5.1 has no directory listing, and it is GUARDED rather
-- than assumed: if the shell is unavailable the check reports itself skipped
-- instead of passing. A skipped check that says so is honest; one that returns
-- true because it could not look is the exact failure this file exists to
-- prevent elsewhere.
do
    local listed = {}
    for _, node in ipairs(NODES) do listed[node.path] = true end

    -- dir wants the whole pattern inside ONE pair of quotes, and backslashes:
    -- a forward-slash path with the quote closed before the filename is the
    -- shape that silently matched nothing on the first attempt.
    local winPath = ANIMSETS:gsub("/", "\\")
    local ok, pipe = pcall(io.popen,
        'dir /b /s "' .. winPath .. 'RQFlinch*.xml" 2>nul')
    if not ok or not pipe then
        print("SKIP RQFlinch: no shell - node completeness unverified")
    else
        local found, unlisted = 0, {}
        for line in pipe:lines() do
            -- Keep the last two path segments: "<state>/RQFlinch*.xml"
            local rel = line:match("([^\\]+\\[^\\]+)$")
            if rel then
                rel = rel:gsub("\\", "/")
                found = found + 1
                if not listed[rel] then unlisted[#unlisted + 1] = rel end
            end
        end
        pipe:close()
        check(found > 0, "the node sweep found nothing - the glob or path is wrong")
        check(#unlisted == 0,
            "shipped node(s) missing from NODES, so no assertion reads them: "
            .. table.concat(unlisted, ", "))
        check(found == #NODES,
            "node count drift: " .. found .. " on disk, " .. #NODES .. " listed")
    end
end

print(string.format("RQFlinch: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
