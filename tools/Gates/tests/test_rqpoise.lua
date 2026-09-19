-- RQPoise fixture - both lanes.
--
-- MELEE: the fallback branch, the gates, and the two constants. The assertion
-- that matters most is that the reaction name is not one of the TEN the
-- knockdown transitions compare against - picking one turns every shove into
-- the knockdown this file exists to prevent, and it shipped once in the lab
-- (HeadLeft, lab FINDINGS F23). The list is copied from
-- media/actiongroups/zombie/hitreaction/to_knockeddown-*.xml, not recalled.
--
-- GUNFIRE: the animation variable the thirteen AnimSets nodes key on. What a
-- fixture can prove is the BOOKKEEPING - every registered special is covered,
-- the variable is taken back when a zombie leaves the registry or the dial
-- goes off, a rebuilt zombie is re-asserted - and that the node files exist
-- with the right condition. Whether the nodes win selection is Mosaic's to say.

local ROOT = arg[1] or "."
local LUA = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua"
local NODES = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/AnimSets/zombie/hitreaction/"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQPoise: " .. message) end
end

-- ---------------------------------------------------------------------------
-- Engine surface
-- ---------------------------------------------------------------------------
local cfg = { poise = true }
RQConfig = { get = function() return cfg end }
RQRegistry = {
    activeZombies = {},
    isSpecial = function(oid) return RQRegistry.activeZombies[oid] ~= nil end,
}
local world = {}
RQCore = { findZombieByID = function(oid) return world[oid] end }

local clockMs = 500000
function getTimestampMs() return clockMs end
function instanceof(obj, className) return obj ~= nil and obj.__class == className end

local hitHandler, tickHandler, startHandler
Events = {
    OnWeaponHitCharacter = { Add = function(fn) hitHandler = fn end },
    OnTick               = { Add = function(fn) tickHandler = fn end },
    OnGameStart          = { Add = function(fn) startHandler = fn end },
}
function require(name)
    if name == "RQConfig" or name == "RQRegistry" then return end
    error("unexpected fixture require: " .. tostring(name))
end

-- The attacker. `vars` is the animation-variable bag processHit reads from.
local function makePlayer(isLocal)
    local p = { __class = "IsoPlayer", vars = {}, isLocal = isLocal ~= false }
    p.isLocalPlayer     = function(s) return s.isLocal end
    p.getVariableString = function(s, k) return s.vars[k] or "" end
    p.setVariable       = function(s, k, v) s.vars[k] = v end
    return p
end

-- A zombie carries the same bag; getVariableBoolean must answer false for an
-- unset key exactly as the engine does (IAnimationVariableSource.java:34-37).
local function makeZombie(oid, opts)
    opts = opts or {}
    local z = { __class = "IsoZombie", vars = {},
        getOnlineID = function() return oid end,
        isDead      = function() return opts.dead == true end,
        isOnFloor   = function() return opts.floor == true end,
    }
    z.getVariableBoolean = function(s, k) return s.vars[k] == true end
    z.setVariable        = function(s, k, v) s.vars[k] = v end
    return z
end

RQPoise = nil
local ok, err = pcall(dofile, LUA .. "/client/RQPoise.lua")
check(ok, "module loads: " .. tostring(err))
check(type(hitHandler) == "function" and type(tickHandler) == "function"
    and type(startHandler) == "function", "hit, tick and game-start listeners register")

-- ---------------------------------------------------------------------------
-- The constants
-- ---------------------------------------------------------------------------
check(RQPoise.VARIABLE == "ZombieHitReaction",
    "the attacker variable is the one processHit reads (CombatManager.java:2383)")
check(RQPoise.REACTION == "ShotBellyStep", "the melee reaction is ShotBellyStep")
check(RQPoise.POISED == "RQPoised", "the zombie variable is the one the nodes condition on")

local FLOOR_ROUTE = {
    HeadLeft = true, HeadRight = true, HeadTop = true, Uppercut = true,
    ShotChestStepL = true, ShotChestStepR = true,
    ShotLegL = true, ShotLegR = true,
    ShotShoulderL = true, ShotShoulderR = true,
}
check(not FLOOR_ROUTE[RQPoise.REACTION],
    "the melee reaction has NO knockdown route - not among the ten to_knockeddown-*.xml names")

