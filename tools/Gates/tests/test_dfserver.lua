-- DFServer fixture - the dispatcher every Dragonfly admin command passes through.
--
-- WHY THIS EXISTS NOW. Until 2026-08-23 nothing tested this file, and three
-- shipped modules were relying on it to enforce `handler.capability` - the vars
-- and layout handlers moved their gates onto it that day, so "the dispatcher
-- refuses" stopped being an assumption and became the whole authority story for
-- seven admin verbs. An untested gate that everything depends on is the shape
-- this repo keeps finding after the fact.
--
-- WHAT IS AT RISK, in order.
--
-- 1. A declared capability must actually refuse, and must refuse BEFORE the
--    handler body runs. A gate that runs after is not a gate.
-- 2. A refusal must be AUDITED AS A REFUSAL. The distinction is not cosmetic:
--    an accepted command and a refused one otherwise produce the same log line,
--    so a server owner reading the audit trail cannot tell an admin who did
--    something from one who tried and was stopped.
-- 3. The three declared shapes (a name; "any" = any capability at all; a
--    FUNCTION of (player, args) for payload-dependent gates - added
--    2026-08-25) must each refuse before the body, answer the caller, and
--    land in the audit log AS refusals. A handler with NO declared
--    capability is still let straight through - correct for a genuinely open
--    handler, though nothing in the suite needs that for gate reasons now.
--
-- The rate limiter and the audit relay are not covered; RDRate has its own
-- fixture and the relay is a send.

local ROOT = arg[1] or "."
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL DFServer: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return true end
require = function() return true end
print = function() end

local dispatch
Events = {
    OnClientCommand    = { Add = function(fn) dispatch = fn end },
    OnPlayerDisconnect = { Add = function() end },
}

local caps = {}
local audits = {}
DFCore = {
    MODULE  = "RFTDDragonfly",
    VERSION = "test",
    roleHas = function(player, capability)
        local held = player and caps[player.name]
        return (held and held[capability]) == true
    end,
    hasAnyCapability = function(player)
        local held = player and caps[player.name]
        if not held then return false end
        for _ in pairs(held) do return true end
        return false
    end,
    allow  = function() return true end,
    audit  = function(action, player, extra)
        audits[#audits + 1] = {
            action = tostring(action),
            who    = player and player.name or "?",
            extra  = extra and tostring(extra) or nil,
        }
    end,
    forgetRateLimit = function() end,
}

