-- RQSvLivery fixture - the server dresses, verifies, and tells the right clients.
--
-- The fakes MODEL THE ENGINE'S ORDER, which is the point of the assertions:
-- dressInPersistentOutfitID clears the visuals BEFORE it tests the id
-- (IsoZombie.java:3898-3905), so a name that does not resolve leaves a naked
-- zombie whose naked id then goes out on the wire. A fake that merely records
-- the requested name could never reproduce that failure.

local ROOT = arg[1] or "."
local LUA = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL RQSvLivery: " .. message) end
end

function isServer() return true end
function isClient() return false end

-- ---------------------------------------------------------------------------
-- Engine surface
-- ---------------------------------------------------------------------------
-- Which outfit names the server can resolve. Ids are arbitrary non-zero.
local registered = {
    RQ_Juggernaut = 0x10001, RQ_Glutton = 0x20001, RQ_Scavenger = 0x30001,
    RQ_ScavengerEnraged = 0x40001, RQ_Screamer = 0x50001, RQ_EMP = 0x60001,
    RQ_BossJuggernaut = 0x70001, RQ_BossDevourer = 0x80001,
    RQ_BossScreamer = 0x90001, RQ_BossEMP = 0xA0001,
}

-- The Boss's body roll. Scripted so the fixture can steer which body comes
-- up; the range asked for is recorded so an out-of-set roll would show.
local nextRoll, rollRanges = 0, {}
function ZombRand(n) rollRanges[#rollRanges + 1] = n; return nextRoll end

local function zombie(oid, x, y, initialID)
    local z = { oid = oid, x = x, y = y, id = initialID or 777, dresses = {} }
    z.getOnlineID = function(s) return s.oid end
    z.getX = function(s) return s.x end
    z.getY = function(s) return s.y end
    z.getPersistentOutfitID = function(s) return s.id end
    -- IsoGameCharacter.java:1735-1740: resolve by name, then dress by id.
    z.dressInPersistentOutfit = function(s, name)
        s.dresses[#s.dresses + 1] = name
        s:dressInPersistentOutfitID(registered[name] or 0)
    end
    -- IsoZombie.java:3898-3905: the id is taken whatever it is; 0 = naked.
    z.dressInPersistentOutfitID = function(s, id)
        s.dresses[#s.dresses + 1] = id
        s.id = id
    end
    return z
end

-- The near-players send is RQSvShared's (promoted 2026-09-17; its window
-- geometry is asserted in test_rqsvshared). Here it is a seam that records
-- the call and answers with however many players the fixture says are near.
local nearCount = 2
local sent, logged, printed = {}, {}, {}
local function capturePrint()
    print = function(line) printed[#printed + 1] = tostring(line) end
end
RQSvShared = {
    sendNear = function(zombie, cmd, args)
        sent[#sent + 1] = { zombie = zombie, cmd = cmd, args = args }
        return nearCount
    end,
}
RQDirgeLog = { write = function(zType, msg) logged[#logged + 1] = { zType = zType, msg = msg } end }
RQCommon = { MODULE = "RFTDDirge" }

local realRequire = require
function require(name)
    if name == "RQLivery" then
        HairOutfitDefinitions = {}
        dofile(LUA .. "/shared/RQLivery.lua")
        return
    end
    if name == "RQCommon" or name == "RQSvShared" or name == "RQDirgeLog" then return end
    error("unexpected fixture require: " .. tostring(name))
end

RQSvLivery = nil
local ok, err = pcall(dofile, LUA .. "/server/RQSvLivery.lua")
require = realRequire
check(ok, "module loads: " .. tostring(err))
capturePrint()

-- ---------------------------------------------------------------------------
-- Conversion-time dress
-- ---------------------------------------------------------------------------
local jugg = zombie(10, 0, 0, 777)
check(RQSvLivery.svDressForType(jugg, "Juggernaut") == true, "a Juggernaut dresses")
check(jugg.id == registered.RQ_Juggernaut, "and its persistent outfit id is the livery's")
check(jugg.dresses[1] == "RQ_Juggernaut", "dressed by NAME on the server - the id is minted here")
check(#sent == 1 and sent[1].zombie == jugg,
    "one repaint goes through the shared near-players send, around the zombie that was dressed")
check(sent[1].cmd == "zombieLivery" and sent[1].args.onlineID == 10 and sent[1].args.outfit == "RQ_Juggernaut",
    "the repaint carries the id and the outfit NAME")
check(#logged == 1 and logged[1].zType == "Juggernaut", "one diagnostic line, attributed to the type")
check(#printed == 0, "a successful dress prints nothing to the console")
check(RQSvLivery.stats.dressed == 1 and RQSvLivery.stats.repaints == 2, "counters record the dress and the recipients")

-- Boss: borrows one of four bodies, chosen by a server-side roll.
local sentBefore = #sent
nextRoll = 2
local boss = zombie(11, 5, 5, 555)
check(RQSvLivery.svDressForType(boss, "Boss") == true, "a Boss is dressed")
check(boss.id == registered.RQ_BossScreamer, "roll 2 gave it the Screamer body in gold")
check(rollRanges[#rollRanges] == 4, "the roll asks for exactly the four bodies")
check(#sent == sentBefore + 1 and sent[#sent].args.outfit == "RQ_BossScreamer",
    "and the repaint carries the body it drew")
nextRoll = 0
local boss2 = zombie(12, 5, 5, 555)
check(RQSvLivery.svDressForType(boss2, "Boss") and boss2.id == registered.RQ_BossJuggernaut,
    "roll 0 gives the Juggernaut body")
check(#rollRanges == 2, "no other type rolls - the Juggernaut above asked for nothing")

-- Every liveried type dresses into ITS outfit, and the Scavenger into the
-- passive one.
for zType, outfitName in pairs(RQLivery.OUTFIT) do
    local z = zombie(20, 5, 5)
    check(RQSvLivery.svDressForType(z, zType) and z.id == registered[outfitName],
        zType .. " dresses into " .. outfitName)
end

-- ---------------------------------------------------------------------------
-- THE UNRESOLVED PATH. Missing content on the server must be loud and must
-- not leave a naked zombie behind.
-- ---------------------------------------------------------------------------
registered.RQ_Screamer = nil
local screamer = zombie(30, 5, 5, 4242)
sentBefore = #sent
check(RQSvLivery.svDressForType(screamer, "Screamer") == false, "an unresolved livery is reported as a failure")
check(screamer.id == 4242, "the previous outfit id is restored - the zombie is not naked")
check(#screamer.dresses == 3 and screamer.dresses[3] == 4242,
    "restored by ID, which resolved once and so resolves again")
check(#sent == sentBefore, "no client is told to repaint into an outfit that does not exist")
check(#printed == 1 and string.find(printed[1], "RQ_Screamer", 1, true)
    and string.find(printed[1], "Screamer", 1, true) and string.find(printed[1], "4242", 1, true),
    "the failure prints unconditionally, naming the outfit, the type and the restored id")
check(RQSvLivery.stats.unresolved == 1, "and is counted")

-- A zombie with no previous id (fresh spawn before its first dress) has
-- nothing to restore to; it is still reported, not silently left at 0.
local bare = zombie(31, 5, 5, 0)
check(RQSvLivery.svDressForType(bare, "Screamer") == false and #bare.dresses == 2,
    "with no prior id there is no restore call, only the failed dress")
registered.RQ_Screamer = 0x50001

-- ---------------------------------------------------------------------------
-- The rage flip
-- ---------------------------------------------------------------------------
local scav = zombie(40, 5, 5)
RQSvLivery.svDressForType(scav, "Scavenger")
check(scav.id == registered.RQ_Scavenger, "a Scavenger converts emerald")
sentBefore = #sent
check(RQSvLivery.svEnrage(scav) == true and scav.id == registered.RQ_ScavengerEnraged,
    "svEnrage re-dresses it crimson")
check(#sent == sentBefore + 1 and sent[#sent].args.outfit == "RQ_ScavengerEnraged",
    "and repaints the same window with the crimson name")

-- Not gated on what it wore: a Scavenger from before liveries existed still
-- turns crimson when it rages.
local legacy = zombie(41, 5, 5, 9001)
check(RQSvLivery.svEnrage(legacy) == true and legacy.id == registered.RQ_ScavengerEnraged,
    "a legacy Scavenger in a vanilla outfit still goes crimson on rage")

-- No players near: the dress still happens; only the repaint has no one to tell.
nearCount = 0
local alone = zombie(50, 5, 5)
check(RQSvLivery.svDressForType(alone, "EMP") == true and alone.id == registered.RQ_EMP,
    "with no one online the server still dresses the zombie")

print = realPrint
print(string.format("RQSvLivery: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
