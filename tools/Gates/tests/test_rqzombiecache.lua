-- RQZombieCache fixture - onlineID -> IsoZombie for this client.
--
-- WHY THIS FILE EXISTS. The cache replaces a 961-grid-square scan that also
-- silently failed (718 DRIFT events in one archive). Replacing a wrong thing
-- with a fast thing is only progress if the fast thing is right, and three of
-- its rules are easy to get wrong in ways nothing would report:
--
--   1. -1 IS THE ONLY INVALID ID. onlineId is a short that wraps negative;
--      the live archive is full of ids like -10307 on ordinary zombies. A
--      positivity check would throw away half the population on any
--      long-running server, and everything would merely look "flaky".
--   2. RECYCLED IDS. A row whose zombie no longer answers to its key must not
--      be returned. Handing back the WRONG BODY is worse than a miss.
--   3. THE DEFERRED NEWBORN. OnZombieCreate fires before the id exists
--      (VirtualZombieManager.java:325 vs the list insert at :327), so the
--      retry path is the normal path, not an edge case - and it must drain.

local ROOT = arg[1] or "."
local LEDGER = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDLedger.lua"
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQZombieCache.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQZombieCache: " .. message)
    end
end

function isServer() return false end
function isClient() return true end
RQCommon = { MODULE = "RFTDDirge" }

local nowMs = 10000
function getTimestampMs() return nowMs end

