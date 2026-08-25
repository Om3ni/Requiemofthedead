-- RQPoise fixture - Bulwarks do not flinch, full stop.
--
-- WHY THIS FILE EXISTS. A .45 kept a Boss staggered for an entire encounter
-- (owner, 2026-08-24). This file covers the POLICY - WHO stops caring about
-- being shot. The mechanism that makes it true lives in RQFlinch and is
-- covered by test_rqflinch.
--
-- REWRITTEN 2026-08-25 when the policy became flat immunity (owner decision).
-- The absorb-a-rolled-count-then-break cycle is gone, and with it the three
-- things this fixture used to guard. What replaces them is narrower but
-- catches the failures the new shape can actually have:
--   1. QUALIFYING. A passive Scavenger is not a tank; only an enraged one is.
--      Getting this wrong makes the sleeper-threat design pointless.
--   2. HANDING THE FLINCH BACK. Immunity latches on the zombie, so a zombie
--      that stops qualifying and is not released stays permanently
--      unflinchable - and because the variable lives on the engine object,
--      nothing in Lua would show it.
--   3. NOT REWRITING EVERY FRAME. The variable is read back rather than
--      shadowed, so the write must happen only when it is actually missing.
--      A regression here is invisible in game and costs a write per frame per
--      Bulwark.

local ROOT = arg[1] or "."
local ZID    = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDZombieId.lua"
local LEDGER = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDLedger.lua"
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQPoise.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQPoise: " .. message)
    end
end

function isServer() return false end
function isClient() return true end

local types = {}
RQRegistry = { getType = function(id) return types[id] end }

