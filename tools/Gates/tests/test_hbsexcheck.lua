-- HBSexCheck fixture - authoritative sex diagnostics use the verified engine
-- default directly and preserve their client reply.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDHusbandry/42/media/lua/server/HBSexCheck_Server.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL HBSexCheck: " .. message)
    end
end

-- Calls HBSexCheck_Server.handle directly. Until 2026-08-19 this file captured
-- an OnClientCommand listener that HBSexCheck_Server registered itself; that
-- listener was a second executable intake on the RFTDHusbandry token and has
-- been folded into HBCommands' dispatcher. The staff gate moved with it, so
-- what is exercised here is exactly what the file still owns: resolving the
-- animal, reading the authoritative sex, and replying on the probe channel.
local listeners = 0
Events = { OnClientCommand = { Add = function() listeners = listeners + 1 end } }
function isServer() return true end
RDAccess = { hasAnyCapability = function() return true end }

local animals = {}
function getAnimal(oid) return animals[oid] end

local replies = {}
function sendServerCommand(_, module, command, args)
    replies[#replies + 1] = { module = module, command = command, args = args }
end

local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(type(HBSexCheck_Server) == "table" and type(HBSexCheck_Server.handle) == "function",
    "exposes the handler for the one dispatcher to call")
check(listeners == 0,
    "and registers NO listener of its own - one token, one executable intake")

local handler = function(_, _, player, args) HBSexCheck_Server.handle(player, args) end

local femaleCalls = 0
animals[12] = { isFemale = function() femaleCalls = femaleCalls + 1; return true end }
handler("RFTDHusbandry", "hbSexCheck", {}, { id = 12 })
check(femaleCalls == 1 and replies[1] and replies[1].args.line:find("oid=12 sex=FEMALE", 1, true),
    "female probe reads the resolved animal directly and replies with the result")

animals[13] = { isFemale = function() return false end }
handler("RFTDHusbandry", "hbSexCheck", {}, { id = 13 })
check(replies[2] and replies[2].args.line:find("oid=13 sex=MALE", 1, true),
    "male probe preserves the authoritative reply contract")

print(string.format("HBSexCheck: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
