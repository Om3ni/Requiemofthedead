-- test_rcserver_dismantle.lua - server authority for dismantle telemetry.

local ROOT = arg[1] or "."
local TARGET = ROOT
    .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/server/RCServer.lua"

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
local dispatch
Events = {
    OnTick = { Add = function() end, Remove = function() end },
    OnClientCommand = { Add = function(fn) dispatch = fn end },
}
if not string.contains then
    string.contains = function(value, needle) return value:find(needle, 1, true) ~= nil end
end

local audits, removals, tokens = {}, {}, {}
local replies = {}
local claims = {}
RCShared = {
    MODULE = "RFTDReclamation",
    VERSION = "test",
    isAdmin = function(player) return player and player.admin == true end,
}
RDRate = { allow = function() return true end }
RCDismantleAuthority = {
    begin = function(_, args)
        return { ok = true, stage = "begin", vehicleId = args.vehicleId,
            ticket = "permit-1", expiresAt = 999 }
    end,
    reasonKey = function(reason)
        return "key:" .. tostring(reason)
    end,
    auditRefusal = function(_, result)
        audits[#audits + 1] = { event = "DISMANTLE-DENY", fields = result }
    end,
}
RCRegistry = {
    owns = function(owner, claimId)
        return claims[owner] and claims[owner][claimId] == true or false
    end,
    remove = function(owner, claimId)
        removals[#removals + 1] = owner .. ":" .. claimId
        claims[owner][claimId] = nil
    end,
    addToken = function(kind) tokens[#tokens + 1] = kind end,
}
RCAudit = {
    log = function(event, _, fields)
        audits[#audits + 1] = { event = event, fields = fields }
    end,
}
function sendServerCommand(_, _, command, args)
    replies[#replies + 1] = { command = command, args = args }
end

local okLoad, loadErr = pcall(dofile, TARGET)
if not okLoad then
    print("FATAL: could not load " .. TARGET)
    print("  " .. tostring(loadErr))
    os.exit(2)
end

local player = { admin = false, getUsername = function() return "mallory" end }
local admin = { admin = true, getUsername = function() return "warden" end }
local function reset()
    audits, removals, tokens, replies = {}, {}, {}, {}
    claims = { alice = { c1 = true } }
end
local function send(sender, command, args)
    dispatch("RFTDReclamation", command, sender, args)
end

-- THE STAGE-LESS WIRE SHAPE IS REFUSED OUTRIGHT (2026-08-19). It had no sender
-- left in the suite - RCDismantleMenu always sends stage = "begin" - and while
-- every state change already refused non-staff, the LEDGER ROW was written from
-- wire fields either way. That let any player mint audit entries of their
-- choosing, including rows reading as though an engine lock had been defeated.
-- The report logic itself is unchanged and still exercised below, through the
-- staff batch path that legitimately reaches it.
reset()
send(player, "dismantled", {
    vehicle = "Base.CarNormal", owner = "alice", claimId = "c1", via = "field",
})
eq("stage-less player report is refused, not processed", audits[1].event,
   "DISMANTLE-STAGELESS-REFUSED")
eq("and only that one row is written", #audits, 1)
eq("refused report cannot prune a claim", #removals, 0)
eq("refused report cannot mint a token", #tokens, 0)

reset()
send(admin, "dismantled", {
    vehicle = "Base.CarNormal", owner = "alice", claimId = "c1", via = "field",
})
eq("staff gets no exemption from the shape rule", audits[1].event,
   "DISMANTLE-STAGELESS-REFUSED")

-- The report policy still stands, reached the way it actually is in production:
-- the admin panel's batch, which is staff-gated at its own door and calls the
-- per-report handler for each entry.
local function report(sender, rep)
    send(sender, "dismantledMany", { reports = { rep } })
end

-- A non-staff sender cannot reach the report policy at all through the batch.
reset()
report(player, { vehicle = "Base.CarNormal", owner = "alice", claimId = "c1", via = "field" })
eq("non-staff batch is refused", audits[1].event, "VEHICLE-DELETE-REFUSED")
eq("non-staff batch prunes nothing", #removals, 0)

-- Staff deletion can prune only an exact server-indexed owner/id pair and does
-- not mint a replacement token for administrative cleanup.
reset()
report(admin, {
    delete = true, vehicle = "Base.CarNormal", owner = "alice", claimId = "c1", via = "panel",
})
eq("staff exact claim is pruned", removals[1], "alice:c1")
eq("staff deletion mints no token", #tokens, 0)
eq("staff deletion keeps its ledger verb", audits[1].event, "VEHICLE-DELETE")
eq("staff exact prune is recorded", audits[1].fields.claimMutation, "pruned")

reset()
report(admin, {
    delete = true, vehicle = "Base.CarNormal", owner = "alice", claimId = "wrong", via = "panel",
})
eq("staff mismatch cannot prune", #removals, 0)
eq("staff mismatch is explicit", audits[1].fields.claimMutation, "refused-mismatch")

-- A trusted staff field dismantle may contribute to the replacement pool.
reset()
report(admin, { vehicle = "Base.Trailer", via = "field" })
eq("staff field dismantle mints trailer token", tokens[1], "trailer")
eq("staff token mutation is recorded", audits[1].fields.tokenMutation, "minted-trailer")

-- The existing dismantled command requests the permit. Build 42's native
-- server timed action owns completion, so no client completion stage exists.
reset()
send(player, "dismantled", { stage = "begin", vehicleId = 42 })
eq("begin stage returns permit command", replies[1].command, "DismantlePermit")
eq("begin stage returns opaque permit", replies[1].args.ticket, "permit-1")
eq("begin stage does not write completion audit", #audits, 0)

reset()
send(player, "dismantled", { stage = "complete", ticket = "permit-1" })
eq("forged completion stage is denied", audits[1].event, "DISMANTLE-DENY")
eq("forged completion denial names bad stage", audits[1].fields.reason, "stage")
eq("forged completion sends bounded refusal", replies[1].command, "Notify")

-- A player cannot forge the staff deletion ledger verb either. This used to be
-- caught INSIDE the report - the row was written as DISMANTLE and flagged
-- UNAUTHORIZED-DELETE-REPORT - which was correct but meant the forgery still
-- reached the ledger. It is now refused at the door, so no chosen field of it
-- lands anywhere: strictly better, and the reason the old pair of assertions
-- below became one.
reset()
send(player, "dismantled", { delete = true, vehicle = "Base.CarNormal", via = "panel" })
eq("forged delete verb never reaches the ledger", audits[1].event,
   "DISMANTLE-STAGELESS-REFUSED")
eq("and writes exactly one row", #audits, 1)

-- Bulk staff reports remain independent: a failed audit record does not cost
-- the reports behind it, though any mutation completed before the secondary
-- audit failure remains authoritative.
reset()
RCAudit.log = function(event, _, fields)
    if fields.vehicle == "bad" then error("simulated audit failure") end
    audits[#audits + 1] = { event = event, fields = fields }
end
send(admin, "dismantledMany", { reports = {
    { delete = true, vehicle = "bad", via = "panel" },
    { delete = true, vehicle = "good", via = "panel" },
} })
eq("bulk continues after one independent report failure", #audits, 1)
eq("bulk later report is preserved", audits[1].fields.vehicle, "good")

print(string.format("RCServer dismantle authority: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
