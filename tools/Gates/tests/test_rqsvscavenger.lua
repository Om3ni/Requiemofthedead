-- RQSvScavenger fixture - the load contract, and now the RAGE machinery.
--
-- WHY THE LOAD HALF EXISTS. RQSvScavenger injects its state table into
-- RQSvEating at FILE SCOPE, and until 2026-08-24 it declared no dependency at
-- all - it loaded correctly only because RQServer happened to require
-- RQSvEating first. The Bulwark batch added RQBloodhound, which sorts ahead
-- of RQSvEating in the server's alphabetical walk and requires this file: the
-- injection ran against nil, the throw was swallowed by require's own
-- protectedCall (LuaManager.java:1391), and every Scavenger eaterArrived
-- crashed for the whole Mosaic session.
--
-- WHY THE RAGE HALF EXISTS (added 2026-08-25). The 2026-08-24 deletion of
-- isEnraged/onPlayerHit survived every gate precisely because no fixture
-- loaded the real file and exercised the flip - and extending coverage
-- immediately found a live bug: both onPlayerHit and tick tested
-- `scavID < 0`, the short-wrap class RDZombieId exists for, so past the wrap
-- HALF the Scavenger population could never rage. The negative-id pins below
-- are that regression, held.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvScavenger.lua"
local ZID    = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDZombieId.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvScavenger: " .. message)
    end
end

function isServer() return true end
local nowMs = 100000
function getTimestampMs() return nowMs end

local sounds = 0
function addSound() sounds = sounds + 1 end