-- The thirteen nodes: every one conditions on RQPoised, at 20x, under its own
-- RQPoise name, and one of them is the melee reaction's. A host-side check
-- (Kahlua registers no `io`), which is where this fixture runs.
local NODE_NAMES = {
    "ShotBelly", "ShotBellyStep", "ShotBellyStepBehind", "ShotChestL", "ShotChestR",
    "ShotChestStepL", "ShotChestStepR", "ShotLegL", "ShotLegR", "ShotShoulderL",
    "ShotShoulderR", "ShotShoulderStepL", "ShotShoulderStepR",
}
local found = 0
for _, n in ipairs(NODE_NAMES) do
    local f = io.open(NODES .. "RQPoise" .. n .. ".xml", "r")
    if f then
        local body = f:read("*a"); f:close()
        local okNode = body:find("<m_Name>RQPoise" .. n .. "</m_Name>", 1, true)
            and body:find("<m_Name>RQPoised</m_Name>", 1, true)
            and body:find("<m_Value>" .. n .. "</m_Value>", 1, true)
            and body:find("<m_SpeedScale>20.00</m_SpeedScale>", 1, true)
            and body:find("<m_ConditionPriority>100</m_ConditionPriority>", 1, true)
            and not body:find("BZPois", 1, true)
        check(okNode, "node " .. n .. " is renamed, conditions on RQPoised + its string, at 20x, priority 100")
        found = found + 1
    end
end
check(found == 13, "all thirteen gunfire nodes ship: " .. found)
local lookup = {}
for _, n in ipairs(NODE_NAMES) do lookup[n] = true end
check(lookup[RQPoise.REACTION], "the melee reaction has a fast node behind it")

-- ---------------------------------------------------------------------------
-- The melee seam
-- ---------------------------------------------------------------------------
local p = RQPoise.plan("", true)
check(p.write == true and p.name == "ShotBellyStep" and p.reason == "fallback",
    "an unnamed hit is the fallback branch and gets named")
p = RQPoise.plan(nil, true)
check(p.write == true and p.reason == "fallback", "nil is treated as unnamed")
p = RQPoise.plan("HeadTop", true)
check(p.write == false and p.reason == "named" and p.had == "HeadTop",
    "a swing that named its own reaction is left completely alone")
p = RQPoise.plan("", false)
check(p.write == false and p.reason == "off", "the dial refuses before anything else")

-- ---------------------------------------------------------------------------
-- The melee listener
-- ---------------------------------------------------------------------------
RQRegistry.activeZombies = { [10] = "Juggernaut", [12] = "Screamer", [13] = "Boss" }
local player = makePlayer()
local jugg = makeZombie(10)

hitHandler(player, jugg)
check(player.vars.ZombieHitReaction == "ShotBellyStep",
    "a shove at a Juggernaut names the reaction instead of leaving the stagger")
check(RQPoise.stats.named == 1, "and it is counted")

-- The engine clears the variable as the swing exits (SwipeStatePlayer.java:438).
player.vars.ZombieHitReaction = nil
hitHandler(player, makeZombie(12))
check(player.vars.ZombieHitReaction == "ShotBellyStep" and RQPoise.stats.named == 2,
    "a Screamer is named too - every registered special, not only the tanks")

player.vars.ZombieHitReaction = nil
hitHandler(player, makeZombie(13))
check(RQPoise.stats.named == 3, "and a Boss")

player.vars.ZombieHitReaction = "HeadTop"
hitHandler(player, jugg)
check(player.vars.ZombieHitReaction == "HeadTop",
    "an armed swing keeps the reaction its own animation assigned")
check(RQPoise.stats.left == 1, "and that is counted as left-alone, not as a write")

local function freshHit(target, who)
    local pl = who or makePlayer()
    pl.vars.ZombieHitReaction = nil
    hitHandler(pl, target)
    return pl
end
local pl = freshHit(makeZombie(99))
check(pl.vars.ZombieHitReaction == nil and RQPoise.stats.skipped.ordinary == 1,
    "an ordinary zombie is left to vanilla, and the refusal is counted")
