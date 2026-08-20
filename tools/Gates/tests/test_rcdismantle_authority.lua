-- test_rcdismantle_authority.lua - bounded one-use server dismantle permits.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCDismantleAuthority.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL  " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

function isServer() return true end
require = function() end
local now = 100000
RDShared = { nowMs = function() return now end }
Events = {
    OnDisconnect = { Add = function() end },
    OnPlayerDisconnect = { Add = function() end },
}

local vehicles = {}
function getVehicleById(id) return vehicles[id] end

local function makeVehicle(id, kind)
    local v = {
        id = id, kind = kind or "vehicle", removed = false,
        claimed = true, owner = "alice", claimId = "claim-1",
    }
    function v:isRemovedFromWorld() return self.removed end
    function v:getScriptName()
        if self.kind == "unnamed" then return nil end
        if self.kind == "trailer" then return "Base.Trailer" end
        if self.kind == "wreck" then return "Base.CarNormalBurnt" end
        return "Base.CarNormal"
    end
    function v:getX() return 10.5 end
    function v:getY() return 20.5 end
    function v:getZ() return 0 end
    function v:getZi() return 0 end
    return v
end

local ruleReason
RCDismantleRules = {
    check = function(vehicle)
        if ruleReason then return ruleReason end
        return nil, { wreck = vehicle.kind == "wreck", engine = 12, torch = {} }
    end,
    primaryTorch = function() return {} end,
}

local yieldOk, yieldCalls, lastEternal = true, 0, nil
local tokenError
RCDismantleYield = {
    commit = function(vehicle, _, _, eternal)
        yieldCalls = yieldCalls + 1
        lastEternal = eternal
        if not yieldOk then return false, { phase = "remove", error = "boom" } end
        vehicle.removed = true
        return true, { dumped = 2, xp = 7 }
    end,
}