-- The mechanism, recorded rather than simulated. RQPoise's job is to decide
-- WHO should stop caring about being shot; RQFlinch's job is to make that
-- true. This fixture asserts the decision, and test_rqflinch covers the
-- mechanism separately.
local setCalls, releaseCalls = {}, 0
local nextSpan = nil
RQFlinch = {
    set = function(zombie, on)
        setCalls[#setCalls + 1] = { zombie = zombie, on = on }
        zombie.flinch = on and true or false
        return true
    end,
    -- Reads the engine back, exactly as production does. Defaults to false so
    -- a fresh zombie looks like one that has never been written to.
    isSet = function(zombie) return zombie.flinch == true end,
    releaseStagger = function() releaseCalls = releaseCalls + 1; return true end,
    observe = function() local s = nextSpan; nextSpan = nil; return s end,
}
RQReconcile = { scavClientState = {} }

local logLines = {}
RQDirgeLog = { write = function(_, line) logLines[#logLines + 1] = line end }
RQCommon = { MODULE = "RFTDDirge" }

local callbacks = {}
local function event(name)
    callbacks[name] = {}
    return { Add = function(fn) callbacks[name][#callbacks[name] + 1] = fn end }
end
Events = { OnZombieUpdate = event("update"), OnGameStart = event("start") }

function require(name)
    local known = { RQCommon = true, RQDirgeLog = true, RQRegistry = true,
                    RQReconcile = true, RQFlinch = true }
    if known[name] then return end
    if name == "RDZombieId" then dofile(ZID) return end
    -- The real ledger, for the same reason test_rqflinch loads it.
    if name == "RDLedger" then dofile(LEDGER) return end
    error("unexpected fixture require: " .. tostring(name))
end

local nowMs = 10000
function getTimestampMs() return nowMs end

RQPoise = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(#callbacks["update"] == 1, "the module registers exactly one OnZombieUpdate listener")

-- No setVariable / setStaggerBack / setKnockedDown / setStateEventDelayTimer
-- on this fake ON PURPOSE. Poise delegates every engine write to RQFlinch, so
-- if a future change starts writing flags here directly, this fixture throws
-- rather than quietly passing.
local function makeZombie(id, remote)
    return {
        id = id,
        flinch = nil,
        getOnlineID    = function(self) return self.id end,
        isDead         = function() return false end,
        isRemoteZombie = function() return remote == true end,
    }
end

-- ---------------------------------------------------------------------------
-- Qualifying
-- ---------------------------------------------------------------------------
local boss = makeZombie(1)
types[1] = "Boss"
RQPoise.update(boss, nowMs)
check(boss.flinch == true, "a Boss is made immune on its first update")
check(#setCalls == 1, "and that took exactly one write")
check(RQPoise.stats.guarded == 1, "the Boss is counted as guarded")
check(RQPoise.stats.byType["Boss"] == 1, "and counted against its type")

-- THE PER-FRAME COST. The variable latches on the engine object, so once it
-- reads back true there is nothing to write.
for _ = 1, 20 do RQPoise.update(boss, nowMs) end
check(#setCalls == 1,
    "immunity is asserted once, not re-written every frame: " .. #setCalls)
check(RQPoise.stats.guarded == 1, "and the zombie is only counted once")

-- SELF-HEALING. A chunk reload rebuilds the zombie with an empty variable
-- slot; the next update must notice and re-assert rather than trust a cache.
boss.flinch = nil
RQPoise.update(boss, nowMs)
check(boss.flinch == true, "immunity is re-asserted after the variable is lost")
check(#setCalls == 2, "which is the second and only other write")

-- THE MELEE LANE runs for every qualifying update - it no-ops internally
-- unless the zombie is genuinely mid-staggerback.
check(releaseCalls > 0, "releaseStagger is offered the zombie each pass")

-- ---------------------------------------------------------------------------
-- THE NEGATIVE onlineID
-- ---------------------------------------------------------------------------
-- Shipped broken until 2026-08-25 as `if not onlineID or onlineID <= 0 then
-- return end`. IsoZombie.onlineId is a SHORT (IsoZombie.java:325) that wraps
-- past 32767 into negative numbers, and the engine's own validity test is
-- always `== -1` - never `< 0`. The live reflect archive is full of ordinary
-- zombies with ids like -10307. That test therefore denied stagger immunity to
-- roughly half the population on any long-running server, and every symptom of
-- it read as "Bulwarks are flaky" rather than as an id bug.
--
-- Nothing else in the suite pins this, so it is pinned here.
local wrapped = makeZombie(-10307)
types[-10307] = "Boss"
RQPoise.update(wrapped, nowMs)
check(wrapped.flinch == true,
    "a Boss past the short wrap (id -10307) still gets immunity")

-- 0 is a legitimate id too; only -1 is the engine's sentinel.
local zeroId = makeZombie(0)
types[0] = "Boss"
RQPoise.update(zeroId, nowMs)
check(zeroId.flinch == true, "id 0 is valid as well - only -1 is 'no id'")

local noId = makeZombie(-1)
types[-1] = "Boss"
RQPoise.update(noId, nowMs)
check(noId.flinch == nil, "id -1 IS refused - it means the zombie has no identity yet")

-- ---------------------------------------------------------------------------
-- Who does NOT qualify
-- ---------------------------------------------------------------------------
local plain = makeZombie(2)
types[2] = "Screamer"
RQPoise.update(plain, nowMs)
check(plain.flinch == nil,
    "a Screamer is left staggerable - being fragile is the point")

local unknown = makeZombie(3)
RQPoise.update(unknown, nowMs)
check(unknown.flinch == nil, "an unregistered zombie is left alone entirely")

-- A remote zombie belongs to another client; deciding for it would have two
-- machines fighting over the same variable.
local remote = makeZombie(4, true)
types[4] = "Boss"
RQPoise.update(remote, nowMs)
check(remote.flinch == nil, "a remote zombie is skipped - its owner decides")

-- ---------------------------------------------------------------------------
-- The Scavenger rule
-- ---------------------------------------------------------------------------
-- A passive Scavenger is a sleeper threat and takes full stagger. Only rage
-- makes it a Bulwark.
local scav = makeZombie(5)
types[5] = "Scavenger"
RQPoise.update(scav, nowMs)
check(scav.flinch == nil, "a passive Scavenger is NOT immune")

RQReconcile.scavClientState[5] = { enraged = true }
RQPoise.update(scav, nowMs)
check(scav.flinch == true, "an enraged Scavenger is")

-- ...and losing the row hands the flinch back, exactly once.
local releasedBefore = RQPoise.stats.released
RQReconcile.scavClientState[5] = nil
RQPoise.update(scav, nowMs)
check(scav.flinch == false,
    "a Scavenger that stops qualifying is handed its flinch back")
check(RQPoise.stats.released == releasedBefore + 1, "and is counted as released")

RQPoise.update(scav, nowMs)
check(RQPoise.stats.released == releasedBefore + 1,
    "releasing is idempotent - a non-qualifying zombie costs nothing after")

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
check(pcall(RQPoise.update, nil, nowMs), "a nil zombie is refused rather than raising")

local dead = makeZombie(6)
types[6] = "Boss"
dead.isDead = function() return true end
RQPoise.update(dead, nowMs)
check(dead.flinch == nil, "a dead zombie is not worth an engine call")

-- (the -1 case is covered above, alongside the ids that must NOT be refused)

-- ---------------------------------------------------------------------------
-- Bounded instrumentation
-- ---------------------------------------------------------------------------
-- Span logging is the only evidence RQFlinch's node is winning selection, so
-- it is worth having - but a long firefight must not turn the log into a
-- per-hit stream. CLAUDE.md section 14: instrumentation is bounded or it does
-- not ship.
RQPoise.reset()
logLines = {}
local logged = makeZombie(7)
types[7] = "Boss"
for i = 1, 200 do
    nextSpan = { ms = 40, frames = 2 }
    RQPoise.update(logged, nowMs + i)
end
check(RQPoise.stats.logged < 200, "span logging stops well short of one line per hit")
check(RQPoise.stats.logged == #logLines,
    "every counted span produced exactly one line: "
    .. RQPoise.stats.logged .. " vs " .. #logLines)
check(logLines[1]:find("frames", 1, true) ~= nil,
    "and the line reports the frame count, which is the number that settles it")
local capped = RQPoise.stats.logged
for i = 1, 50 do
    nextSpan = { ms = 40, frames = 2 }
    RQPoise.update(logged, nowMs + 200 + i)
end
check(RQPoise.stats.logged == capped,
    "and the cap holds - further spans are counted but silent: " .. RQPoise.stats.logged)

-- ---------------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------------
RQPoise.reset()
check(RQPoise.stats.guarded == 0 and RQPoise.stats.released == 0
    and RQPoise.stats.logged == 0, "reset clears every counter")
-- pairs, not next: Kahlua has no next() and the suite does not use it even in
-- fixtures, so a copied line never carries it into shipping code (CLAUDE.md 3).
local remaining = 0
for _ in pairs(RQPoise.stats.byType) do remaining = remaining + 1 end
check(remaining == 0, "including the per-type table")

print(string.format("RQPoise: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