local hooks = {}
local function event(name)
    hooks[name] = {}
    return { Add = function(fn) hooks[name][#hooks[name] + 1] = fn end }
end
Events = {
    OnZombieCreate = event("create"),
    OnZombieDead   = event("dead"),
    OnTick         = event("tick"),
    OnGameStart    = event("start"),
}

-- The cell, and the list the fallback pass walks. getZombieList returns a
-- java.util.ArrayList, so size/get with a ZERO-based index is the contract.
local cellZombies = {}
local listAccesses = 0
function getCell()
    return {
        getZombieList = function()
            return {
                size = function() return #cellZombies end,
                get  = function(_, i)
                    listAccesses = listAccesses + 1
                    return cellZombies[i + 1]
                end,
            }
        end,
    }
end

function require(name)
    if name == "RQCommon" then return end
    if name == "RDLedger" then dofile(LEDGER) return end
    error("unexpected fixture require: " .. tostring(name))
end

RQZombieCache = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local function makeZombie(id, dead)
    return {
        id = id, dead = dead == true,
        getOnlineID = function(self) return self.id end,
        isDead      = function(self) return self.dead end,
    }
end

local function fireCreate(z) for _, fn in ipairs(hooks["create"]) do fn(z) end end
local function fireDead(z)   for _, fn in ipairs(hooks["dead"])   do fn(z) end end
local function fireTick()    for _, fn in ipairs(hooks["tick"])   do fn() end end

-- ---------------------------------------------------------------------------
-- Storage and the id contract
-- ---------------------------------------------------------------------------
local z1 = makeZombie(500)
fireCreate(z1)
check(RQZombieCache.get(500) == z1, "a newborn with an id is cached at creation")
check(RQZombieCache.count() == 1, "and counted")

-- THE ONE THAT WOULD SILENTLY HALVE THE POPULATION. onlineId is a short and
-- wraps; -10307 is a real id from the live archive, not a sentinel.
local zneg = makeZombie(-10307)
fireCreate(zneg)
check(RQZombieCache.get(-10307) == zneg,
    "a NEGATIVE onlineID is valid and cached - only -1 means 'no id'")

local zsentinel = makeZombie(-1)
fireCreate(zsentinel)
check(RQZombieCache.get(-1) == nil, "-1 is refused as a key")

check(RQZombieCache.get(nil) == nil, "a nil id is nil, not an error")
check(RQZombieCache.get(9999) == nil, "an unknown id misses cleanly")

-- ---------------------------------------------------------------------------
-- RECYCLED IDS
-- ---------------------------------------------------------------------------
-- The rule is three-part on purpose. A row whose zombie has been renumbered
-- must not be handed back under the old key.
local recycled = makeZombie(700)
fireCreate(recycled)
check(RQZombieCache.get(700) == recycled, "cached under its id")
recycled.id = 701
check(RQZombieCache.get(700) == nil,
    "a zombie that no longer answers to the key is NOT returned - wrong body is worse than a miss")

-- Dead zombies are not handed out either.
local corpse = makeZombie(800)
fireCreate(corpse)
corpse.dead = true
check(RQZombieCache.get(800) == nil, "a dead zombie is not returned")

-- ---------------------------------------------------------------------------
-- THE DEFERRED NEWBORN
-- ---------------------------------------------------------------------------
-- OnZombieCreate fires before the id exists, so this is the normal path.
local late = makeZombie(-1)
fireCreate(late)
check(RQZombieCache.stats.deferred >= 1, "a newborn with no id is parked, not dropped")
check(RQZombieCache.count() == 2, "and is not cached under the sentinel")

-- The id arrives; the retry must pick it up.
late.id = 900
nowMs = nowMs + 200
fireTick()
check(RQZombieCache.get(900) == late, "once the id arrives the newborn is filed")

-- A newborn that NEVER gets an id must drain rather than accumulate.
-- Reset first so the count is exact: the -1 sentinel zombie created earlier is
-- also still parked, and asserting against a shared pending list would make
-- this pass for the wrong reason.
RQZombieCache.reset()
local orphan = makeZombie(-1)
fireCreate(orphan)
for _ = 1, 20 do nowMs = nowMs + 200; fireTick() end
check(RQZombieCache.stats.dropped == 1,
    "a newborn that never gets an id is dropped after bounded retries: "
    .. RQZombieCache.stats.dropped)
-- Draining is the point: ticking again must cost nothing and raise nothing.
local okTick = pcall(fireTick)
check(okTick, "ticking an empty pending list is safe")

-- ---------------------------------------------------------------------------
-- Death eviction
-- ---------------------------------------------------------------------------
local dying = makeZombie(1000)
fireCreate(dying)
check(RQZombieCache.get(1000) == dying, "cached")
fireDead(dying)
check(RQZombieCache.get(1000) == nil, "the death hook evicts immediately")

-- ---------------------------------------------------------------------------
-- The fallback pass
-- ---------------------------------------------------------------------------
-- A zombie this client never saw created - the mid-session join case - must
-- still resolve, and the pass should warm everything it walks past.
RQZombieCache.reset()
cellZombies = { makeZombie(11), makeZombie(12), makeZombie(13) }
nowMs = nowMs + 1000
local found = RQZombieCache.get(12)
check(found == cellZombies[2], "an uncached zombie resolves from the cell list")
check(RQZombieCache.stats.warmed == 3,
    "and the pass warms every zombie it walked past: " .. RQZombieCache.stats.warmed)

-- Now a hit must NOT touch the list again.
local before = listAccesses
check(RQZombieCache.get(11) == cellZombies[1], "a warmed zombie reads back")
check(listAccesses == before, "and costs no list access at all")

-- RATE LIMITING. A genuinely absent id must not trigger a pass per call -
-- that would reproduce the per-frame scan this module exists to delete.
local resolvesBefore = RQZombieCache.stats.resolves
for _ = 1, 50 do RQZombieCache.get(4242) end
check(RQZombieCache.stats.resolves == resolvesBefore,
    "50 misses inside the interval trigger no further passes")
nowMs = nowMs + 1000
RQZombieCache.get(4242)
check(RQZombieCache.stats.resolves == resolvesBefore + 1,
    "and exactly one more once the interval has passed")

-- ---------------------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------------------
-- The chunk-unload case: no death event ever fires, so only the ledger sweep
-- reclaims these. This is the leak a death hook alone cannot close.
RQZombieCache.reset()
local ghosts = {}
for i = 1, 10 do
    ghosts[i] = makeZombie(2000 + i)
    fireCreate(ghosts[i])
end
check(RQZombieCache.count() == 10, "ten tracked")
for i = 1, 10 do ghosts[i].dead = true end      -- unloaded, no death event
local rounds = 0
while RQZombieCache.count() > 0 and rounds < 100 do
    RQZombieCache.ledger.sweep()
    rounds = rounds + 1
end
check(RQZombieCache.count() == 0,
    "the sweep reclaims zombies that vanished without a death event")

RQZombieCache.reset()
check(RQZombieCache.count() == 0 and RQZombieCache.stats.warmed == 0,
    "reset clears rows and counters")

print(string.format("RQZombieCache: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
