-- DFVars_Server fixture - the admin surface for RDVars.
--
-- WHAT IS AT RISK, in order.
--
-- 1. AUTHORITY, and again the dispatcher is not carrying it. Two different
--    gates on one command set - server-wide schema on
--    ChangeAndReloadServerOptions, per-player state on
--    CanModifyPlayerStatsInThePlayerStatsUI - so every handler gates itself and
--    these tests are the only thing between a role and a verb it must not have.
--    Written as CROSSED PAIRS: each role is asserted allowed its own verbs and
--    refused the others, because a gate that says yes to everybody passes any
--    test that only checks the yes.
--
-- 2. undefine PURGES. Removing a definition takes it off every player who held
--    it, deliberately - RDVars' own header explains that leaving orphans behind
--    resurrects last season's holders when a name is reused. So it is the most
--    destructive verb in the panel, and the count of who it hit has to reach
--    the admin rather than being a number the server kept to itself.
--
-- 3. A username off the wire becomes a TABLE KEY in a persisted store. RDVars
--    accepts a bare string on purpose - an admin has to be able to grant to
--    somebody who is offline - so the bound lives at this door and nowhere else.
--
-- REAL RDVars and REAL RDVarDefs, not stubs. The interesting failures here are
-- about what the store actually does with a payload - a stub would answer for
-- the fixture's idea of RDVars rather than for RDVars.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DIR  = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL DFVars_Server: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return true end
require = function() return true end
print = function() end

local started
Events = {
    OnServerStarted  = { Add = function(fn) started = fn end },
    OnCharacterDeath = { Add = function() end },
    EveryTenMinutes  = { Add = function() end },
}

local clock = 1000
local modDataMap = {}
ModData = { getOrCreate = function(tag)
    modDataMap[tag] = modDataMap[tag] or {}; return modDataMap[tag]
end }

-- RDConfigStore stubbed to a live table: this fixture is about the wire and the
-- gates, and RDConfigStore has its own fixture for persistence.
local touched = 0
RDConfigStore = { new = function()
    local st = { _d = {}, _s = {} }
    st.boot = function() end
    st.defs = function(self) return self._d end
    st.state = function(self) return self._s end
    st.touchDefs  = function() touched = touched + 1; return true end
    st.touchState = function() touched = touched + 1; return true end
    return st
end }

local caps = {}
RDAccess = {
    roleHas = function(player, capability)
        local held = player and caps[player.name]
        return (held and held[capability]) == true
    end,
}

