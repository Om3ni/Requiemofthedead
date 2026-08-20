-- RDNet fixture - the family's one command intake, and the policy it enforces.
--
-- WHY THIS EXISTS: RDNet is the permission wall for every adopted family token,
-- and until 2026-08-19 nothing pinned its behaviour at all. The rules it
-- enforces are cheap to break by accident - a second registration of the same
-- command, a capability-less endpoint nobody meant to open, a rate bucket that
-- is shared instead of scoped - and each of those is invisible until a player
-- finds it.
--
-- STUBS MODEL THE VERIFIED SURFACE. sendServerCommand is an exposed global
-- whose faults are swallowed by MethodCaller (MethodCaller.java:33-56), so it
-- is a plain recorder here and never throws. RDRate and RDAccess are our own
-- Lua, so they behave exactly as their real implementations do for the shapes
-- this file drives.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDNet.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL RDNet: " .. message) end
end

-- ---- engine / suite stubs ----------------------------------------------
function isServer() return true end

local dispatch
Events = { OnClientCommand = { Add = function(fn) dispatch = fn end } }

local forensic = {}
RDLog = { forensic = function(stream, event, player, payload)
    forensic[#forensic + 1] = { stream = stream, event = event, payload = payload }
end }

-- Real RDRate semantics: a nil scope shares one bucket per username, a scope
-- isolates it. This mirrors RDRate.lua:52-66 closely enough to prove RDNet
-- passes a scope at all, which is the property that matters here.
local buckets, rateWindow = {}, {}
RDRate = {
    allow = function(player, max, windowMs, scope)
        local name = player and player.getUsername and player:getUsername()
        if not name then return true end
        local key = scope and (name .. "|" .. tostring(scope)) or name
        buckets[key] = (buckets[key] or 0) + 1
        rateWindow[key] = true
        return buckets[key] <= (max or 20)
    end,
}

local capabilityOf = {}
RDAccess = {
    can = function(player, capability)
        if capability == nil then return true end          -- RDAccess.lua:62
        local name = player and player.getUsername and player:getUsername()
        return capabilityOf[name] == true
    end,
}

local function mkPlayer(name) return { getUsername = function() return name end } end

local logged = {}
local function capture() print = function(s) logged[#logged + 1] = tostring(s) end end
local function release() print = realPrint end

require = function() return true end
RDNet = nil
capture()
local ok, err = pcall(dofile, SOURCE)
release()
check(ok, "module loads: " .. tostring(err))
check(type(dispatch) == "function", "registers exactly one server-command listener")

-- ---- default-deny -------------------------------------------------------
local ran = {}
RDNet.adopt("TestToken")
RDNet.register("TestToken", "known", { public = true, rate = 20 },
    function(player, args) ran[#ran + 1] = args end)

local alice = mkPlayer("alice")
dispatch("TestToken", "known", alice, { v = 1 })
check(#ran == 1, "a registered command reaches its handler")

forensic = {}
dispatch("TestToken", "neverRegistered", alice, {})
check(#ran == 1, "an unregistered command on an adopted token does NOT execute")
check(#forensic == 1 and forensic[1].payload.reason == "unregistered-command",
      "and is recorded as a rejection with its reason")

-- A token nobody adopted is not ours to police; Guardian still sees it.
forensic = {}
dispatch("SomeOtherMod", "whatever", alice, {})
check(#forensic == 0, "traffic on an unadopted token is left alone entirely")

-- ---- duplicate registration is loud, and first wins ---------------------
local which = {}
RDNet.register("TestToken", "dup", { public = true }, function() which[#which+1] = "first" end)
logged = {}
capture()
RDNet.register("TestToken", "dup", { public = true }, function() which[#which+1] = "second" end)
release()
check(#logged == 1 and logged[1]:find("DUPLICATE", 1, true),
      "a duplicate (token, command) registration is announced loudly")
dispatch("TestToken", "dup", alice, {})
check(#which == 1 and which[1] == "first",
      "and the FIRST registration wins - load order must never pick the handler")

-- ---- an ungated endpoint must be deliberate ------------------------------
logged = {}
capture()
RDNet.register("TestToken", "forgotten", { rate = 5 }, function() end)
release()
check(#logged == 1 and logged[1]:find("RDNet is NOT gating this", 1, true),
      "a capability-less registration declaring neither is called out as an open endpoint")

logged = {}
capture()
RDNet.register("TestToken", "deliberate", { public = true, rate = 5 }, function() end)
release()
check(#logged == 0, "declaring public = true silences it - the point is intent, not friction")

logged = {}
capture()
RDNet.register("TestToken", "gated", { capability = "any", rate = 5 }, function() end)
release()
check(#logged == 0, "and a gated registration says nothing either")

-- The third declaration, for a gate RDNet cannot express statically: a runtime
-- sandbox tier, an ownership test, a proximity check. Without it the only way to
-- register Dirge's admin commands was to call them public, which would have put
-- six admin endpoints on the intended-OPEN list and made that list worthless.
logged = {}
capture()
RDNet.register("TestToken", "tierGated", { gate = "handler", rate = 5 }, function() end)
release()
check(#logged == 0, 'gate = "handler" is accepted for a gate RDNet cannot express')
check(RDNet.registry().TestToken.tierGated.public ~= true,
      "and does NOT count as public - the open list stays honest")

-- ---- capability refusal -------------------------------------------------
local staffRan = 0
RDNet.register("TestToken", "staffOnly", { capability = "any", rate = 20 },
    function() staffRan = staffRan + 1 end)

forensic = {}
dispatch("TestToken", "staffOnly", alice, {})
check(staffRan == 0, "a caller without the capability does not reach the handler")
check(#forensic == 1 and forensic[1].payload.reason == "capability",
      "and the refusal is recorded as a capability rejection")

capabilityOf["alice"] = true
dispatch("TestToken", "staffOnly", alice, {})
check(staffRan == 1, "the same caller with the capability does reach it")

-- ---- rate buckets are scoped per command --------------------------------
-- The regression this pins: without a scope every command drains one shared
-- per-username bucket while each compares the shared count against its own max,
-- so a low-rate command is refused because an unrelated one was busy.
buckets = {}
RDNet.register("TestToken", "chatty", { public = true, rate = 50 }, function() end)
RDNet.register("TestToken", "rare",   { public = true, rate = 2  }, function() end)

local bob = mkPlayer("bob")
for _ = 1, 20 do dispatch("TestToken", "chatty", bob, {}) end
check(buckets["bob|TestToken.chatty"] == 20, "a command's hits land in its own bucket")
check(buckets["bob"] == nil, "and never in the shared bare-username bucket")

local rareRan = 0
RDNet.register("TestToken", "rare2", { public = true, rate = 2 }, function() rareRan = rareRan + 1 end)
dispatch("TestToken", "rare2", bob, {})
check(rareRan == 1,
      "a low-rate command still runs after 20 hits on a busy neighbour - no starvation")

-- ---- the reject hook ----------------------------------------------------
-- Opt-in per token. Answers the two terminal refusals; never the rate one,
-- because a reply to a flood re-amplifies it.
local answered = {}
RDNet.adopt("HookToken", {
    onReject = function(player, command, reason)
        answered[#answered + 1] = { command = command, reason = reason }
    end,
})
RDNet.register("HookToken", "gated", { capability = "any", rate = 20 }, function() end)
RDNet.register("HookToken", "slow",  { public = true, rate = 1 }, function() end)

local carol = mkPlayer("carol")
dispatch("HookToken", "notAThing", carol, {})
check(#answered == 1 and answered[1].reason == "unregistered-command",
      "the reject hook answers an unknown command")

dispatch("HookToken", "gated", carol, {})
check(#answered == 2 and answered[2].reason == "capability",
      "and answers a capability refusal")

buckets = {}
answered = {}
dispatch("HookToken", "slow", carol, {})   -- 1st: allowed
dispatch("HookToken", "slow", carol, {})   -- 2nd: over rate
check(#answered == 0,
      "but stays silent on a rate refusal - answering a flood would re-amplify it")

-- A token without a hook is unchanged: rejections are recorded, never answered.
forensic = {}
dispatch("TestToken", "stillNotAThing", alice, {})
check(#forensic == 1, "a token with no hook still records its rejections")

-- ---- the registry view --------------------------------------------------
local reg = RDNet.registry()
check(type(reg.TestToken) == "table" and reg.TestToken.known ~= nil,
      "registry() lists adopted tokens and their commands")
check(reg.TestToken.staffOnly.capability == "any" and reg.TestToken.known.public == true,
      "and carries the policy each command was registered under")
check(reg.TestToken.known.handler == nil,
      "but never the handler - this answers what is registered, not how to run it")
reg.TestToken.known = nil
check(RDNet.registry().TestToken.known ~= nil,
      "and it is a copy: mutating the view cannot disarm the live registry")

realPrint(string.format("RDNet: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