local remote = makePlayer(false)
remote.vars.ZombieHitReaction = nil
hitHandler(remote, jugg)
check(remote.vars.ZombieHitReaction == nil and RQPoise.stats.skipped.remote == 1,
    "a non-local wielder is refused - only the attacking client runs processHit")
RQRegistry.activeZombies[14] = "Juggernaut"
pl = freshHit(makeZombie(14, { dead = true }))
check(pl.vars.ZombieHitReaction == nil and RQPoise.stats.skipped.dead == 1, "a dead zombie is refused")
RQRegistry.activeZombies[15] = "Juggernaut"
pl = freshHit(makeZombie(15, { floor = true }))
check(pl.vars.ZombieHitReaction == nil and RQPoise.stats.skipped.floor == 1,
    "a zombie already on the floor is refused")
pl = freshHit(makeZombie(-1))
check(pl.vars.ZombieHitReaction == nil and RQPoise.stats.skipped.noid == 1,
    "a zombie with no online id is refused")
pl = freshHit(makePlayer())
check(RQPoise.stats.skipped.notzombie == 1, "a non-zombie target is refused")
RQRegistry.activeZombies[14], RQRegistry.activeZombies[15] = nil, nil

cfg.poise = false
pl = freshHit(jugg)
check(pl.vars.ZombieHitReaction == nil, "the dial turns the melee lane off")
cfg.poise = true

-- ---------------------------------------------------------------------------
-- The gunfire lane
-- ---------------------------------------------------------------------------
local function place(oid) world[oid] = makeZombie(oid); return world[oid] end
local zJugg, zScreamer, zBoss = place(10), place(12), place(13)
local zPlain = place(99)
local resolve = RQCore.findZombieByID

RQPoise.assertPass(resolve, true)
check(zJugg.vars.RQPoised == true and zScreamer.vars.RQPoised == true and zBoss.vars.RQPoised == true,
    "every registered special is marked for compression, Boss included")
check(zPlain.vars.RQPoised == nil, "an ordinary zombie is never touched, so vanilla picks its own node")

local afterFirst = RQPoise.stats.gunfire.set
RQPoise.assertPass(resolve, true)
check(RQPoise.stats.gunfire.set == afterFirst,
    "a second pass writes nothing - the value is read back, not re-asserted blindly")

zJugg.vars.RQPoised = nil
RQPoise.assertPass(resolve, true)
check(zJugg.vars.RQPoised == true, "a rebuilt zombie is re-asserted on the next pass")

world[13] = nil
local beforeMissing = RQPoise.stats.gunfire.missing
RQPoise.assertPass(resolve, true)
check(RQPoise.stats.gunfire.missing > beforeMissing,
    "a special that is not loaded here is counted, not treated as an error")
world[13] = zBoss

-- THE TAKE-BACK: a zombie that leaves the registry loses the variable, once.
RQRegistry.activeZombies[12] = nil
RQPoise.assertPass(resolve, true)
check(zScreamer.vars.RQPoised == false and RQPoise.stats.gunfire.cleared == 1,
    "a zombie that stops being special has it taken back")
RQPoise.assertPass(resolve, true)
check(RQPoise.stats.gunfire.cleared == 1, "the take-back happens once, not every pass")

-- The dial going off mid-session takes it back from everything.
RQPoise.assertPass(resolve, false)
check(zJugg.vars.RQPoised == false and zBoss.vars.RQPoised == false,
    "turning the dial off clears every asserted zombie")
RQPoise.assertPass(resolve, true)
check(zJugg.vars.RQPoised == true, "and turning it back on re-asserts them")

-- The tick is a one-second cadence over the same pass.
local passes = RQPoise.stats.gunfire.passes
tickHandler()
check(RQPoise.stats.gunfire.passes == passes + 1, "the first tick runs a pass")
tickHandler()
check(RQPoise.stats.gunfire.passes == passes + 1, "a tick inside the second does not")
clockMs = clockMs + 1000
tickHandler()
check(RQPoise.stats.gunfire.passes == passes + 2, "a second later it runs again")

print(string.format("RQPoise: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
