-- RQTailor fixture - the client re-dress is verified, and the wound strip is
-- keyed on the livery, clears once, and catches a re-dress.
--
-- The zombie fake MODELS THE ENGINE'S ORDER: dressInNamedOutfit clears the
-- visuals BEFORE it looks the outfit up (IsoZombie.java:3878-3884), so a name
-- the client cannot resolve, or one whose items are not loaded yet, leaves the
-- zombie naked. The old lab probe reported that as success; a fake that just
-- records the requested name can never reproduce the bug it hid.

local ROOT = arg[1] or "."
local LUA = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQTailor: " .. message) end
end

function isClient() return true end
function isServer() return false end

local updateHandler
Events = { OnZombieUpdate = { Add = function(fn) updateHandler = fn end } }

-- Outfits this client has loaded. A name outside this set strips the zombie.
local loaded = { RQ_Juggernaut = true, RQ_Scavenger = true, RQ_ScavengerEnraged = true }

-- ItemVisuals is an ArrayList: size/get are 0-based Java, clear empties it.
local function visuals(types)
    local list = {}
    for _, t in ipairs(types) do
        list[#list + 1] = { getItemType = function() return t end }
    end
    return {
        size  = function() return #list end,
        get   = function(_, i) return list[i + 1] end,
        clear = function() for k in pairs(list) do list[k] = nil end end,
        add   = function(_, t) list[#list + 1] = { getItemType = function() return t end } end,
    }
end

local function zombie(oid, outfit, persistentID, wounds)
    local z = { oid = oid, outfit = outfit, persistentID = persistentID or 0,
                resets = 0, body = visuals(wounds or {}) }
    z.getOnlineID           = function(s) return s.oid end
    z.getOutfitName         = function(s) return s.outfit end
    z.getPersistentOutfitID = function(s) return s.persistentID end
    z.getHumanVisual        = function(s) return { getBodyVisuals = function() return s.body end } end
    z.resetModelNextFrame   = function(s) s.resets = s.resets + 1 end
    z.dressInNamedOutfit = function(s, name)
        s.outfit = nil                              -- the clear at :3878-3880
        if loaded[name] then s.outfit = name end   -- set only on success (HumanVisual.java:638-640)
    end
    z.dressInPersistentOutfitID = function(s, id)
        s.persistentID = id
        s.outfit = (id ~= 0) and ("restored:" .. id) or nil
    end
    return z
end

local printed = {}
local realPrint = print

local realRequire = require
function require(name)
    if name == "RQLivery" then
        HairOutfitDefinitions = {}
        dofile(LUA .. "/shared/RQLivery.lua")
        return
    end
    error("unexpected fixture require: " .. tostring(name))
end

RQTailor = nil
local ok, err = pcall(dofile, LUA .. "/client/RQTailor.lua")
require = realRequire
check(ok, "module loads: " .. tostring(err))
check(type(updateHandler) == "function", "the strip lane registers on OnZombieUpdate")
print = function(line) printed[#printed + 1] = tostring(line) end

-- ---------------------------------------------------------------------------
-- Redress
-- ---------------------------------------------------------------------------
local z = zombie(22, "RQ_Scavenger", 7788)
check(RQTailor.redress(z, "RQ_ScavengerEnraged") == true
    and z.outfit == "RQ_ScavengerEnraged" and z.resets == 1,
    "a loaded outfit applies and queues exactly one model reset")
check(#printed == 0, "a successful redress prints nothing")

-- THE STRIPPED PATH: first sight of a livery whose items are not loaded yet.
local cold = zombie(23, "Police", 7788)
check(RQTailor.redress(cold, "RQ_Screamer") == false,
    "an outfit that does not apply is reported as a FAILURE, not a repaint")
check(cold.outfit ~= nil, "and the zombie is NOT left naked - the engine strips before it looks up")
check(cold.persistentID == 7788 and cold.outfit == "restored:7788",
    "recovery re-applies the server's authoritative persistent outfit id")
check(cold.resets == 1, "the render invalidation still runs on the recovery")
check(#printed == 1 and string.find(printed[1], "RQ_Screamer", 1, true)
    and string.find(printed[1], "7788", 1, true),
    "the failure prints, naming the outfit and the restored id")

-- No persistent id to fall back on: still refuses rather than claiming success.
local orphan = zombie(24, "Police", 0)
check(RQTailor.redress(orphan, "RQ_Screamer") == false and orphan.persistentID == 0,
    "with no fallback id the redress still refuses rather than reporting success")
check(RQTailor.stats.redressed == 1 and RQTailor.stats.restored == 2, "counters split success from restore")

-- ---------------------------------------------------------------------------
-- Strip
-- ---------------------------------------------------------------------------
-- A Glutton wearing the skull cap and a calf bandage.
local glutton = zombie(10, "RQ_Glutton", 1, { "Base.ZedDmg_HEAD_Skin", "Base.Bandage_RightLowerLeg_Blood" })
updateHandler(glutton)
check(glutton.body:size() == 0, "livery: body visuals are cleared")
check(glutton.resets == 1, "livery: exactly one model reset is queued")
check(RQTailor.stats.cleared == 1 and RQTailor.stats.seen == 1, "counters record one seen, one cleared")
check(RQTailor.stats.stripped["Base.ZedDmg_HEAD_Skin"] == 1
    and RQTailor.stats.stripped["Base.Bandage_RightLowerLeg_Blood"] == 1,
    "each stripped item type is tallied")

-- Second frame: nothing left, so no second reset and no second clear.
updateHandler(glutton)
check(glutton.resets == 1 and RQTailor.stats.cleared == 1, "a clean zombie is not reset again")
check(RQTailor.stats.seen == 2, "but the per-frame cost is still counted")

-- A re-dress rolls the wounds back on; the size() test catches it.
glutton.body:add("Base.ZedDmg_NoNose")
updateHandler(glutton)
check(glutton.body:size() == 0 and glutton.resets == 2, "wounds re-added by a re-dress are stripped again")

-- The enraged Scavenger is a livery too.
local crimson = zombie(11, "RQ_ScavengerEnraged", 1, { "Base.ZedDmg_HEAD_Skin" })
updateHandler(crimson)
check(crimson.body:size() == 0, "the enraged outfit is stripped like the others")

-- A vanilla zombie keeps its wounds, whatever it wears.
local vanilla = zombie(12, "Police", 1, { "Base.ZedDmg_HEAD_Skin" })
updateHandler(vanilla)
check(vanilla.body:size() == 1 and vanilla.resets == 0, "a vanilla outfit is left alone")

-- No outfit resolved yet (outfit == null on the Java side) is not ours.
local naked = zombie(13, nil, 1, { "Base.ZedDmg_HEAD_Skin" })
updateHandler(naked)
check(naked.body:size() == 1 and naked.resets == 0, "a zombie with no outfit name is left alone")

-- A liveried creature with nothing rolled costs a size() and nothing else.
local clean = zombie(14, "RQ_Juggernaut", 1, {})
updateHandler(clean)
check(clean.resets == 0 and RQTailor.stats.cleared == 3, "a livery with no wounds is not reset")
check(RQTailor.stats.seen == 5, "seen counts liveried zombies only")

print = realPrint
print(string.format("RQTailor: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
