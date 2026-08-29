-- HBCommands fixture - the RFTDHusbandry token's declared trust boundary.
--
-- WHY THIS FILE EXISTS. Husbandry adopted RDNet on 2026-08-25, replacing an
-- if/elseif chain behind its own OnClientCommand listener. That chain had no
-- test at all: the gate on each branch, the absence of a branch for the two
-- withdrawn commands, and the rate on each command were all assertions made
-- only by comments. Under RDNet the same facts are DATA - one options table
-- per command - so they can be read back and pinned, which is the half a Lua
-- fixture can actually prove.
--
-- WHAT IS AT RISK, in order.
--
-- 1. A GATE SILENTLY GOING OPEN. `capability = nil` with no `public = true`
--    and no `gate = "handler"` means RDAccess.can admits everyone
--    (RDNet.lua:151-156). RDNet prints about it at boot; a server nobody was
--    watching boot does not. Every command here states which of the three it
--    is, and this file fails if one stops stating it.
--
-- 2. hbRegister / hbUnregister COMING BACK. Two unauthenticated writes,
--    withdrawn 2026-08-20. Under the old chain "withdrawn" meant a missing
--    branch, which looks identical to a branch nobody wrote yet. Under RDNet
--    it means default-deny, and the pin below is that they are NOT registered.
--
-- 3. RATE DRIFT on the client-facing commands. hbPartPlaced's 4/sec moved out
--    of HBPartWatch.onClientReport and onto its registration in the same
--    change; if it drifts, nothing in play looks different until a flood.
--
-- Loads the REAL HBCommands with a recording RDNet, so what is asserted is the
-- shipped registration and not a restatement of it.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/shared/HBCommands.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL HBCommands: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return true end
print = function() end

local registeredMods = {}
RDShared = { registerMod = function(id, v) registeredMods[id] = v end }
require = function() return true end

