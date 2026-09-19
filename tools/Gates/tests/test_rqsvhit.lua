-- RQSvHit fixture - one intake, named refusals, and a dispatch order that is
-- a contract.
--
-- WHY THE ORDER IS ASSERTED AS ONE SEQUENCE. Rage runs before healing and
-- pursuit because both read the Scavenger's state; per-stage call counts could
-- all be right while the order between them was wrong, so every stage writes to
-- one log and the log is compared whole.
--
-- The 2026-09-17 retirement of the server-side soak (RQBulwark) took the old
-- fourth stage and the debug probe with it, and put ordinary zombies back on
-- the refusal list: nothing downstream has a use for a hit on a zombie that is
-- not a special. The same day the escort muster (RQSvMuster) took the fourth
-- slot: a notification, so it runs after every stage that changes state.

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
local order = {}
local rageCalls = {}
RQSvScavenger = {
    onPlayerHit = function(z)
        rageCalls[#rageCalls + 1] = z
        order[#order + 1] = "rage"
    end,
}
local mccoyCalls = {}
RQMcCoy = {
    onAttacked = function(ctx)
        mccoyCalls[#mccoyCalls + 1] = ctx
        order[#order + 1] = "mccoy"
    end,
}
local bloodhoundCalls = {}
RQBloodhound = {
    onAttacked = function(ctx)
        bloodhoundCalls[#bloodhoundCalls + 1] = ctx
        order[#order + 1] = "bloodhound"
    end,
}
local musterCalls = {}
RQSvMuster = {
    onAttacked = function(ctx)
        musterCalls[#musterCalls + 1] = ctx
        order[#order + 1] = "muster"
    end,
}
RQDirgeLog = { write = function() end }
local activeZombies = {}
RQSvShared = {
    getSvConfig = function() return {} end,
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
        RQBloodhound = true, RQMcCoy = true, RQSvMuster = true,
    }
    if known[name] then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQSvHit = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(#listeners == 1, "the module registers exactly one OnHitZombie listener")
check(RQSvHit.setActiveZombies == nil,
    "no registry injection - type questions go through RQSvShared.typeOf")
check(RQSvHit.probe == nil, "the soak probe is gone with the soak")

local function makeZombie(opts)
    opts = opts or {}
    local md = opts.modData or {}
    return {
        className = "IsoZombie",
        getOnlineID = function() return opts.id or 42 end,
        getModData  = function() return md end,
        isDead      = function() return opts.dead == true end,
        getHealth   = function() return opts.hp or 4.0 end,
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

-- An ordinary zombie is a refusal again. It reached dispatch only so the soak
-- could ask whether an aura covered it; the soak is gone and so is the reason.
local ordinary = makeZombie{ id = 7 }
order, rageCalls, mccoyCalls, bloodhoundCalls = {}, {}, {}, {}
fire(ordinary, player, nil, meleeWeapon())
check(refusedCount("not-special") == 1, "an ordinary zombie is refused by name")
check(#mccoyCalls == 0 and #bloodhoundCalls == 0 and #rageCalls == 0 and #musterCalls == 0,
    "and reaches no module at all")

check(RQSvHit.stats.dispatched == 0, "no refused hit reached dispatch")
check(RQSvHit.stats.seen == 5, "every call is counted as seen, refused or not")

-- ---------------------------------------------------------------------------
-- The registry is consulted before modData
-- ---------------------------------------------------------------------------
-- A special that has fallen out of the live registry but still carries RQType
-- in its own modData is still a special. That is the path a reloaded zombie
-- takes before the orchestrator re-adopts it.
local reloaded = makeZombie{ id = 9, modData = { RQType = "Boss" } }
mccoyCalls = {}
fire(reloaded, player, nil, meleeWeapon())
check(#mccoyCalls == 1,
    "a special known only by modData is treated as a special, not as ordinary")
check(mccoyCalls[1].zType == "Boss", "and its context carries the modData type")

-- ---------------------------------------------------------------------------
-- The order, as one sequence
-- ---------------------------------------------------------------------------
local scav = makeZombie{ id = 3 }
activeZombies[scav] = "Scavenger"
order = {}
fire(scav, player, nil, rangedWeapon())
check(table.concat(order, ",") == "rage,mccoy,bloodhound,muster",
    "a Scavenger hit runs rage, then healing, then pursuit, then the muster: " .. table.concat(order, ","))

order = {}
fire(jugg, player, nil, rangedWeapon())
check(table.concat(order, ",") == "mccoy,bloodhound,muster",
    "a Juggernaut hit skips rage and keeps the rest in order: " .. table.concat(order, ","))

-- ---------------------------------------------------------------------------
-- Ranged classification
-- ---------------------------------------------------------------------------
-- isRanged(), not isAimedFirearm() - a decided policy, wider than RQDread's
-- firearm band, so a crossbow counts.
bloodhoundCalls = {}
fire(scav, player, nil, rangedWeapon())
check(bloodhoundCalls[1].isRanged == true, "a ranged weapon is classified ranged")

bloodhoundCalls = {}
fire(scav, player, nil, meleeWeapon())
check(bloodhoundCalls[1].isRanged == false, "a melee weapon is classified melee")

-- Bare hands and shoves arrive with no weapon at all; that must not throw and
-- must not read as ranged.
rageCalls, bloodhoundCalls = {}, {}
local threw = not pcall(fire, scav, player, nil, nil)
check(not threw, "an unarmed hit does not throw")
check(#rageCalls == 1 and bloodhoundCalls[1].isRanged == false,
    "an unarmed hit still reaches rage and reads as melee")

-- A non-HandWeapon item has no isRanged method. Presence test, not a pcall.
rageCalls, bloodhoundCalls = {}, {}
threw = not pcall(fire, scav, player, nil, notAWeapon())
check(not threw, "an item with no isRanged method does not throw")
check(#rageCalls == 1 and bloodhoundCalls[1].isRanged == false,
    "an item with no isRanged method still dispatches, as melee")

-- ---------------------------------------------------------------------------
-- Dispatch is type-gated
-- ---------------------------------------------------------------------------
rageCalls = {}
fire(jugg, player, nil, meleeWeapon())
check(#rageCalls == 0, "a Juggernaut hit does not reach Scavenger rage")

local boss = makeZombie{ id = 5 }
activeZombies[boss] = "Boss"
rageCalls = {}
fire(boss, player, nil, rangedWeapon())
check(#rageCalls == 0, "a Boss hit does not reach Scavenger rage")

-- The context every module reads, carried whole.
local ctx = bloodhoundCalls[#bloodhoundCalls]
check(ctx.zombie == boss and ctx.attacker == player and ctx.isPlayerAttack == true
    and ctx.now == clock, "the context carries zombie, attacker, the player flag and the clock")
check(musterCalls[#musterCalls] == ctx, "and the muster reads the very same context, not a copy")

print(string.format("RQSvHit: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