-- Engine-surface stubs the CALL-time paths need. Kept narrow on purpose: any
-- new file-scope dereference still fails the load half instead of riding on
-- an accidental stub.
local hpWrites, broadcasts = {}, {}
RQSvShared = {
    getSvConfig  = function() return { screamerSoundRadius = 30 } end,
    svSetZombieHP = function(z, hp, ownerOnly)
        hpWrites[#hpWrites + 1] = { hp = hp, ownerOnly = ownerOnly == true }
        z.health = hp
    end,
    broadcast = function(cmd, args) broadcasts[#broadcasts + 1] = { cmd = cmd, args = args } end,
    due = function(state, key, interval, now)
        if state[key] and now < state[key] then return false end
        state[key] = now + interval
        return true
    end,
    SCAV_CORPSE_RADIUS = 6,
}
local eatingCalls = {}
local function record(name)
    return function(...) eatingCalls[#eatingCalls + 1] = name end
end
local injectedState = nil
RQSvEating = {
    setScavengerState    = function(tbl) injectedState = tbl end,
    svClearEatingIntent  = record("clearIntent"),
    svRemoveEaterFromCast = record("removeFromCast"),
    svSetEatingIntent    = record("setIntent"),
    svCorpseStillThere   = function() return false end,
    svFinalizeEater      = record("finalize"),
    svRestoreAI          = record("restoreAI"),
    svCancelEaterState   = record("cancel"),
    svGluttonFindCorpse  = function() return nil end,
}

local demanded = {}
local realRequire = require
function require(name)
    demanded[name] = true
    if name == "RDZombieId" then dofile(ZID) return end
    if name ~= "RQSvEating" then
        error("unexpected fixture require: " .. tostring(name))
    end
end

RQSvScavenger = nil
local ok, err = pcall(dofile, SOURCE)
require = realRequire
check(ok, "module loads: " .. tostring(err))
check(demanded["RQSvEating"] == true,
    "the file declares its RQSvEating dependency - load order is not a contract")
check(demanded["RDZombieId"] == true,
    "the file declares its RDZombieId dependency - the id rule is Core's, not folklore")
check(injectedState ~= nil and injectedState == RQSvScavenger.state,
    "the eating engine received this module's state table at load")

-- The surfaces the rest of the suite dispatches to must exist after a bare
-- load - RQSvHit calls onPlayerHit, RQBulwark and RQBloodhound call isEnraged,
-- RQServer calls tick.
check(type(RQSvScavenger.onPlayerHit) == "function", "onPlayerHit exists")
check(type(RQSvScavenger.isEnraged) == "function", "isEnraged exists")
check(type(RQSvScavenger.tick) == "function", "tick exists")
check(RQSvScavenger.setActiveZombies == nil,
    "no registry injection - the write-only _activeZombies copy was cut 2026-08-25; type questions go through RQSvShared.typeOf")
check(type(RQSvScavenger.state) == "table", "state table exists")

-- ---------------------------------------------------------------------------
-- A zombie that models the surface the real functions touch.
-- ---------------------------------------------------------------------------
local function makeScav(id, health)
    return {
        id = id, health = health or 2.0, modData = {}, vars = {},
        getOnlineID = function(self) return self.id end,
        getHealth   = function(self) return self.health end,
        getModData  = function(self) return self.modData end,
        transmitModData = function() end,
        getX = function() return 10 end,
        getY = function() return 20 end,
        getZ = function() return 0 end,
        setUseless = function() end,
        setVariable = function(self, k, v) self.vars[k] = v end,
        setEatBodyTarget = function() end,
        clearAggroList = function() end,
        setTarget = function() end,
    }
end
local function lastBroadcast(cmd)
    for i = #broadcasts, 1, -1 do
        if broadcasts[i].cmd == cmd then return broadcasts[i] end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- THE RAGE FLIP
-- ---------------------------------------------------------------------------
local scav = makeScav(500, 2.0)
RQSvScavenger.tick(scav)                       -- builds the state row
local st = RQSvScavenger.state[500]
check(st ~= nil and st.hostile == false, "a fresh scav starts passive")
check(RQSvScavenger.isEnraged(scav) == false, "and isEnraged agrees")

-- Peak tracks upward while passive (well-fed scav is a bigger threat).
scav.health = 3.0
nowMs = nowMs + 1000
RQSvScavenger.tick(scav)
check(st.peakHP == 3.0, "peakHP tracks the high-water mark while passive")

RQSvScavenger.onPlayerHit(scav)
check(st.hostile == true, "one player hit flips it hostile")
check(scav.health == 15.0, "rage HP is peakHP * 5: " .. tostring(scav.health))
check(st.peakHP == 15.0, "and peakHP freezes at the rage ceiling")
check(scav.modData["RQScavHostile"] == true, "the flag persists on the zombie")
check(RQSvScavenger.isEnraged(scav) == true, "isEnraged answers from live state")
check(lastBroadcast("scavRageScream") ~= nil, "the rage scream reaches clients")
check(sounds == 1, "and the world hears it once")

-- The flip cancels any in-flight eating so the survivors get the right share.
local sawClear, sawRemove = false, false
for _, c in ipairs(eatingCalls) do
    if c == "clearIntent" then sawClear = true end
    if c == "removeFromCast" then sawRemove = true end
end
check(sawClear and sawRemove, "raging cancels eating and leaves the shared cast")

-- Duplicate hits are debounced - rage is a one-way flip, not a stack.
local hpBefore, soundsBefore = #hpWrites, sounds
RQSvScavenger.onPlayerHit(scav)
check(#hpWrites == hpBefore and sounds == soundsBefore,
    "a second hit on a raging scav does nothing")

-- A hit on a scav that has never ticked has no state row and must not throw.
local unticked = makeScav(501)
local okHit = pcall(RQSvScavenger.onPlayerHit, unticked)
check(okHit and RQSvScavenger.state[501] == nil,
    "a hit before the first tick is safely ignored")

-- ---------------------------------------------------------------------------
-- THE NEGATIVE-ID REGRESSION. Both onPlayerHit and tick tested `scavID < 0`
-- until 2026-08-25; ids like -10307 are ordinary on any wrapped server.
-- ---------------------------------------------------------------------------
local wrapped = makeScav(-10307, 2.0)
RQSvScavenger.tick(wrapped)
check(RQSvScavenger.state[-10307] ~= nil,
    "a wrapped (negative) id gets a state row - half the population lost this")
RQSvScavenger.onPlayerHit(wrapped)
check(RQSvScavenger.state[-10307].hostile == true,
    "and CAN RAGE - the bug made these scavs permanently passive")

local sentinel = makeScav(-1)
RQSvScavenger.tick(sentinel)
check(RQSvScavenger.state[-1] == nil, "-1 (no id yet) is still refused")

-- ---------------------------------------------------------------------------
-- DECAY: linear push-down, never up, disarmed after the window.
-- ---------------------------------------------------------------------------
-- Halfway through the 10-minute window the target is halfway down.
nowMs = nowMs + 300000
RQSvScavenger.tick(scav)
local w = hpWrites[#hpWrites]
-- peak 15, base 2 (captured at the FIRST tick, before feeding raised health,
-- and never moved by it) -> midpoint 15 - 13*0.5 = 8.5.
check(w and math.abs(w.hp - 8.5) < 0.01,
    "halfway through decay HP targets the midpoint: " .. tostring(w and w.hp))
check(w.ownerOnly == true,
    "decay writes owner-only - recomputed next tick, so a lost write self-heals")

-- Decay never pushes UP: a scav beaten below the curve is left alone.
scav.health = 4.0
local writesBefore = #hpWrites
nowMs = nowMs + 60000
RQSvScavenger.tick(scav)
check(#hpWrites == writesBefore,
    "a scav already below the decay curve is not healed by it")

-- Past the window: one clamp to baseHealth, then the clock disarms.
scav.health = 10.0
nowMs = nowMs + 300000
RQSvScavenger.tick(scav)
check(scav.health == 2.0, "decay ends with a one-time clamp to baseHealth")
check(st.rageStartTime == nil, "and the decay clock is retired")
check(st.hostile == true, "but the scav stays angry forever - that is the design")

-- THE RE-FEEDING FIX: after the clamp, rage-eating gains must not be fought.
scav.health = 6.0
writesBefore = #hpWrites
nowMs = nowMs + 10000
RQSvScavenger.tick(scav)
check(#hpWrites == writesBefore,
    "post-decay feeding is kept - the disarmed clock no longer slams HP back")

-- ---------------------------------------------------------------------------
-- RESTART PICKUP: hostile flag survives via modData, decay clock restarts.
-- ---------------------------------------------------------------------------
local reloaded = makeScav(600, 8.0)
reloaded.modData["RQScavHostile"] = true
reloaded.modData["RQGluttonBaseHealth"] = 2.0
check(RQSvScavenger.isEnraged(reloaded) == true,
    "before any tick, isEnraged falls back to the persisted flag - no window "
    .. "where the hardest target stops defending itself")
RQSvScavenger.tick(reloaded)
local rst = RQSvScavenger.state[600]
check(rst.hostile == true, "the rebuilt row is hostile")
check(rst.baseHealth == 2.0, "baseHealth comes from the persisted value")
check(rst.rageStartTime ~= nil, "and the player gets a fresh decay window")

print(string.format("RQSvScavenger: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