-- Recording RDNet. Handlers are kept so the gates can be exercised, not just
-- the options read.
local adopted, adoptOpts = {}, nil
local reg = {}
local replies = {}
RDNet = {
    adopt = function(token, opts)
        adopted[#adopted + 1] = token
        adoptOpts = opts
    end,
    register = function(token, command, opts, handler)
        check(reg[command] == nil, "duplicate registration of " .. tostring(command))
        reg[command] = { token = token, opts = opts, handler = handler }
    end,
    reply = function(player, token, command, args)
        replies[#replies + 1] = { player = player, token = token,
                                  command = command, args = args }
    end,
}

local anyCapability = false
RDAccess = { hasAnyCapability = function() return anyCapability end }
local debugOn = false
function isDebugEnabled() return debugOn end

local seenAnimals = {}
HBData = { addSeen = function(a) seenAnimals[#seenAnimals + 1] = a end }

local animals = { [7] = { id = 7 } }
function getAnimal(id) return animals[id] end

local partReports = {}
HBPartWatch = { onClientReport = function(p, args)
    partReports[#partReports + 1] = { player = p, args = args }
end }

local probes = {}
HBAPIProbe = { runOn = function(id, p) probes[#probes + 1] = { id = id, player = p } end }

local sexChecks = {}
HBSexCheck_Server = { handle = function(p, args)
    sexChecks[#sexChecks + 1] = { player = p, args = args }
end }

local beddingAdds = {}
HBBedding = {
    MAX = 100,
    perAdd = function() return 25 end,
    resolveHutchAt = function(x, y, z)
        if x == 10 and y == 20 then return { hutch = true } end
        return nil
    end,
    addBedding = function(hutch, amount)
        beddingAdds[#beddingAdds + 1] = amount
        return amount
    end,
}

local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local player = { getUsername = function() return "Tester" end }

-- ---------------------------------------------------------------------------
-- The token is claimed, once.
-- ---------------------------------------------------------------------------

check(#adopted == 1 and adopted[1] == "RFTDHusbandry",
    "the token is not adopted exactly once")
check(registeredMods["RFTDHusbandry"] ~= nil, "the mod did not register its version")

-- NO reject hook, deliberately: with every staff gate at gate="handler", RDNet
-- can only reject for unregistered-command or rate, and it tests the command
-- BEFORE the rate limiter (RDNet.lua:206-221) - so a hook here would mint an
-- unmetered reply for any name a client cares to invent. See HBCommands.
check(adoptOpts == nil or adoptOpts.onReject == nil,
    "an onReject hook appeared - that answers unregistered commands unmetered")

-- ---------------------------------------------------------------------------
-- Every command declares a gate. This is the assertion that catches a gate
-- going open by omission rather than by decision.
-- ---------------------------------------------------------------------------

local EXPECTED = {
    hbAddSeen    = { public = true,      rate = 20 },
    hbAddBedding = { public = true,      rate = 30 },
    hbPartPlaced = { public = true,      rate = 4  },
    hbSexCheck   = { gate = "handler",   rate = 4  },
    hbDebugProbe = { gate = "handler",   rate = 4  },
    hbDebugRefill= { gate = "handler",   rate = 2  },
}

local count = 0
for name, want in pairs(EXPECTED) do
    count = count + 1
    local got = reg[name]
    check(got ~= nil, name .. " is not registered")
    if got then
        check(got.token == "RFTDHusbandry", name .. " registered on the wrong token")
        check(got.opts ~= nil, name .. " registered with no options table at all")
        if got.opts then
            check(got.opts.public == want.public,
                name .. " public flag drifted: " .. tostring(got.opts.public))
            check(got.opts.gate == want.gate,
                name .. " gate declaration drifted: " .. tostring(got.opts.gate))
            check(got.opts.rate == want.rate,
                name .. " rate drifted: " .. tostring(got.opts.rate))
            -- The shape RDNet shouts about: no capability, and neither of the
            -- two ways of saying that was on purpose.
            check(got.opts.capability ~= nil or got.opts.public == true
                  or got.opts.gate ~= nil,
                name .. " has no capability and declares neither public nor gate"
                .. " - RDAccess.can admits everyone")
        end
    end
end

-- Nothing beyond the declared surface. A seventh registration would mean a
-- command was added without a line in EXPECTED above, which is how an ungated
-- one would arrive.
local actual = 0
for _ in pairs(reg) do actual = actual + 1 end
check(actual == count, "registration count is " .. actual .. ", expected " .. count)

-- ---------------------------------------------------------------------------
-- The two withdrawn commands are ABSENT, not merely ungated.
-- ---------------------------------------------------------------------------

check(reg["hbRegister"] == nil,
    "hbRegister is registered again - it is an unauthenticated write (2026-08-20)")
check(reg["hbUnregister"] == nil,
    "hbUnregister is registered again - it is an unauthenticated write (2026-08-20)")
check(reg["hbSyncAnimal"] == nil, "hbSyncAnimal has no handler and must not be wired")
check(reg[HBCmd.DEBUG_PROBE_RESULT] == nil,
    "the server->client result command is registered as an INBOUND command")

-- ---------------------------------------------------------------------------
-- Staff gates actually refuse. Handlers, not comments.
-- ---------------------------------------------------------------------------

anyCapability, debugOn = false, false

reg.hbSexCheck.handler(player, { id = 7 })
check(#sexChecks == 0, "hbSexCheck ran for a player with no capability")

reg.hbDebugProbe.handler(player, { id = 7 })
check(#probes == 0, "hbDebugProbe ran for a player with no capability")

replies = {}
reg.hbDebugRefill.handler(player, { oids = "7", value = 0 })
check(#replies == 1 and replies[1].command == HBCmd.DEBUG_PROBE_RESULT,
    "a refused hbDebugRefill did not answer its caller")
check(#beddingAdds == 0, "refill touched bedding (wrong handler ran)")

-- A capability opens all three.
anyCapability = true
reg.hbSexCheck.handler(player, { id = 7 })
check(#sexChecks == 1, "hbSexCheck refused a capability holder")
reg.hbDebugProbe.handler(player, { id = 7 })
check(#probes == 1 and probes[1].id == 7, "hbDebugProbe refused a capability holder")

-- Debug mode is the documented escape, and it is an OR - which is exactly why
-- these are gate="handler" and not capability="any". If someone "simplifies"
-- them to capability="any", the EXPECTED table above fails first; this pins the
-- behaviour that made the distinction necessary.
anyCapability, debugOn = false, true
reg.hbSexCheck.handler(player, { id = 7 })
check(#sexChecks == 2, "the debug escape stopped working")
anyCapability, debugOn = false, false

-- ---------------------------------------------------------------------------
-- Open commands: preconditions, not guards. A forged command may arrive with
-- no args table at all - receiveClientCommand leaves it nil when the sender
-- set no payload (GameServer.java:2115-2125).
-- ---------------------------------------------------------------------------

seenAnimals = {}
reg.hbAddSeen.handler(player, nil)
reg.hbAddSeen.handler(player, {})
reg.hbAddSeen.handler(player, { id = "not-a-number" })
check(#seenAnimals == 0, "hbAddSeen accepted a report with no usable id")
reg.hbAddSeen.handler(player, { id = "7" })
check(#seenAnimals == 1, "hbAddSeen refused a well-formed report")

anyCapability = true
probes = {}
reg.hbDebugProbe.handler(player, nil)
check(#probes == 0, "hbDebugProbe called through with no id")
anyCapability = false

-- hbAddBedding: the server decides the amount, and a client-supplied one is
-- ignored. This is the whole reason the command can be open.
beddingAdds = {}
reg.hbAddBedding.handler(player, { x = 10, y = 20, z = 0, amount = 9999 })
check(#beddingAdds == 1 and beddingAdds[1] == 25,
    "hbAddBedding used the CLIENT's amount: " .. tostring(beddingAdds[1]))
reg.hbAddBedding.handler(player, { x = 1, y = 1, z = 0 })
check(#beddingAdds == 1, "hbAddBedding added to a square with no hutch")
reg.hbAddBedding.handler(player, nil)
reg.hbAddBedding.handler(player, { y = 20 })
check(#beddingAdds == 1, "hbAddBedding accepted missing coordinates")

-- hbPartPlaced passes straight through; the bounds live in HBPartWatch and are
-- pinned by test_hbpartwatch. What is pinned HERE is that it still arrives.
partReports = {}
reg.hbPartPlaced.handler(player, { x = 1, y = 2, z = 0, items = {} })
check(#partReports == 1, "hbPartPlaced did not reach HBPartWatch.onClientReport")

print = realPrint
print(string.format("HBCommands: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
