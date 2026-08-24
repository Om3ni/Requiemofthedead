-- RQSvHit fixture - one intake, one listener, a named reason for every refusal.
--
-- This is the file that has to stay honest as Slices 2-4 land on it. Three more
-- combat responsibilities are going to be dispatched from here, and the whole
-- reason the intake exists is that their ORDER is a contract rather than an
-- accident of engine registration order. What is pinned below is the shape of
-- that contract: exactly one listener, validation that names why it turned a
-- hit away, and a context whose fields downstream modules can rely on.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvHit.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvHit: " .. message)
    end
end

function isServer() return true end
function instanceof(value, className) return value ~= nil and value.className == className end

local clock = 12345
function getTimestampMs() return clock end

local listeners = {}
Events = { OnHitZombie = { Add = function(fn) listeners[#listeners + 1] = fn end } }

-- The module hard-requires its siblings. The fixture answers with the surface
-- it actually touches, and errors on anything unexpected, so a new dependency
-- appearing in production shows up here rather than at runtime.
local rageCalls = {}
-- ONE log, written by every stage. Order is the contract this file exists to
-- protect, so it is asserted against a single sequence rather than per-stage
-- call counts that could both be right while the order between them is wrong.
local order = {}
RQSvScavenger = {
    onPlayerHit = function(z)
        rageCalls[#rageCalls + 1] = z
        order[#order + 1] = "rage"
    end,
}
local bulwarkCalls = {}
RQBulwark = {
    resolve = function(ctx)
        bulwarkCalls[#bulwarkCalls + 1] = ctx
        order[#order + 1] = "bulwark"
    end,
}
RQDirgeLog = { write = function() end }
local debugMode = false
local activeZombies = {}
RQSvShared = {
    getSvConfig = function() return { debugMode = debugMode } end,
    -- The real resolver's contract: registry first, the zombie's own RQType
    -- second. RQSvHit deliberately owns no copy of the registry.
    typeOf = function(z)
        if not z then return nil end
        return activeZombies[z] or z:getModData()["RQType"]
    end,
}
RQCommon = { MODULE = "RFTDDirge" }

function require(name)
    local known = {
        RQCommon = true, RQDirgeLog = true, RQSvShared = true, RQSvScavenger = true,
        RQBulwark = true,
    }
    if known[name] then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQSvHit = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---------------------------------------------------------------------------
-- One listener
-- ---------------------------------------------------------------------------
check(#listeners == 1, "the module registers exactly one OnHitZombie listener")
check(RQSvHit.setActiveZombies == nil,
    "the intake keeps no registry of its own - it asks RQSvShared.typeOf")

local function makeZombie(opts)
    opts = opts or {}
    local md = opts.modData or {}
    return {
        className = "IsoZombie",
        getOnlineID    = function() return opts.id or 42 end,
        getModData     = function() return md end,
        isDead         = function() return opts.dead == true end,
        getHealth      = function() return opts.hp or 4.0 end,
        getOwnerPlayer = function() return opts.owner end,
        isRemoteZombie = function() return opts.remote == true end,
    }
end

local player = { className = "IsoPlayer" }
local zed = { className = "IsoZombie" }

local function rangedWeapon() return { isRanged = function() return true end } end
local function meleeWeapon()  return { isRanged = function() return false end } end
-- An InventoryItem that is not a HandWeapon carries no isRanged at all. Reading
-- an absent method yields nil rather than throwing, which is why the intake
-- tests for presence instead of wrapping the call.
local function notAWeapon()   return { getName = function() return "Base.Rock" end } end

local fire = listeners[1]

-- ---------------------------------------------------------------------------
-- Refusals, each with its own name
-- ---------------------------------------------------------------------------
local function refusedCount(reason) return RQSvHit.stats.refused[reason] or 0 end

fire(nil, player, nil, nil)
check(refusedCount("no-zombie") == 1, "a missing zombie is refused by name")

local jugg = makeZombie()
activeZombies[jugg] = "Juggernaut"

fire(jugg, nil, nil, nil)
check(refusedCount("no-wielder") == 1, "a missing wielder is refused by name")

-- Zombie-on-zombie and environmental damage both reach Hit(). Only a player
-- attack is a provocation any downstream responsibility cares about.
fire(jugg, zed, nil, nil)
check(refusedCount("not-player") == 1, "a non-player attacker is refused by name")

local corpse = makeZombie{ dead = true }
activeZombies[corpse] = "Juggernaut"
fire(corpse, player, nil, nil)
check(refusedCount("already-dead") == 1, "a dead zombie is refused by name")

local ordinary = makeZombie{ id = 7 }
fire(ordinary, player, nil, meleeWeapon())
check(refusedCount("not-special") == 1, "an ordinary zombie is refused by name")

check(RQSvHit.stats.dispatched == 0, "no refused hit reached dispatch")
check(RQSvHit.stats.seen == 5, "every call is counted as seen, refused or not")

-- ---------------------------------------------------------------------------
-- The registry is consulted before modData
-- ---------------------------------------------------------------------------
-- A special that has fallen out of the live registry but still carries RQType
-- in its own modData is still a special. That is the path a reloaded zombie
-- takes before the orchestrator re-adopts it.
local reloaded = makeZombie{ id = 9, modData = { RQType = "Boss" } }
fire(reloaded, player, nil, meleeWeapon())
check(RQSvHit.stats.dispatched == 1, "a special known only by modData still dispatches")

-- ---------------------------------------------------------------------------
-- Ranged classification
-- ---------------------------------------------------------------------------
-- isRanged(), not isAimedFirearm() - a decided policy, wider than the shipped
-- RQSuppress band, so a crossbow counts.
local scav = makeZombie{ id = 3 }
activeZombies[scav] = "Scavenger"

rageCalls = {}
fire(scav, player, nil, rangedWeapon())
check(#rageCalls == 1, "a ranged hit on a Scavenger reaches rage")

rageCalls = {}
fire(scav, player, nil, meleeWeapon())
check(#rageCalls == 1, "a melee hit on a Scavenger reaches rage")

-- Bare hands and shoves arrive with no weapon at all; that must not throw and
-- must not read as ranged.
rageCalls = {}
local threw = not pcall(fire, scav, player, nil, nil)
check(not threw, "an unarmed hit does not throw")
check(#rageCalls == 1, "an unarmed hit still reaches rage")

-- A non-HandWeapon item has no isRanged method. Presence test, not a pcall.
rageCalls = {}
threw = not pcall(fire, scav, player, nil, notAWeapon())
check(not threw, "an item with no isRanged method does not throw")
check(#rageCalls == 1, "an item with no isRanged method still dispatches")

-- ---------------------------------------------------------------------------
-- Dispatch is type-gated
-- ---------------------------------------------------------------------------
-- The listener this replaced tested the type before calling rage. Relying
-- instead on onPlayerHit finding no state row for a Juggernaut would work by
-- accident; the intake knows the type, so the intake states it.
rageCalls = {}
fire(jugg, player, nil, meleeWeapon())
check(#rageCalls == 0, "a Juggernaut hit does not reach Scavenger rage")

local boss = makeZombie{ id = 5 }
activeZombies[boss] = "Boss"
rageCalls = {}
fire(boss, player, nil, rangedWeapon())
check(#rageCalls == 0, "a Boss hit does not reach Scavenger rage")

-- ---------------------------------------------------------------------------
-- The probe is debug-gated and bounded
-- ---------------------------------------------------------------------------
local before = RQSvHit.probe.logged
fire(scav, player, nil, meleeWeapon())
check(RQSvHit.probe.logged == before, "the probe is silent while DebugMode is off")

debugMode = true
RQSvHit.probe.ownerServer, RQSvHit.probe.ownerClient = 0, 0
fire(scav, player, nil, meleeWeapon())
check(RQSvHit.probe.logged == before + 1, "the probe records once DebugMode is on")
check(RQSvHit.probe.ownerServer == 1,
    "a zombie with no owner is counted as server-authoritative")

-- The Slice 1 question in one counter: who owns the target. A nil owner means
-- this server is authoritative (IsoZombie.java:454-456).
local owned = makeZombie{ id = 8, owner = { className = "IsoPlayer" }, remote = true }
activeZombies[owned] = "Juggernaut"
fire(owned, player, nil, rangedWeapon())
check(RQSvHit.probe.ownerClient == 1, "a client-owned zombie is counted separately")
check(RQSvHit.probe.remoteFlag >= 1, "isRemoteZombie is recorded alongside ownership")

-- Bounded: the log stops, the counters do not. An unbounded per-hit line in a
-- release artifact is exactly what the working rules forbid.
RQSvHit.probe.logged = 200          -- PROBE_LOG_MAX
local suppressedBefore = RQSvHit.probe.suppressed
local rangedBefore = RQSvHit.probe.ranged
fire(scav, player, nil, rangedWeapon())
check(RQSvHit.probe.logged == 200, "the probe log stops at its cap")
check(RQSvHit.probe.suppressed == suppressedBefore + 1, "suppressed lines are counted")
check(RQSvHit.probe.ranged == rangedBefore + 1, "counters keep running past the log cap")

debugMode = false

-- ---------------------------------------------------------------------------
-- ORDER IS THE CONTRACT
-- ---------------------------------------------------------------------------
-- Bulwark resolves LAST. A soaked hit is still an attack: it must still enrage a
-- Scavenger, and once Slices 3 and 4 land it must still arm healing and still
-- mark a shooter. Mitigation running first would make a well-armoured target
-- progressively harder to provoke, which is backwards.
order, rageCalls, bulwarkCalls = {}, {}, {}
fire(scav, player, nil, rangedWeapon())
check(#order == 2, "both stages ran for a Scavenger hit")
check(order[1] == "rage", "rage runs first")
check(order[2] == "bulwark", "Bulwark resolves last")

-- A type with no rage stage still reaches Bulwark - the ordering must not be
-- accidentally chained through the stage before it.
order, bulwarkCalls = {}, {}
fire(jugg, player, nil, meleeWeapon())
check(order[1] == "bulwark" and #order == 1,
    "a Juggernaut reaches Bulwark without passing through rage")

-- ---------------------------------------------------------------------------
-- The context Bulwark is handed
-- ---------------------------------------------------------------------------
bulwarkCalls = {}
fire(jugg, player, nil, rangedWeapon())
local ctx = bulwarkCalls[1]
check(ctx ~= nil, "Bulwark receives a context")
check(ctx.zombie == jugg, "context carries the struck zombie")
check(ctx.attacker == player, "context carries the attacker")
check(ctx.zType == "Juggernaut", "context carries the resolved type")
check(ctx.isRanged == true, "context carries the ranged verdict")
check(ctx.isPlayerAttack == true, "context asserts this is a player attack")
check(ctx.now == clock, "context carries one timestamp read, not a fresh clock per stage")

bulwarkCalls = {}
fire(jugg, player, nil, nil)
check(bulwarkCalls[1].isRanged == false, "an unarmed hit is not ranged")
check(bulwarkCalls[1].weapon == nil, "an unarmed hit carries no weapon")

print(string.format("RQSvHit: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