local replies = {}
function sendServerCommand(player, _, command, args)
    replies[#replies + 1] = { to = player.name, command = command, args = args }
end
function getTimestampMs() return 1000 end

DFServer = nil
local ok, err = pcall(dofile, DIR .. "/server/DFServer.lua")
check(ok, "module loads: " .. tostring(err))
check(dispatch ~= nil, "no OnClientCommand listener was registered")

local function player(name, capList)
    caps[name] = {}
    for _, c in ipairs(capList or {}) do caps[name][c] = true end
    return { name = name, getUsername = function(self) return self.name end }
end

local admin  = player("Admin", { "KickUser" })
local nobody = player("Nobody", {})

local ran = {}
DFServer.registerHandler{
    action     = "gatedThing",
    capability = "KickUser",
    run = function(p) ran[#ran + 1] = p.name; return { ok = true, message = "done" } end,
}
DFServer.registerHandler{
    action = "openThing",
    run = function(p) ran[#ran + 1] = p.name; return { ok = true } end,
}

local function fire(who, command, args)
    ran, audits, replies = {}, {}, {}
    dispatch(DFCore.MODULE, command, who, args or {})
end

-- ---- a declared capability refuses --------------------------------------

fire(admin, "gatedThing")
check(#ran == 1 and ran[1] == "Admin", "a permitted caller was refused")
check(#replies == 1 and replies[1].args.ok == true, "no success reply was sent")

fire(nobody, "gatedThing")
check(#ran == 0,
    "A DECLARED CAPABILITY DID NOT REFUSE. Seven admin verbs moved their gate "
    .. "onto this dispatcher on 2026-08-23; if it does not enforce, none of them "
    .. "is gated at all.")
check(#replies == 1 and replies[1].args.ok == false, "the refused caller got no answer")
check(tostring(replies[1].args.reason):find("apability", 1, true) ~= nil,
    "the refusal did not say what was missing: " .. tostring(replies[1].args.reason))

-- ...and refuses BEFORE the body. A gate that runs after the work is not a gate,
-- and this is the assertion that tells the two apart.
check(#ran == 0, "the handler body ran despite the refusal")

-- ---- a refusal is audited AS a refusal ----------------------------------

fire(nobody, "gatedThing")
check(#audits == 1, "a refused command produced " .. #audits .. " audit lines, expected 1")
check(audits[1].extra ~= nil and audits[1].extra:find("refused", 1, true) ~= nil,
    "A REFUSED COMMAND WAS LOGGED LIKE AN ACCEPTED ONE. A server owner reading "
    .. "the audit trail then cannot tell an admin who did something from one "
    .. "who tried and was stopped: " .. tostring(audits[1].extra))

fire(admin, "gatedThing")
check(#audits == 1 and audits[1].extra == nil,
    "an accepted command carried a refusal marker")

-- ---- no declared capability is let straight through ---------------------
-- Still correct for a genuinely open handler; since 2026-08-25 nothing in the
-- suite NEEDS to be open for gate reasons ("any" and function gates below).

fire(nobody, "openThing")
check(#ran == 1, "a handler with no declared capability was refused")
check(#audits == 1 and audits[1].extra == nil,
    "an ungated command was logged as anything other than accepted")

-- ---- capability = "any": any capability at all --------------------------
-- The shape the staff-only reads (varsList, varHolders, layoutGet) declare.
-- Before 2026-08-25 it did not exist and those handlers self-gated, which
-- meant their refusals were either invisible or self-audited to compensate.

DFServer.registerHandler{
    action     = "anyThing",
    capability = "any",
    run = function(p) ran[#ran + 1] = p.name; return { ok = true } end,
}
fire(admin, "anyThing")
check(#ran == 1, "a staff caller (any capability) was refused the 'any' gate")

fire(nobody, "anyThing")
check(#ran == 0, "A CALLER WITH NO CAPABILITY AT ALL PASSED THE 'any' GATE")
check(#replies == 1 and replies[1].args.ok == false, "the 'any' refusal sent no answer")
check(#audits == 1 and audits[1].extra ~= nil
      and audits[1].extra:find("refused", 1, true) ~= nil,
    "an 'any' refusal was not audited as a refusal - the whole point of the "
    .. "shape is that the dispatcher's log carries it: "
    .. tostring(audits[1] and audits[1].extra))

-- ---- capability = function(player, args): payload-dependent gates --------
-- layoutSet's shape: __server needs one capability, a sandbox page another.
-- The function must receive the ARGS (that is what makes it payload-aware),
-- and its returned reason must reach both the audit line and the reply.

local gateSaw = nil
DFServer.registerHandler{
    action     = "pagedThing",
    capability = function(p, args)
        gateSaw = args
        if args.page == "open" then return true end
        return false, "missing TheRightCap for " .. tostring(args.page)
    end,
    run = function(p) ran[#ran + 1] = p.name; return { ok = true } end,
}
fire(admin, "pagedThing", { page = "open" })
check(#ran == 1, "the function gate refused a payload it approves")
check(gateSaw ~= nil and gateSaw.page == "open",
    "the function gate never received the args - it cannot be payload-aware blind")

fire(admin, "pagedThing", { page = "locked" })
check(#ran == 0, "the function gate's refusal did not stop the body")
check(#replies == 1 and tostring(replies[1].args.reason):find("TheRightCap", 1, true) ~= nil,
    "the gate's stated reason did not reach the caller: "
    .. tostring(replies[1].args.reason))
check(#audits == 1 and tostring(audits[1].extra):find("TheRightCap", 1, true) ~= nil,
    "the gate's stated reason did not reach the audit log: "
    .. tostring(audits[1] and audits[1].extra))

-- ---- unknown actions and foreign modules --------------------------------

fire(admin, "noSuchAction")
check(#ran == 0, "an unregistered action ran something")
check(#replies == 1 and replies[1].args.ok == false, "an unknown action was not answered")
check(#audits == 1 and audits[1].extra:find("unknown", 1, true) ~= nil,
    "an unknown action was not audited as one")

ran, audits, replies = {}, {}, {}
dispatch("SomeOtherMod", "gatedThing", admin, {})
check(#ran == 0 and #audits == 0 and #replies == 0,
    "another mod's command was dispatched, audited or answered")

-- Our own replies must never re-enter the dispatcher.
ran, audits, replies = {}, {}, {}
dispatch(DFCore.MODULE, "Result", admin, {})
check(#audits == 0 and #replies == 0, "a Result reply was treated as a command")

-- ---- a throwing handler still answers -----------------------------------
-- The retained pcall's actual purpose: a request/response boundary where a
-- silent throw leaves the admin's button dead with no message.

DFServer.registerHandler{
    action = "faultyThing",
    run = function() error("boom") end,
}
fire(admin, "faultyThing")
check(#replies == 1 and replies[1].args.ok == false,
    "a handler that threw left the caller with no answer at all - the button "
    .. "stays dead and nothing says why")

print = realPrint
print(string.format("DFServer: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
