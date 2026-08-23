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
-- 3. A handler with NO declared capability is let straight through. That is the
--    correct behaviour - some handlers genuinely cannot declare one - and it is
--    exactly why those handlers have to audit their own refusals. Pinned here
--    so the reason stays visible from this side too.
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
-- Correct, and the reason the handlers that cannot declare one - the reads
-- gated on "any capability at all", and layoutSet whose gate depends on its
-- payload - audit their own refusals.

fire(nobody, "openThing")
check(#ran == 1,
    "a handler with no declared capability was refused; some genuinely cannot "
    .. "declare one and decide for themselves")
check(#audits == 1 and audits[1].extra == nil,
    "a handler that decides for itself had its command logged as anything other "
    .. "than accepted - which is exactly why those handlers must audit their own "
    .. "refusals: the log cannot do it for them")

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
