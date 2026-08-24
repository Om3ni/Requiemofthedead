-- RDVarsPush fixture - the server half of the owner mirror.
--
-- WHAT IS AT RISK. This file is thin on purpose - resolve, send, bind - and
-- every one of those is a silent failure when wrong: a push aimed at the wrong
-- player leaks one player's variables to another, a push skipped on touch is a
-- mirror that goes stale with nothing on screen to say so, and a connect
-- handler that never bound means every client plays blind until their first
-- mutation. RDVars itself is real elsewhere (test_rdvars); here it is stubbed
-- to RECORD, because the seam under test is the wiring, not the store.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RDVarsPush: " .. message) end
end

-- ---- stubs ---------------------------------------------------------------

function isServer() return true end
require = function() end

-- The store, recording. mirrorOf answers a distinct table per user so a test
-- can prove WHICH document was sent, not merely that one was.
local mirrorAsked = {}
RDVars = {
    onTouched = nil,
    mirrorOf = function(user)
        mirrorAsked[#mirrorAsked + 1] = user
        return { flags = { probe = 0 }, numbers = {}, who = user }
    end,
}

-- The online list, Java-shaped: size()/get(i), zero-based, like the real one.
local online = {}
function getOnlinePlayers()
    return {
        size = function() return #online end,
        get = function(_, i) return online[i + 1] end,
    }
end
local function player(name)
    return { getUsername = function() return name end }
end

local sent = {}
function sendServerCommand(p, module, command, args)
    sent[#sent + 1] = { player = p, module = module, command = command, args = args }
end
local function drained()
    local out = sent
    sent = {}
    return out
end

-- Events: only what the file binds. OnClientConnect deliberately ABSENT -
-- Dirge documents it as null on B42 dedicated servers, and the file must
-- shrug rather than fault.
local fired = {}
local function event(name)
    local listeners = {}
    fired[name] = listeners
    return { Add = function(fn) listeners[#listeners + 1] = fn end }
end
Events = {
    OnPlayerConnect = event("OnPlayerConnect"),
    OnCreatePlayer  = event("OnCreatePlayer"),
    -- no OnClientConnect, no OnConnected
}

RDVarsPush = nil
local ok, err = pcall(dofile, CORE .. "/server/RDVarsPush.lua")
check(ok, "RDVarsPush loads: " .. tostring(err))
check(RDVarsPush ~= nil, "RDVarsPush global missing")

-- ---- the seam is subscribed ------------------------------------------------

check(type(RDVars.onTouched) == "function",
    "THE PUSH NEVER SUBSCRIBED TO THE STORE. Every mutation would leave every "
    .. "mirror stale, silently - the exact failure this file exists to prevent.")

-- ---- push: the right player, the right document ---------------------------

online = { player("Kriegan"), player("Voss") }

RDVars.onTouched("Voss")
local out = drained()
check(#out == 1, "one touch did not become exactly one send: " .. #out)
check(out[1].player == online[2],
    "THE PUSH WENT TO THE WRONG PLAYER. One player's variables landing on "
    .. "another's client is a leak, not a glitch.")
check(out[1].args and out[1].args.who == "Voss",
    "the document sent was not the touched player's own")
check(out[1].module == "RFTDCore" and out[1].command == "VarsMine",
    "the wire pair drifted from what RDVarsMirror filters on")

-- An offline player is not an error and not a send.
check(RDVarsPush.push("Ghost") == false, "an offline push claimed success")
check(#drained() == 0, "an offline push still sent something")

check(RDVarsPush.push(nil) == false, "a nil user did not refuse")
check(RDVarsPush.push("") == false, "an empty user did not refuse")

-- ---- the connect sweep -----------------------------------------------------

check(#fired.OnPlayerConnect == 1,
    "the connect event that exists was not bound")
check(#fired.OnCreatePlayer == 1, "OnCreatePlayer was not bound")

fired.OnPlayerConnect[1]()
out = drained()
check(#out == 2,
    "A CONNECT DID NOT RE-PUSH EVERYONE ONLINE (got " .. #out .. "). The "
    .. "joining player has no document at all until this fires.")
check(out[1].args.who == "Kriegan" and out[2].args.who == "Voss",
    "the connect sweep sent players something other than their own documents")

-- An empty server sweeps to nobody and does not fault.
online = {}
check(RDVarsPush.pushAll() == 0, "an empty server claimed to have pushed")
check(#drained() == 0, "an empty server still sent something")

print(string.format("RDVarsPush: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
