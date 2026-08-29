-- DFVars_Server fixture - the admin surface for RDVars.
--
-- WHAT IS AT RISK, in order.
--
-- 1. AUTHORITY. Two different gates on one command set - server-wide schema on
--    ChangeAndReloadServerOptions, per-player state on
--    CanModifyPlayerStatsInThePlayerStatsUI - and each verb DECLARES its own,
--    which the dispatcher enforces (pinned separately in test_dfserver.lua).
--    `run` below applies the declared capability the way DFServer does, so these
--    stay behaviour tests rather than becoming declaration tests.
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
RDConfigStore = {}
RDConfigStore.new = function()
    local st = { _d = {}, _s = {} }
    st.boot = function() end
    st.defs = function(self) return self._d end
    st.state = function(self) return self._s end
    st.touchDefs  = function() touched = touched + 1; return true end
    st.touchState = function() touched = touched + 1; return true end
    return st
end
-- A stub must implement the surface it stands in for, not the subset today's
-- caller happens to reach. lazy() is how a consumer is meant to hold a store,
-- and leaving it out here meant RDVars stopped loading the moment it adopted
-- the supported pattern - a fixture failure that says nothing about RDVars.
RDConfigStore.lazy = function(spec)
    local store
    return function()
        if not store then store = RDConfigStore.new(spec) end
        store:boot()
        return store
    end
end

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
-- The online roster. Set per block; the holder list must merge it in, because
-- "hand this to the four people standing in front of me" is the ordinary case
-- and "revoke it from somebody who logged off" is the correct one.
local onlineRoster = {}
function getOnlinePlayers()
    return {
        size = function() return #onlineRoster end,
        get  = function(_, i)
            local n = onlineRoster[i + 1]
            return n and { getUsername = function() return n end } or nil
        end,
    }
end

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

-- The REAL RDShared, with only the clock replaced - RDVars resolves every
-- player through RDShared.username, and a hand-written stub of three fields
-- stopped covering that the day it moved into Core.
require = function() return true end
dofile(CORE .. "/shared/RDShared.lua")
RDShared.nowMs = function() return clock end

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
-- Every verb's DECLARED gate, asserted by name. A verb that silently loses its
-- declaration would still pass every behaviour test below, because `run` applies
-- whatever is declared - so the declaration is pinned on its own.
--
-- The three reads declare capability = "any" (dispatcher support 2026-08-25):
-- their gate is "any capability at all", which the dispatcher can now express,
-- so the self-gate-and-self-audit compensation is gone and a refused read is
-- audited AS a refusal like every other verb.
local EXPECTED_GATE = {
    varsList     = "any", varsOfPlayer = "any", varHolders = "any",
    varDefine    = "ChangeAndReloadServerOptions",
    varUndefine  = "ChangeAndReloadServerOptions",
    varGrant     = "CanModifyPlayerStatsInThePlayerStatsUI",
    varRevoke    = "CanModifyPlayerStatsInThePlayerStatsUI",
    varSet       = "CanModifyPlayerStatsInThePlayerStatsUI",
    varReset     = "CanModifyPlayerStatsInThePlayerStatsUI",
}
for action, want in pairs(EXPECTED_GATE) do
    check(handlers[action] ~= nil, action .. " did not register")
    do
        check(handlers[action] and handlers[action].capability == want,
            action .. " declares '" .. tostring(handlers[action]
                and handlers[action].capability) .. "', expected '" .. want
            .. "'. A verb that checks inside its own body instead loses the "
            .. "dispatcher's refusal reply AND has its refused attempts logged "
            .. "as accepted commands.")
    end
end

-- ---- the roles -----------------------------------------------------------

local schemaAdmin = player("Sasha",  { "ChangeAndReloadServerOptions" })
local statAdmin   = player("Petra",  { "CanModifyPlayerStatsInThePlayerStatsUI" })
local moderator   = player("Mo",     { "KickUser" })
local nobody      = player("Nobody", {})

-- Dispatch the way DFServer does: apply the DECLARED capability first, then the
-- body. Mirrored here rather than loading the real dispatcher because these
-- assertions read a handler's return value, which DFServer converts into a reply
-- packet - and the dispatcher's own enforcement is pinned in test_dfserver.lua,
-- so this is standing in for tested behaviour rather than for an assumption.
local function run(action, who, args)
    local h = handlers[action]
    if h.capability then
        local allowed
        if h.capability == "any" then
            allowed = DFCore.hasAnyCapability(who)
        elseif type(h.capability) == "function" then
            allowed = h.capability(who, args or {})
        else
            allowed = RDAccess.roleHas(who, h.capability)
        end
        if not allowed then
            -- The real dispatcher audits every refusal; mirror that so the
            -- audit assertions test the same observable the log carries.
            DFCore.audit(action, who, "(refused)")
            return { ok = false, reason = "Refused for " .. action }
        end
    end
    return h.run(who, args or {})