local audits = {}
DFCore = {
    MODULE = "RFTDDragonfly",
    hasAnyCapability = function(player)
        local held = player and caps[player.name]
        if not held then return false end
        for _ in pairs(held) do return true end
        return false
    end,
    audit = function(action, _, extra)
        audits[#audits + 1] = tostring(action) .. " " .. tostring(extra)
    end,
}

local staffSends, directSends = {}, {}
RDNet = { sendStaff = function(_, command, args)
    staffSends[#staffSends + 1] = { command = command, args = args }
end }
function sendServerCommand(player, _, command, args)
    directSends[#directSends + 1] = { to = player.name, command = command, args = args }
end

local handlers = {}
DFServer = { registerHandler = function(spec) handlers[spec.action] = spec end }

local function player(name, capList)
    caps[name] = {}
    for _, c in ipairs(capList or {}) do caps[name][c] = true end
    return { name = name, getUsername = function(self) return self.name end }
end

-- ---- load ----------------------------------------------------------------

RDShared = { nowMs = function() return clock end, DIR = "RFTD/", EXT_DOC = ".json.txt" }

RDVarDefs = nil
local okD, errD = pcall(dofile, CORE .. "/shared/RDVarDefs.lua")
check(okD, "RDVarDefs loads: " .. tostring(errD))
RDVars = nil
local okV, errV = pcall(dofile, CORE .. "/server/RDVars.lua")
check(okV, "RDVars loads: " .. tostring(errV))

DFVars_Server = nil
local ok, err = pcall(dofile, DIR .. "/server/DFVars_Server.lua")
check(ok, "module loads: " .. tostring(err))
check(started ~= nil, "registration was not deferred to OnServerStarted")
check(handlers.varGrant == nil, "a handler registered at file scope")
started()
for _, a in ipairs({ "varsList", "varsOfPlayer", "varHolders", "varDefine",
                     "varUndefine", "varGrant", "varRevoke", "varSet",
                     "varReset" }) do
    check(handlers[a] ~= nil, a .. " did not register")
    check(handlers[a].capability == nil,
        a .. " grew a dispatcher capability; the gates here differ per verb and "
        .. "one name cannot express them")
end

-- ---- the roles -----------------------------------------------------------

local schemaAdmin = player("Sasha",  { "ChangeAndReloadServerOptions" })
local statAdmin   = player("Petra",  { "CanModifyPlayerStatsInThePlayerStatsUI" })
local moderator   = player("Mo",     { "KickUser" })
local nobody      = player("Nobody", {})

local function run(action, who, args) return handlers[action].run(who, args or {}) end

-- ---- schema verbs --------------------------------------------------------

local CHAR = { kind = "char", name = "Anomaly", revokers = { death = true } }

check(run("varDefine", schemaAdmin, { def = CHAR }).ok == true,
    "a role holding ChangeAndReloadServerOptions could not define a var")
check(RDVars.definition("Anomaly") ~= nil, "the definition did not reach the store")

check(run("varDefine", statAdmin, { def = { kind = "char", name = "Sneaky" } }).ok == false,
    "A PER-PLAYER ROLE DEFINED SERVER-WIDE SCHEMA. Defining changes what this "
    .. "world can express and undefining purges every holder; that is not the "
    .. "same authority as editing one player's state.")
check(RDVars.definition("Sneaky") == nil, "the refused definition reached the store anyway")
check(run("varDefine", moderator, { def = CHAR }).ok == false, "a moderator defined a var")
check(run("varDefine", nobody, { def = CHAR }).ok == false, "a non-staff caller defined a var")

-- Validation is RDVarDefs' job and is NOT re-implemented here; what is asserted
-- is that a bad payload gets its real reason back rather than a generic one.
local badKind = run("varDefine", schemaAdmin, { def = { kind = "wat", name = "X" } })
check(badKind.ok == false, "an unknown kind was defined")
check(tostring(badKind.reason):find("kind", 1, true) ~= nil,
    "the refusal did not name the field: " .. tostring(badKind.reason))
check(run("varDefine", schemaAdmin, { def = { kind = "string", name = "NoFlag" } }).ok == false,
    "a counter with no resetOnDeath was defined - the missing default is the "
    .. "thing RDVarDefs refuses on purpose")
check(run("varDefine", schemaAdmin, {}).ok == false, "a define with no payload was accepted")

-- ---- per-player verbs ----------------------------------------------------

check(run("varGrant", statAdmin, { user = "Kriegan", name = "Anomaly" }).ok == true,
    "a role holding CanModifyPlayerStatsInThePlayerStatsUI could not grant")
check(RDVars.has("Kriegan", "Anomaly") == true, "the grant did not reach the store")

check(run("varGrant", schemaAdmin, { user = "Ghost", name = "Anomaly" }).ok == false,
    "A SCHEMA ROLE CHANGED A PLAYER'S STATE. Defining a var and handing one to "
    .. "somebody are different acts, and the engine gates the second on its own "
    .. "capability (PlayerXpPacket.java:20).")
check(RDVars.has("Ghost", "Anomaly") == false, "the refused grant reached the store")
check(run("varGrant", moderator, { user = "Ghost", name = "Anomaly" }).ok == false,
    "a moderator granted a var")
check(run("varRevoke", schemaAdmin, { user = "Kriegan", name = "Anomaly" }).ok == false,
    "a schema role revoked a var")
check(RDVars.has("Kriegan", "Anomaly") == true, "the refused revoke took effect anyway")

check(run("varRevoke", statAdmin, { user = "Kriegan", name = "Anomaly" }).ok == true,
    "revoke was refused for the right role")
check(RDVars.has("Kriegan", "Anomaly") == false, "revoke did not take")
check(run("varRevoke", statAdmin, { user = "Kriegan", name = "Anomaly" }).ok == false,
    "revoking what nobody holds reported success")

-- Counters. ABSENT IS NOT ZERO, and reset goes back to absent - the panel has
-- to be able to express both or the two-kind split buys nothing.
run("varDefine", schemaAdmin,
    { def = { kind = "string", name = "AnomalyLoot", resetOnDeath = false } })
local setRes = run("varSet", statAdmin, { user = "Kriegan", name = "AnomalyLoot", value = 5 })
check(setRes.ok == true, "set was refused: " .. tostring(setRes.reason))
check(RDVars.get("Kriegan", "AnomalyLoot") == 5, "set did not take")
check(tostring(setRes.message):find("5", 1, true) ~= nil,
    "the reply did not say what the value became: " .. tostring(setRes.message))

-- The value is untrusted, and it is checked exactly once - in RDVars, where
-- the rule lives. Asserted on the REASON as well as the refusal, because a
-- refusal alone cannot tell "the wire value was rejected" from "the var name
-- was wrong", and an earlier draft of this file carried a second, weaker copy
-- of the same check at the door that this assertion would not have caught.
check(run("varSet", statAdmin, { user = "Kriegan", name = "AnomalyLoot" }).ok == false,
    "a set with no value was accepted")
local badVal = run("varSet", statAdmin,
    { user = "Kriegan", name = "AnomalyLoot", value = "5" })
check(badVal.ok == false,
    "a STRING was written into a counter - it arrives off the wire")
check(tostring(badVal.reason):find("got string", 1, true) ~= nil,
    "the refusal did not name the TYPE it got, so it cannot tell the string "
    .. '"5" from the number 5 and reads like a bug in the panel: '
    .. tostring(badVal.reason))
local nanVal = run("varSet", statAdmin,
    { user = "Kriegan", name = "AnomalyLoot", value = 0 / 0 })
check(nanVal.ok == false,
    "NaN was written into a counter - it compares false against every bound "
    .. "afterwards, so every threshold a quest sets on it silently stops firing")
check(tostring(nanVal.reason):find("NaN", 1, true) ~= nil,
    "NaN was refused with the generic type message, which is self-contradicting "
    .. "- its type IS number: " .. tostring(nanVal.reason))
check(RDVars.get("Kriegan", "AnomalyLoot") == 5, "a refused set changed the value")

check(run("varSet", statAdmin, { user = "Kriegan", name = "AnomalyLoot", value = 0 }).ok == true,
    "setting a counter to ZERO was refused - zero is a value, and it is not absent")
check(RDVars.get("Kriegan", "AnomalyLoot") == 0, "the counter did not reach zero")
check(run("varReset", statAdmin, { user = "Kriegan", name = "AnomalyLoot" }).ok == true,
    "reset was refused")
check(RDVars.get("Kriegan", "AnomalyLoot") == nil,
    "reset left the counter at zero instead of ABSENT - collapsing 'never "
    .. "started' with 'back to nothing' is the one thing the two kinds exist "
    .. "to keep apart")

-- ---- the username bound --------------------------------------------------

check(DFVars_Server.validUser("Kriegan") == true, "a normal username was refused")
check(DFVars_Server.validUser("") == false, "an empty username was accepted")
check(DFVars_Server.validUser(nil) == false, "a nil username was accepted")
check(DFVars_Server.validUser(42) == false, "a non-string username was accepted")
check(DFVars_Server.validUser(string.rep("u", 64)) == true, "a username at the limit was refused")
check(DFVars_Server.validUser(string.rep("u", 65)) == false, "an over-long username was accepted")
check(DFVars_Server.validUser("two\nlines") == false,
    "a control character was accepted into a username - it becomes a table key, "
    .. "a JSON string and an audit line, and those three read it differently")

check(run("varGrant", statAdmin, { user = string.rep("u", 200), name = "Anomaly" }).ok == false,
    "an unbounded username reached the store as a key")
check(run("varGrant", statAdmin, { name = "Anomaly" }).ok == false, "a missing username was accepted")

-- ---- undefine, the destructive one --------------------------------------

run("varGrant", statAdmin, { user = "A", name = "Anomaly" })
run("varGrant", statAdmin, { user = "B", name = "Anomaly" })
check(run("varUndefine", statAdmin, { name = "Anomaly" }).ok == false,
    "a per-player role removed a definition, which purges it from EVERY holder")
check(RDVars.definition("Anomaly") ~= nil, "the refused undefine took effect")

audits = {}
local un = run("varUndefine", schemaAdmin, { name = "Anomaly" })
check(un.ok == true, "undefine was refused for the right role: " .. tostring(un.reason))
check(RDVars.definition("Anomaly") == nil, "the definition survived undefine")
check(RDVars.has("A", "Anomaly") == false, "a holder kept the var after undefine")
check(tostring(un.message):find("2 player", 1, true) ~= nil,
    "undefine did not tell the admin how many people it took the var from - "
    .. "this is the most destructive verb in the panel: " .. tostring(un.message))
check(#audits == 1 and audits[1]:find("purged=2", 1, true) ~= nil,
    "the purge count did not reach the audit log: " .. table.concat(audits, " | "))

check(run("varUndefine", schemaAdmin, { name = "NeverExisted" }).ok == false,
    "undefining a var that does not exist reported success")

-- ---- reads ---------------------------------------------------------------

run("varDefine", schemaAdmin, { def = { kind = "char", name = "Wave", revokers = {} } })
run("varGrant", statAdmin, { user = "A", name = "Wave" })
run("varGrant", statAdmin, { user = "B", name = "Wave" })

directSends = {}
check(run("varsList", moderator).ok == true,
    "a moderator could not READ the var list - a panel that cannot show you "
    .. "the state before you change it is worse than one a moderator can see")
check(run("varsList", nobody).ok == false, "a non-staff caller read the var list")
check(#directSends == 1 and directSends[1].command == "AdminVars", "the list reply is wrong")

local defs = directSends[1].args.defs
local wave
for _, d in ipairs(defs) do if d.name == "Wave" then wave = d end end
check(wave ~= nil, "the definition did not reach the reply")
check(wave.holders == 2, "the holder COUNT was wrong: " .. tostring(wave.holders))
check(wave.permanent == true, "a var with no revokers did not report as permanent")

-- A count, not a list. A marker granted to two hundred event attendees is a
-- packet nobody needs and a list nobody reads.
check(type(wave.holders) == "number",
    "the summary sent a holder LIST rather than a count")

directSends = {}
check(run("varsOfPlayer", moderator, { user = "A" }).ok == true, "a staff read was refused")
check(directSends[1].command == "AdminVarsPlayer", "the player reply is wrong")
check(directSends[1].args.username == "A", "the reply did not name its player")
check(#directSends[1].args.chars == 1, "the player's markers did not come back")
check(run("varsOfPlayer", moderator, { user = string.rep("u", 200) }).ok == false,
    "an unbounded username was read")

-- varHolders: the one read whose size is set by how many people play here.
directSends = {}
check(run("varHolders", moderator, { name = "Wave" }).ok == true, "varHolders was refused")
check(directSends[1].command == "AdminVarHolders", "the holders reply is wrong")
check(#directSends[1].args.rows == 2, "the holder rows did not come back")
check(directSends[1].args.total == 2, "the total was wrong")
check(run("varHolders", nobody, { name = "Wave" }).ok == false,
    "a non-staff caller read a holder list")
check(run("varHolders", moderator, { name = "NoSuchVar" }).ok == false,
    "holders answered for an undefined var")

-- A counter answers the same question from the other side, values included.
run("varDefine", schemaAdmin,
    { def = { kind = "string", name = "Progress", resetOnDeath = false } })
run("varSet", statAdmin, { user = "A", name = "Progress", value = 0 })
directSends = {}
run("varHolders", moderator, { name = "Progress" })
check(directSends[1].args.rows[1].value == 0,
    "a counter's holder list dropped a ZERO - zero is a value somebody was set "
    .. "to, and only absent means untouched")

-- The bound. Over the cap the list is TRUNCATED but the total is honest: a list
-- that says 200 of 340 is usable, one that quietly stops at 200 is a lie.
for i = 1, 205 do run("varGrant", statAdmin, { user = "bulk" .. i, name = "Wave" }) end
directSends = {}
run("varHolders", moderator, { name = "Wave" })
local big = directSends[1].args
check(#big.rows == 200, "the holder list was not bounded: " .. #big.rows .. " rows")
check(big.total == 207,
    "the TRUE total did not travel with the truncated list, so the panel would "
    .. "show 200 and imply that is everyone: " .. tostring(big.total))

-- A schema change invalidates every panel's list, so they are told to re-ask.
staffSends = {}
run("varDefine", schemaAdmin, { def = { kind = "char", name = "Wave2" } })
check(#staffSends == 1 and staffSends[1].command == "AdminVarsStale",
    "defining a var did not tell the other panels their list is out of date")
staffSends = {}
run("varUndefine", schemaAdmin, { name = "Wave2" })
check(#staffSends == 1, "undefining a var did not invalidate the other panels")

-- A per-player change pushes the fresh record back, INCLUDING after a refusal:
-- a refused verb leaves the panel showing whatever it believed before.
directSends = {}
run("varGrant", statAdmin, { user = "C", name = "Wave" })
check(#directSends == 1 and directSends[1].args.username == "C",
    "a per-player change did not push the record back")
directSends = {}
run("varRevoke", statAdmin, { user = "C", name = "NoSuchVar" })
check(#directSends == 1,
    "a REFUSED per-player verb pushed nothing, so the panel keeps drawing what "
    .. "it believed before the refusal")

print = realPrint
print(string.format("DFVars_Server: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