RCShared = {
    MODULE = "RFTDReclamation",
    isAdmin = function(player) return player.admin == true end,
    isTrailer = function(vehicle) return vehicle.kind == "trailer" end,
}
RCClaim = {
    isClaimed = function(vehicle) return vehicle.claimed end,
    getOwner = function(vehicle) return vehicle.owner end,
    getClaimId = function(vehicle) return vehicle.claimId end,
}
local removals, tokens = {}, {}
local audits, replies = {}, {}
RCRegistry = {
    remove = function(owner, claimId)
        removals[#removals + 1] = owner .. ":" .. claimId
    end,
    addToken = function(kind)
        if tokenError then return nil, tokenError end
        tokens[#tokens + 1] = kind
        return #tokens, nil
    end,
}
RCAudit = {
    log = function(event, _, fields)
        audits[#audits + 1] = { event = event, fields = fields }
    end,
}
function sendServerCommand(_, _, command, args)
    replies[#replies + 1] = { command = command, args = args }
end

local function makePlayer(name, admin)
    local p = { name = name, admin = admin == true, distance = 1, z = 0 }
    function p:getUsername() return self.name end
    function p:getVehicle() return nil end
    function p:getZi() return self.z end
    function p:DistToSquared() return self.distance end
    return p
end

local okLoad, loadErr = pcall(dofile, TARGET)
if not okLoad then
    print("FATAL: could not load " .. TARGET)
    print("  " .. tostring(loadErr))
    os.exit(2)
end

local player = makePlayer("alice", false)
local admin = makePlayer("warden", true)
local function reset(kind)
    vehicles[7] = makeVehicle(7, kind)
    removals, tokens, audits, replies = {}, {}, {}, {}
    ruleReason, yieldOk, yieldCalls, lastEternal, tokenError = nil, true, 0, nil, nil
    player.distance, player.z = 1, 0
    now = 100000
end

reset()
local begun = RCDismantleAuthority.begin(player, { vehicleId = 7 })
eq("valid begin issues a permit", begun.ok, true)
eq("permit names authoritative vehicle", begun.vehicleId, 7)
eq("begin performs no removal", yieldCalls, 0)
eq("begin performs no claim mutation", #removals, 0)
eq("begin performs no token mutation", #tokens, 0)

local forged = RCDismantleAuthority.complete(player, { ticket = "forged" })
eq("forged ticket is refused", forged.reason, "ticket")
local committed = RCDismantleAuthority.complete(player,
    { ticket = begun.ticket, vehicle = vehicles[7] })
eq("forged ticket does not consume real permit", committed.ok, true)
eq("successful commit removes once", yieldCalls, 1)
eq("successful commit prunes server claim", removals[1], "alice:claim-1")
eq("successful car commit mints vehicle token", tokens[1], "vehicle")
eq("commit authority is explicit", committed.authority, "server-transaction")
eq("ordinary player cannot request eternal torch", lastEternal, false)

local replay = RCDismantleAuthority.complete(player,
    { ticket = begun.ticket, vehicle = vehicles[7] })
eq("used permit cannot replay", replay.reason, "ticket")
eq("replay performs no second removal", yieldCalls, 1)

reset()
ruleReason = "claim-other"
local claimed = RCDismantleAuthority.begin(player, { vehicleId = 7 })
eq("claimed vehicle is a hard authorization block", claimed.reason, "claim-other")
eq("claimed vehicle block performs no removal", yieldCalls, 0)
eq("claimed vehicle block mints no token", #tokens, 0)

reset()
local missingActionVehicle = RCDismantleAuthority.begin(player, { vehicleId = 7 })
local missingActionResult = RCDismantleAuthority.complete(player,
    { ticket = missingActionVehicle.ticket })
eq("completion requires the engine action vehicle", missingActionResult.reason, "gone")
eq("missing action vehicle still consumes the exact permit",
    RCDismantleAuthority.complete(player, {
        ticket = missingActionVehicle.ticket, vehicle = vehicles[7],
    }).reason, "ticket")

reset()
local expiring = RCDismantleAuthority.begin(player, { vehicleId = 7 })
now = expiring.expiresAt + 1
local expired = RCDismantleAuthority.complete(player,
    { ticket = expiring.ticket, vehicle = vehicles[7] })
eq("expired permit is refused", expired.reason, "expired")
eq("expired permit performs no removal", yieldCalls, 0)

reset()
local mismatched = RCDismantleAuthority.begin(player, { vehicleId = 7 })
local originalVehicle = vehicles[7]
vehicles[7] = makeVehicle(7)
local gone = RCDismantleAuthority.complete(player,
    { ticket = mismatched.ticket, vehicle = originalVehicle })
eq("reused vehicle id cannot substitute object", gone.reason, "gone")

reset()
local distant = RCDismantleAuthority.begin(player, { vehicleId = 7 })
player.distance = 17
local tooFar = RCDismantleAuthority.complete(player,
    { ticket = distant.ticket, vehicle = vehicles[7] })
eq("completion requires nearby player", tooFar.reason, "distance")
eq("distance refusal consumes exact permit", RCDismantleAuthority.complete(player,
    { ticket = distant.ticket, vehicle = vehicles[7] }).reason, "ticket")

reset()
local changed = RCDismantleAuthority.begin(player, { vehicleId = 7 })
ruleReason = "claim-other"
local changedResult = RCDismantleAuthority.complete(player,
    { ticket = changed.ticket, vehicle = vehicles[7] })
eq("completion repeats persistent rules", changedResult.reason, "claim-other")

reset()
local failedRemoval = RCDismantleAuthority.begin(player, { vehicleId = 7 })
yieldOk = false
local failedResult = RCDismantleAuthority.complete(player,
    { ticket = failedRemoval.ticket, vehicle = vehicles[7] })
eq("remove failure is explicit", failedResult.reason, "remove-failed")
eq("remove failure does not prune claim", #removals, 0)
eq("remove failure does not mint token", #tokens, 0)

reset("wreck")
local wreckPermit = RCDismantleAuthority.begin(player, { vehicleId = 7 })
local wreckResult = RCDismantleAuthority.complete(player,
    { ticket = wreckPermit.ticket, vehicle = vehicles[7] })
eq("wreck still commits", wreckResult.ok, true)
eq("wreck mints no replacement", #tokens, 0)

reset("trailer")
local trailerPermit = RCDismantleAuthority.begin(admin, { vehicleId = 7, eternal = true })
local trailerResult = RCDismantleAuthority.complete(admin,
    { ticket = trailerPermit.ticket, vehicle = vehicles[7] })
eq("trailer commit mints trailer token", tokens[1], "trailer")
eq("staff eternal torch is server-gated", lastEternal, true)
eq("staff cheat is audited", trailerResult.cheat, "eternal-torch")

reset()
local tokenlessPermit = RCDismantleAuthority.begin(player, { vehicleId = 7 })
tokenError = "token-pool-invalid"
local tokenlessResult = RCDismantleAuthority.complete(player,
    { ticket = tokenlessPermit.ticket, vehicle = vehicles[7] })
eq("token validation failure still completes dismantle", tokenlessResult.ok, true)
eq("token validation failure still removes vehicle", yieldCalls, 1)
eq("token validation failure mints no token", #tokens, 0)
eq("token validation failure is explicit", tokenlessResult.tokenMutation,
    "withheld-unverified")
eq("token validation failure retains its reason", tokenlessResult.tokenFailure,
    "token-pool-invalid")

reset("unnamed")
local unnamedPermit = RCDismantleAuthority.begin(player, { vehicleId = 7 })
local unnamedResult = RCDismantleAuthority.complete(player,
    { ticket = unnamedPermit.ticket, vehicle = vehicles[7] })
eq("missing vehicle script still completes dismantle", unnamedResult.ok, true)
eq("missing vehicle script mints no token", #tokens, 0)
eq("missing vehicle script withholds unverified reward", unnamedResult.tokenMutation,
    "withheld-unverified")
eq("missing vehicle script explains withheld reward", unnamedResult.tokenFailure,
    "vehicle-script-unavailable")

reset()
local queuedFirst = RCDismantleAuthority.begin(player, { vehicleId = 7 })
local queuedSecond = RCDismantleAuthority.begin(player, { vehicleId = 7 })
local firstResult = RCDismantleAuthority.complete(player,
    { ticket = queuedFirst.ticket, vehicle = vehicles[7] })
eq("a second queued action does not invalidate the first", firstResult.ok, true)
eq("the second queued permit remains independently present",
    RCDismantleAuthority.complete(player,
        { ticket = queuedSecond.ticket, vehicle = vehicles[7] }).reason, "gone")

reset()
local deniedFinish = RCDismantleAuthority.begin(player, { vehicleId = 7 })
ruleReason = "claim-other"
eq("timed-action refusal rejects engine completion",
    RCDismantleAuthority.finish(player, deniedFinish.ticket, vehicles[7]), false)
eq("timed-action refusal notifies the player", replies[1].command, "Notify")
eq("timed-action refusal uses the mapped reason", replies[1].args.key,
    "IGUI_RC_DismClaimed")
eq("timed-action refusal is audited", audits[1].event, "DISMANTLE-DENY")

reset()
local acceptedFinish = RCDismantleAuthority.begin(player, { vehicleId = 7 })
eq("timed-action commit completes the engine action",
    RCDismantleAuthority.finish(player, acceptedFinish.ticket, vehicles[7]), true)
eq("timed-action commit is audited", audits[1].event, "DISMANTLE")

reset()
eq("non-integer vehicle id is refused",
    RCDismantleAuthority.begin(player, { vehicleId = 7.5 }).reason, "vehicle-id")
eq("short-alias vehicle id is refused",
    RCDismantleAuthority.begin(player, { vehicleId = 65543 }).reason, "vehicle-id")

print(string.format("RCDismantleAuthority: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
