-- RQSvDormant fixture - exact persistent identity and active/dormant ownership.
--
-- ZombiePopulationManager passes the complete persistentOutfitID into native
-- virtualization and VirtualZombieManager restores that integer unchanged.
-- These pins prevent a weaker outfit-family match from stealing an identity,
-- and prevent a record that is still bound to a live zombie from participating.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQSvDormant: " .. message)
    end
end

function isServer() return true end
local nowMs = 500000
function getTimestampMs() return nowMs end

local gmd = {}
ModData = {
    getOrCreate = function(name)
        gmd[name] = gmd[name] or {}
        return gmd[name]
    end,
}
Events = { OnInitGlobalModData = { Add = function() end } }
function getDebug() return false end
RQSvShared = {
    MAX_NETWORK_HP = 100,
    HEALTH_MULTIPLIER = {
        Screamer = 2, Juggernaut = 10, EMP = 2,
        Glutton = 2, Scavenger = 2, Boss = 10,
    },
}
function require(name)
    if name == "RQSvShared" then return end
    -- The REAL RDShared, not a stub: badNum was promoted into it 2026-08-25
    -- and this module's sanitation keys on that exact test, so a stub would
    -- be the fixture testing itself.
    if name == "RDShared" then dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDShared.lua") return end
    error("unexpected fixture require: " .. tostring(name))
end

RQSvDormant = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
RQSvDormant.DEBUG = false   -- assertions, not prints

-- Build ids the way the engine does. No bit ops in Kahlua OR real 5.1's
-- stdlib, so the fixture composes arithmetically - which is also exactly the
-- claim under test.
local MIN_INT = -2147483648
local function maleId(idx, variant)   return idx * 65536 + variant + 1 end
local function femaleId(idx, variant) return MIN_INT + idx * 65536 + variant + 1 end

-- ---------------------------------------------------------------------------
-- THE IDENTITY. The full id must agree, and only a demoted record is eligible.
-- ---------------------------------------------------------------------------
local pid1 = RQSvDormant.mint()
check(pid1 == "1", "pids mint from 1")
local id1 = maleId(69, 250)
RQSvDormant.record(pid1, "Screamer", 100, 100, 0, id1, 2.0, 1.0, nil, nil)

check(RQSvDormant.hasDormant() == false, "a newly recorded live special is not dormant")
check(RQSvDormant.findMatch(100, 100, 0, id1) == nil,
    "an ordinary zombie cannot steal a still-live special's identity")

RQSvDormant.demote(pid1)
check(RQSvDormant.hasDormant() == true, "demotion makes the identity eligible")
check(RQSvDormant.findMatch(101, 100, 0, id1) == pid1,
    "the exact persisted outfit id matches within the drift radius")
check(RQSvDormant.findMatch(101, 100, 0, maleId(69, 7)) == nil,
    "same outfit family with a different low-half seed does not match")

-- A second, nearer record with a different full id must not beat the exact id.
local pid2 = RQSvDormant.mint()
local id2 = maleId(42, 111)
RQSvDormant.record(pid2, "Glutton", 102, 100, 0, id2, 2.0)
RQSvDormant.demote(pid2)
check(RQSvDormant.findMatch(103, 100, 0, id1) == pid1,
    "a nearer different id cannot steal the exact match")

-- Female ids are negative and retain exact identity too.
local pid3 = RQSvDormant.mint()
local id3 = femaleId(69, 250)
RQSvDormant.record(pid3, "Scavenger", 300, 300, 0, id3, 2.0)
RQSvDormant.demote(pid3)
check(RQSvDormant.findMatch(301, 300, 0, id3) == pid3,
    "a negative female persistent id matches exactly")
check(RQSvDormant.findMatch(301, 300, 0, femaleId(69, 3)) == nil,
    "a female seed mismatch is still a mismatch")

-- No identity evidence means no adoption, even at zero distance.
check(RQSvDormant.findMatch(102, 100, 0, nil) == nil,
    "missing outfit identity refuses instead of falling back to distance")
check(RQSvDormant.findMatch(102, 100, 0, 0) == nil,
    "zero outfit identity refuses")

-- Same floor only.
check(RQSvDormant.findMatch(100, 100, 1, id1) == nil,
    "a record one floor away is not a candidate")

-- Claim is a consume operation and returns the persisted state intact.
local claimedPid, claimed = RQSvDormant.claimMatch(101, 100, 0, id1)
check(claimedPid == pid1 and claimed and claimed.zType == "Screamer",
    "claim returns the matching subtype")
check(claimed and claimed.baseHP == 1.0 and claimed.hp == 2.0,
    "claim carries health evidence")
check(RQSvDormant.findMatch(101, 100, 0, id1) == nil,
    "a claimed identity cannot be claimed twice")

-- ---------------------------------------------------------------------------
-- Registry hygiene the matcher rests on.
-- ---------------------------------------------------------------------------
check(RQSvDormant.findMatch(0/0, 100, 0, nil) == nil, "NaN coordinates refuse")
RQSvDormant.remove(pid2)
check(RQSvDormant.isEmpty() == false, "records remain, isEmpty says so")

print(string.format("RQSvDormant: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