end

-- ---- schema verbs --------------------------------------------------------

local CHAR = { kind = "flag", name = "Anomaly", revokers = { death = true } }

check(run("varDefine", schemaAdmin, { def = CHAR }).ok == true,
    "a role holding ChangeAndReloadServerOptions could not define a var")
check(RDVars.definition("Anomaly") ~= nil, "the definition did not reach the store")

check(run("varDefine", statAdmin, { def = { kind = "flag", name = "Sneaky" } }).ok == false,
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
check(run("varDefine", schemaAdmin, { def = { kind = "counter", name = "NoFlag" } }).ok == false,
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
    { def = { kind = "counter", name = "AnomalyLoot", resetOnDeath = false } })
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

run("varDefine", schemaAdmin, { def = { kind = "flag", name = "Wave", revokers = {} } })
run("varGrant", statAdmin, { user = "A", name = "Wave" })
run("varGrant", statAdmin, { user = "B", name = "Wave" })

directSends = {}
check(run("varsList", moderator).ok == true,
    "a moderator could not READ the var list - a panel that cannot show you "
    .. "the state before you change it is worse than one a moderator can see")
audits = {}
check(run("varsList", nobody).ok == false, "a non-staff caller read the var list")
check(#audits == 1 and audits[1]:find("refused", 1, true) ~= nil,
    "a refused read did not reach the audit log as a REFUSAL - the dispatcher "
    .. "owns the gate now, and a refusal logged as anything else is the bug "
    .. "the 'any' shape was built to end: " .. table.concat(audits, " | "))
check(#directSends == 1 and directSends[1].command == "AdminVars", "the list reply is wrong")

local defs = directSends[1].args.defs
local wave
for _, d in ipairs(defs) do if d.name == "Wave" then wave = d end end
check(wave ~= nil, "the definition did not reach the reply")
check(wave.holders == 2, "the holder COUNT was wrong: " .. tostring(wave.holders))
check(wave.permanent == true, "a var with no revokers did not report as permanent")

-- A count, not a list. A flag granted to two hundred event attendees is a
-- packet nobody needs and a list nobody reads.
check(type(wave.holders) == "number",
    "the summary sent a holder LIST rather than a count")

directSends = {}
check(run("varsOfPlayer", moderator, { user = "A" }).ok == true, "a staff read was refused")
check(directSends[1].command == "AdminVarsPlayer", "the player reply is wrong")
check(directSends[1].args.username == "A", "the reply did not name its player")
check(#directSends[1].args.flags == 1, "the player's flags did not come back")
check(run("varsOfPlayer", moderator, { user = string.rep("u", 200) }).ok == false,
    "an unbounded username was read")

-- varHolders: the one read whose size is set by how many people play here.
onlineRoster = {}
directSends = {}
check(run("varHolders", moderator, { name = "Wave" }).ok == true, "varHolders was refused")
check(directSends[1].command == "AdminVarHolders", "the holders reply is wrong")
check(#directSends[1].args.rows == 2, "the holder rows did not come back")
check(directSends[1].args.total == 2, "the total was wrong")

-- Online players appear whether or not they hold it: the panel's ordinary job
-- is handing a flag to somebody who is standing there, and a list of holders
-- alone can never offer that.
onlineRoster = { "Zed", "A" }
directSends = {}
run("varHolders", moderator, { name = "Wave" })
local merged = directSends[1].args
local byUser = {}
for _, r in ipairs(merged.rows) do byUser[r.user] = r end
check(byUser["Zed"] ~= nil,
    "AN ONLINE PLAYER WHO DOES NOT HOLD THE VAR WAS ABSENT. There is then no "
    .. "way to grant one from this panel except by typing a username.")
check(byUser["Zed"].online == true, "an online row was not marked online")
check(byUser["Zed"].holds == nil, "a non-holder was reported as holding it")
check(byUser["A"].holds == true and byUser["A"].online == true,
    "an online HOLDER lost one of its two facts")
check(byUser["B"] ~= nil and byUser["B"].online == nil,
    "an OFFLINE holder vanished - somebody who earned a flag last night and "
    .. "logged off must still be revocable today")
-- HOLDERS FIRST, then the roster. A: holder and online. B: holder, offline.
-- Zed: online, holds nothing. The window asks "who holds this", so the holders
-- occupy the top of the list whether or not they are logged in, and the people
-- who are merely present sit under them. Put the roster first - which is what
-- this did until 2026-08-23 - and a variable nobody holds opens with the
-- reading admin's own name on row one, which reads as the panel having added
-- them to it.
check(merged.rows[1].user == "A" and merged.rows[2].user == "B"
      and merged.rows[3].user == "Zed",
    "the three groups are out of order: "
    .. merged.rows[1].user .. ", " .. merged.rows[2].user .. ", "
    .. tostring(merged.rows[3] and merged.rows[3].user))
check(merged.total == 3, "the total lost somebody: " .. tostring(merged.total))
check(run("varHolders", nobody, { name = "Wave" }).ok == false,
    "a non-staff caller read a holder list")
check(run("varHolders", moderator, { name = "NoSuchVar" }).ok == false,
    "holders answered for an undefined var")

-- A counter answers the same question from the other side, values included.
run("varDefine", schemaAdmin,
    { def = { kind = "counter", name = "Progress", resetOnDeath = false } })
run("varSet", statAdmin, { user = "A", name = "Progress", value = 0 })
directSends = {}
run("varHolders", moderator, { name = "Progress" })
check(directSends[1].args.rows[1].value == 0,
    "a counter's holder list dropped a ZERO - zero is a value somebody was set "
    .. "to, and only absent means untouched")

-- The bound, and WHICH rows survive it. Online players are never the ones cut:
-- dropping one removes the very person the admin is acting on, while an
-- unlisted offline holder is still reachable by name.
for i = 1, 205 do run("varGrant", statAdmin, { user = "bulk" .. i, name = "Wave" }) end
onlineRoster = { "Zed", "A" }
directSends = {}
run("varHolders", moderator, { name = "Wave" })
local big = directSends[1].args
check(#big.rows == 200, "the holder list was not bounded: " .. #big.rows .. " rows")
check(big.total == 208,
    "the TRUE total did not travel with the truncated list, so the panel would "
    .. "show 200 and imply that is everyone: " .. tostring(big.total))
local sawOnline = {}
for _, r in ipairs(big.rows) do if r.online then sawOnline[r.user] = true end end
check(big.rows[#big.rows].user == "Zed",
    "THE ROSTER WAS NOT WHAT SURVIVED AT THE TAIL. Order and truncation are "
    .. "separate decisions here: holders read first, and the bound is spent on "
    .. "OFFLINE holders alone. Filling to the bound in display order would put "
    .. "the roster past the cut on any variable with two hundred holders - "
    .. "exactly the case where handing the flag to somebody present matters.")
check(sawOnline["Zed"] and sawOnline["A"],
    "AN ONLINE PLAYER WAS TRUNCATED OUT of an oversized list. The bound exists "
    .. "for the two hundred offline holders nobody is looking at, not for the "
    .. "handful of people the admin is actually standing next to.")

-- SORTED, and not by luck. All three groups come out of hash iteration, whose
-- order Lua does not define - so an unsorted list reshuffles between two reads
-- of a variable nothing has changed, which reads as the panel losing track of
-- who holds what. Eight names, deliberately not in alphabetical order as
-- written, so the assertion is about table.sort and not about insertion order.
run("varDefine", schemaAdmin, { def = { kind = "flag", name = "Sorted" } })
local crowd = { "mike", "alpha", "zulu", "bravo", "yankee", "charlie", "xray", "delta" }
for _, u in ipairs(crowd) do run("varGrant", statAdmin, { user = u, name = "Sorted" }) end
onlineRoster = crowd
directSends = {}
run("varHolders", moderator, { name = "Sorted" })
local ordered = directSends[1].args.rows
check(#ordered == #crowd, "the sorting case lost rows: " .. #ordered)
local slip = nil
for i = 2, #ordered do
    if ordered[i - 1].user > ordered[i].user then
        slip = ordered[i - 1].user .. " came before " .. ordered[i].user
    end
end
check(slip == nil, "THE HOLDER LIST CAME BACK UNSORTED: " .. tostring(slip))

-- The offline half sorts too, and separately: it is a different table, so one
-- table.sort proves nothing about the other.
onlineRoster = {}
directSends = {}
run("varHolders", moderator, { name = "Sorted" })
local offline = directSends[1].args.rows
local offSlip = nil
for i = 2, #offline do
    if offline[i - 1].user > offline[i].user then
        offSlip = offline[i - 1].user .. " came before " .. offline[i].user
    end
end
check(offSlip == nil, "the OFFLINE holders came back unsorted: " .. tostring(offSlip))
run("varUndefine", schemaAdmin, { name = "Sorted" })

-- ---- world counters ------------------------------------------------------
--
-- One number the whole server shares. The window that shows it has no holder
-- list, so the read has to answer with the VALUE, and the two verbs are their
-- own commands rather than a scope branch inside varSet/varReset: those carry
-- a username, validate it, and push that player's record back afterwards, and
-- none of the three means anything here.

run("varDefine", schemaAdmin,
    { def = { kind = "counter", name = "Runs", scope = "world" } })

directSends = {}
check(run("varHolders", moderator, { name = "Runs" }).ok == true,
    "a world counter could not be read")
local wpay = directSends[1].args
check(wpay.scope == "world", "the reply did not say which scope it was")
check(#wpay.rows == 0 and wpay.total == 0,
    "A WORLD COUNTER CAME BACK WITH HOLDER ROWS. Nobody holds it, and any row "
    .. "here is a name an admin can aim a verb at.")
check(wpay.value == nil,
    "AN UNTOUCHED WORLD COUNTER REPORTED A VALUE. Absent means nothing has "
    .. "ever written to it; a panel drawing that as 0 says a quest has been "
    .. "completed zero times, which is a different claim.")

-- THE GATE IS THE SCHEMA CAPABILITY, not the per-player one. An admin trusted
-- to fix one player's sample count is not automatically trusted to declare
-- what the whole server has done.
check(run("varWorldSet", statAdmin, { name = "Runs", value = 5 }).ok == false,
    "THE PER-PLAYER CAPABILITY REACHED A SERVER-WIDE NUMBER. Every quest gate "
    .. "on the server reads it.")
check(run("varWorldSet", nobody, { name = "Runs", value = 5 }).ok == false,
    "a caller with no capability set a world counter")

directSends = {}
check(run("varWorldSet", schemaAdmin, { name = "Runs", value = 42 }).ok == true,
    "a world counter could not be set")
check(directSends[1] and directSends[1].args.value == 42,
    "the verb did not push the new value back, so the window would keep "
    .. "drawing what it believed before")

-- Zero is a value somebody set. Clearing is the other thing.
check(run("varWorldSet", schemaAdmin, { name = "Runs", value = 0 }).ok == true,
    "a world counter could not be set to zero")
directSends = {}
run("varHolders", moderator, { name = "Runs" })
check(directSends[1].args.value == 0, "a stored zero read back as absent")

directSends = {}
check(run("varWorldReset", schemaAdmin, { name = "Runs" }).ok == true,
    "a world counter could not be cleared")
check(directSends[1].args.value == nil,
    "A CLEARED WORLD COUNTER CAME BACK AS ZERO. Absent and zero are the two "
    .. "answers every repeatable quest gates on.")

-- Refusals still push, for the same reason the per-player verbs do: a refused
-- action leaves the panel showing whatever it believed before, and the one
-- thing an admin needs after one is the value that is actually stored.
run("varWorldSet", schemaAdmin, { name = "Runs", value = 7 })
directSends = {}
local bad = run("varWorldSet", schemaAdmin, { name = "Runs", value = "abc" })
check(bad.ok == false, "a world counter accepted something that is not a number")
check(directSends[1] and directSends[1].args.value == 7,
    "a REFUSED world write pushed nothing back")

-- The verbs refuse anything that is not a world counter, rather than falling
-- through to a player write with no player.
check(run("varWorldSet", schemaAdmin, { name = "Progress", value = 1 }).ok == false,
    "A PER-PLAYER COUNTER WAS WRITTEN THROUGH THE WORLD VERB. It carries no "
    .. "username, so the write would land nowhere or everywhere.")
check(run("varWorldSet", schemaAdmin, { name = "Wave", value = 1 }).ok == false,
    "a FLAG was written through the world counter verb")
check(run("varWorldSet", schemaAdmin, { name = "NoSuchVar", value = 1 }).ok == false,
    "an undefined var was written")
check(run("varWorldReset", schemaAdmin, { name = "NoSuchVar" }).ok == false,
    "an undefined var was cleared")

-- And a world counter is not reachable through the per-player verbs, which
-- would otherwise write it once per admin who tried.
check(run("varSet", statAdmin, { user = "A", name = "Runs", value = 3 }).ok == true,
    "the per-player verb errored rather than routing by scope")
directSends = {}
run("varHolders", moderator, { name = "Runs" })
check(directSends[1].args.value == 3,
    "a per-player set on a world counter went somewhere other than the world "
    .. "slot: " .. tostring(directSends[1].args.value))
check(#directSends[1].args.rows == 0,
    "A PER-PLAYER SET ON A WORLD COUNTER CREATED A HOLDER. RDVars routes by "
    .. "the definition on purpose, so a kit writing add:1 never has to know "
    .. "which scope the DM picked - but it must not leave a record behind.")

run("varUndefine", schemaAdmin, { name = "Runs" })

-- A schema change invalidates every panel's list, so they are told to re-ask.
staffSends = {}
run("varDefine", schemaAdmin, { def = { kind = "flag", name = "Wave2" } })
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
