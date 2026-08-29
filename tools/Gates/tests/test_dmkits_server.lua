-- DMKits_Server fixture - the wire surface for kits.
--
-- WHAT IS AT RISK, in order.
--
-- 1. THE INVARIANT. A player supplies EVENTS, the DM supplies DEFINITIONS. The
--    claim payload carries an id and nothing else, and the proof that a forged
--    grant list does nothing is not "we validate it" - it is that the handler
--    never reads it. That is asserted by sending one and checking the player
--    got the catalogue's kit instead.
--
-- 2. AUTHORITY, as CROSSED PAIRS. Each role is asserted allowed its own verbs
--    and refused the others, because a gate that says yes to everybody passes
--    any test that only checks the yes. Every gate is DECLARED - RDNet enforces
--    it, unlike DFServer, because RDAccess.can understands the literal "any" -
--    so the declarations are pinned separately from the behaviour.
--
-- 3. WHAT A PLAYER LEARNS. An unknown kit and an unearned kit must be
--    indistinguishable from the outside, or the catalogue leaks one guess at a
--    time. kitMine must not carry requirement lists for the same reason.
--
-- 4. ORDER OF EFFECTS ON A CLAIM. Record the claim, THEN revoke the flags the
--    kit consumes. Reversed, the revoke removes the flag the entitlement check
--    just passed on, and a retry is refused for a reason created by the first
--    attempt.
--
-- REAL DMKits, DMGrant, DMKitDefs, DMRoll, DMRegistry, RDVars and
-- RDConfigStore. Only the engine and RDNet's transport are stubbed.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL DMKits_Server: " .. message) end
end

-- ---- engine stubs ---------------------------------------------------------

function isServer() return true end
print = function() end
function instanceof(o, cls) return type(o) == "table" and o.__class == cls end

Capability = { SandboxOptions = "SandboxOptions", AddItem = "AddItem" }

local fs = {}
function getFileReader(path)
    local c = fs[path]; if c == nil then return nil end
    local lines, i = {}, 1
    for line in (c .. "\n"):gmatch("(.-)\n") do lines[i] = line; i = i + 1 end
    if lines[#lines] == "" then lines[#lines] = nil end
    local pos = 0
    return { readLine = function() pos = pos + 1; return lines[pos] end,
             close = function() end }
end
function getFileWriter(path, _, append)
    if not append then fs[path] = "" end
    return { write = function(_, s) fs[path] = (fs[path] or "") .. s end,
             close = function() end }
end

local modDataMap = {}
ModData = { getOrCreate = function(t)
    modDataMap[t] = modDataMap[t] or {}; return modDataMap[t] end }

local started
Events = {
    OnServerStarted  = { Add = function(fn) started = fn end },
    OnCharacterDeath = { Add = function() end },
    EveryTenMinutes  = { Add = function() end },
    OnClientCommand  = { Add = function() end },
}

local clock = 1000000

-- DMAudit stamps its records off the wall clock and the world age. Both are
-- pinned to the fixture's own clock so a record's timestamp is a fact under
-- test rather than whatever the machine says.
function getTimestamp() return math.floor(clock / 1000) end
function getTimestampMs() return clock end
function getGameTime()
    return { getWorldAgeHours = function() return 72.0 end }
end

-- Registries, as DMRegistry crosses them.
local function javaList(items)
    return setmetatable({}, { __index = function(_, k)
        if k == "size" then return function() return #items end end
        if k == "get"  then return function(_, i) return items[i + 1] end end
    end })
end
local traitObjects = {}
local function traitDef(id, label)
    local t = setmetatable({}, { __tostring = function() return id end })
    traitObjects[id] = t
    return { getType = function() return t end, getLabel = function() return label end }
end
CharacterTraitDefinition = { getTraits = function()
    return javaList({ traitDef("base:Brave", "Brave") }) end }
local MAX_SENTINEL = { name = "MAX" }
Perks = { MAX = MAX_SENTINEL, Fitness = { name = "Fitness" },
          Strength = { name = "Strength" },
          FromString = function(s)
              if s == "Woodwork" then return { name = "Woodwork" } end
              return MAX_SENTINEL end }
CharacterStat = { FITNESS = "FITNESS", STRENGTH = "STRENGTH" }
local liveItems = { ["Base.Axe"] = true, ["Base.Crowbar"] = true }
function getScriptManager() return { getItem = function(_, ft)
    return liveItems[ft] and {} or nil end } end
function ZombRand(n) return 0 end
function sendAddItemToContainer() end

-- A character implementing the surface DMGrant was written against.
local function character(name)
    local held, contents = {}, {}
    local inv = { AddItem = function(_, ft)
        if not liveItems[ft] then return nil end
        local item = { type = ft }; contents[#contents + 1] = item; return item
    end }
    return {
        __class = "IsoPlayer", name = name,
        getUsername = function(self) return self.name end,
        getInventory = function() return inv end,
        getCharacterTraits = function()
            return { get = function(_, t) return held[t] == true end,
                     add = function(_, t) held[t] = true end } end,
        getXp = function() return { AddXP = function() end } end,
        getPerkLevel = function() return 5 end,
        getStats = function() return { set = function() end } end,
        getNetworkCharacterAI = function()
            return { updateXpChecker = function() end } end,
        _contents = contents, _held = held,
    }
end

local onlineRoster = {}
function getOnlinePlayers()
    return { size = function() return #onlineRoster end,
             get = function(_, i) return onlineRoster[i + 1] end }
end

-- ---- RDNet transport, captured -------------------------------------------

local handlers, adoptOpts = {}, nil
local sent, staffSent = {}, {}
RDNet = {
    adopt = function(_, opts) adoptOpts = opts end,
    register = function(_, command, opts, handler)
        handlers[command] = { opts = opts or {}, handler = handler }
    end,
    reply = function(player, _, command, args)
        sent[#sent + 1] = { to = player and player.name, command = command, args = args }
    end,
    sendStaff = function(_, command, args)
        staffSent[#staffSent + 1] = { command = command, args = args }
    end,
}

local caps = {}
RDAccess = {
    can = function(player, requirement)
        if requirement == nil then return true end
        local held = player and caps[player.name] or {}
        if requirement == "any" then
            for _ in pairs(held) do return true end
            return false
        end
        return held[requirement] == true
    end,
}
local forensics = {}
-- A stub must implement the surface it stands in for, not the subset today's
-- caller happens to reach. channel() is how a satellite is meant to hold a
-- stream, and leaving it out means the module fails to LOAD the moment it
-- adopts the supported pattern - a fixture failure that says nothing about the
-- module. channel here is the real behaviour, not a no-op, so a record written
-- through it is still observable below.
RDLog = {}
RDLog.forensic = function(_, evt, _, payload)
    forensics[#forensics + 1] = { evt = evt, payload = payload }
end
RDLog.channel = function(stream, modId)
    return function(evt, subj, payload)
        RDLog.forensic(stream, evt, subj, payload, modId)
    end
end
local chronicles = {}
RDLog.chronicle = function(evt, subj, payload)
    chronicles[#chronicles + 1] = { evt = evt, subj = subj, payload = payload }
    return true
end

-- Files are captured, not written. DMAudit needs a directory name per player;
-- the SteamID suffix is what a real RDIdentity adds and what proves a record
-- was filed under the person it is about.
local audited = {}
RDIdentity = { dirFor = function(subj)
    return (RDShared and RDShared.username(subj)) or "unknown"
end }
function getFileWriter(path, _createIfNull, append)
    return {
        write = function(_, line)
            audited[#audited + 1] = { path = path, line = line, append = append }
        end,
        close = function() end,
    }
end

require = function() return true end
dofile(CORE .. "/shared/RDShared.lua")
RDShared.nowMs = function() return clock end
dofile(CORE .. "/shared/RDJson.lua")
dofile(CORE .. "/shared/RDVarDefs.lua")
dofile(CORE .. "/shared/RDEvents.lua")
dofile(DM .. "/shared/DMRoll.lua")
dofile(DM .. "/shared/DMKitDefs.lua")
dofile(DM .. "/shared/DMRegistry.lua")
-- The REAL RDFile (write mechanism since 2026-08-25).
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDFile.lua")
dofile(CORE .. "/server/RDConfigStore.lua")
dofile(CORE .. "/server/RDVars.lua")
dofile(DM .. "/server/DMKits.lua")
dofile(DM .. "/server/DMGrant.lua")
-- LOADED FOR REAL, not stubbed. DMKits_Server calls it behind `if DMAudit then`
-- and passes a subject and an action name; a stub would accept anything, which
-- is precisely what a fixture must not do when the module under test is the one
-- deciding WHO a permanent record is about.
dofile(DM .. "/server/Kits/DMAudit.lua")

DMKits_Server = nil
local ok, err = pcall(dofile, DM .. "/server/DMKits_Server.lua")
check(ok, "module loads: " .. tostring(err))
check(started ~= nil, "registration was not deferred to OnServerStarted")
check(next(handlers) == nil, "a handler registered at file scope")
started()

-- ---- every gate is DECLARED ----------------------------------------------
-- A verb that silently lost its declaration would still pass every behaviour
-- test below, because `run` applies whatever is declared. So the declarations
-- are pinned on their own, by name.

local EXPECTED = {
    kitList      = "any",
    kitClaimants = "any",
    kitDefine    = "SandboxOptions",
    kitDelete    = "SandboxOptions",
    kitForget    = "SandboxOptions",
    kitGrantTo   = "AddItem",
    kitMine      = "PUBLIC",
    kitClaim     = "PUBLIC",
}
for action, want in pairs(EXPECTED) do
    local h = handlers[action]
    check(h ~= nil, action .. " did not register")
    if h then
        if want == "PUBLIC" then
            check(h.opts.public == true, action .. " is not declared public - "
                .. "an open endpoint must be a decision, not an omission")
            check(h.opts.capability == nil, action .. " is public AND gated")
        else
            check(h.opts.capability == want, action .. " declared "
                .. tostring(h.opts.capability) .. ", expected " .. want)
        end
        check(type(h.opts.rate) == "number", action .. " declared no rate limit")
    end
end
check(adoptOpts and type(adoptOpts.onReject) == "function",
    "the token adopted without a reject hook, so a refused caller hears nothing")

-- ---- the harness ---------------------------------------------------------

local function player(name, capList)
    caps[name] = {}
    for _, c in ipairs(capList or {}) do caps[name][c] = true end
    return character(name)
end

-- Applies the DECLARED gate the way RDNet does, so these stay behaviour tests.
local function run(action, p, args)
    sent, staffSent = {}, {}
    local h = handlers[action]
    if not h then return nil end
    if not h.opts.public and not RDAccess.can(p, h.opts.capability) then
        return { refusedByGate = true }
    end
    h.handler(p, args)
    return sent[#sent]
end

local function reset()
    fs, modDataMap, forensics, onlineRoster = {}, {}, {}, {}
    chronicles, audited = {}, {}
    clock = 1000000
    DMRegistry.forget()
    dofile(CORE .. "/server/RDConfigStore.lua")
    dofile(CORE .. "/server/RDVars.lua")
    dofile(DM .. "/server/DMKits.lua")
    dofile(DM .. "/server/DMGrant.lua")
    RDVars.define{ kind = "flag", name = "Delver" }
    RDVars.define{ kind = "flag", name = "Ticket", revokers = { kit = "reward" } }
    RDVars.define{ kind = "counter", name = "Samples", resetOnDeath = false }
end

local function defineKit(over)
    local d = { id = "reward", kind = "item", label = "Delver's Reward",
                claim = { once = true },
                grants = { { kind = "item", type = "Base.Axe" } } }
    for k, v in pairs(over or {}) do d[k] = v end
    return DMKits.define(d, "seed")
end

-- ---- crossed pairs -------------------------------------------------------

reset()
local author = player("author", { "SandboxOptions" })
local giver  = player("giver",  { "AddItem" })
local nobody = player("nobody", {})

for _, action in ipairs({ "kitDefine", "kitDelete", "kitForget" }) do
    check(run(action, author, { id = "reward" }).refusedByGate ~= true,
        action .. " refused the author who holds SandboxOptions")
    check(run(action, giver, { id = "reward" }).refusedByGate == true,
        action .. " admitted a role holding only AddItem")
    check(run(action, nobody, { id = "reward" }).refusedByGate == true,
        action .. " admitted a role holding nothing")
end
check(run("kitGrantTo", giver, {}).refusedByGate ~= true,
    "kitGrantTo refused the role holding AddItem")
check(run("kitGrantTo", author, {}).refusedByGate == true,
    "kitGrantTo admitted a role holding only SandboxOptions")
-- "any" means staff at all, so either role passes and a plain player does not.
check(run("kitList", giver, {}).refusedByGate ~= true, "kitList refused staff")
check(run("kitList", author, {}).refusedByGate ~= true, "kitList refused staff")
check(run("kitList", nobody, {}).refusedByGate == true,
    "kitList admitted a player holding no capability at all")

-- ---- authoring -----------------------------------------------------------

reset()
local r = run("kitDefine", author, { kit = { id = "reward", kind = "item",
    label = "Reward", claim = { once = true },
    grants = { { kind = "item", type = "Base.Axe" } } } })
check(r and r.args.ok == true, "a valid kit was refused: " .. tostring(r and r.args.reason))
check(DMKits.definition("reward") ~= nil, "the kit did not reach the store")
check(#staffSent == 1 and staffSent[1].command == "KitsStale",
    "saving a kit did not tell the other staff panels to refresh")

r = run("kitDefine", author, { kit = { id = "bad", kind = "item",
    claim = { once = true }, grants = { { kind = "item", type = "Base.Ghost" } } } })
check(r and r.args.ok == false, "a kit naming a dead item saved")
check(type(r.args.reason) == "string" and r.args.reason ~= "",
    "the refusal carried no reason for the admin to read")
r = run("kitDefine", author, {})
check(r and r.args.ok == false, "kitDefine accepted a payload with no kit")
r = run("kitDefine", author, { kit = "reward" })
check(r and r.args.ok == false, "kitDefine accepted a kit that was not a table")

-- Deleting says what it did NOT do. "Deleting a kit clears its claims" is the
-- reasonable assumption and it is wrong.
r = run("kitDelete", author, { id = "reward" })
check(r and r.args.ok == true, "deleting a real kit failed")
check(r.args.message:lower():find("claim", 1, true),
    "the delete confirmation did not mention that claims are kept: "
    .. tostring(r.args.message))
check(run("kitDelete", author, { id = "reward" }).args.ok == false,
    "deleting an absent kit reported success")
check(run("kitDelete", author, {}).args.ok == false, "kitDelete accepted no id")

-- ---- an admin hands a kit over -------------------------------------------

reset()
defineKit()
local pat = character("pat")
onlineRoster = { pat }

r = run("kitGrantTo", giver, { id = "reward", username = "pat" })
check(r and r.args.ok == true, "a grant to an online player failed: "
    .. tostring(r and r.args.reason))
check(#pat._contents == 1, "the item never reached the player")
check(DMKits.hasClaimed("pat", "reward") == true, "the grant was not recorded")

-- THE RECORD IS ABOUT THE RECIPIENT, NOT THE ADMIN. This handler holds two
-- people at once - `target` gets the kit, `tell` gets the confirmation - and
-- filing on the wrong one writes half of every grant into the wrong player's
-- permanent record and folder. It is silent: both writes succeed.
local granted = nil
for _, c in ipairs(chronicles) do
    if c.evt == "DM.KIT_GRANTED" then granted = c end
end
check(granted ~= nil, "a staff grant left no permanent record")
check(RDShared.username(granted.subj) == "pat",
    "the grant was chronicled about '"
    .. tostring(RDShared.username(granted.subj)) .. "', not the recipient")
check(granted.subj == pat,
    "the chronicle got a username string where the player object was in hand; "
    .. "only an object carries the life id and a SteamID-bearing directory")
check(granted.payload.by ~= nil, "the responsible admin is not in the record")

local filed = false
for _, w in ipairs(audited) do
    if w.path:find("Kits/pat/", 1, true) then filed = true end
end
check(filed, "nothing was filed in the recipient's own Kits folder")
for _, w in ipairs(audited) do
    check(not w.path:find("Kits/giver/", 1, true),
        "a grant put a record in the ADMIN's folder: " .. w.path)
end

-- A self-claim is the same action with nobody behind it, and must not be
-- recorded as a grant.
check(DMAudit.chronicleEvent("KIT_CLAIMED", {}) == "DM.KIT_CLAIMED",
    "a self-claim would be recorded as a staff grant")

-- once is honoured even for a staff grant: re-granting a one-time reward is
-- almost always a mis-click, and Re-open exists for when it is not.
r = run("kitGrantTo", giver, { id = "reward", username = "pat" })
check(r and r.args.ok == false, "a one-time kit was granted twice")
check(r.args.reason:lower():find("re-open", 1, true),
    "the refusal did not point at the deliberate way to do it: "
    .. tostring(r.args.reason))

-- Offline is refused whole, because the engine has no server-side path that
-- gives XP to a player with no connection and an absent one has no inventory.
onlineRoster = {}
r = run("kitGrantTo", giver, { id = "reward", username = "ghost" })
check(r and r.args.ok == false, "a kit was granted to somebody not online")
check(r.args.reason:lower():find("online", 1, true),
    "the refusal did not say why: " .. tostring(r.args.reason))
-- DMGrant refuses a nil target as well, and its wording also says "online", so
-- that assertion alone cannot tell the two apart. This check is what the
-- door-level guard actually buys: an admin is told WHICH player, not merely
-- that somebody was not online.
check(r.args.reason:find("ghost", 1, true) ~= nil,
    "the refusal did not name the player: " .. tostring(r.args.reason))

-- A username off the wire becomes a table key in a persisted store. The long
-- name is put ONLINE first, because an offline one is refused by the liveness
-- check and the bound is never reached - which is a test that passes without
-- testing anything.
local longName = string.rep("x", 500)
onlineRoster = { character(longName) }
r = run("kitGrantTo", giver, { id = "reward", username = longName })
check(r and r.args.ok == false, "an unbounded username was accepted")
check(r.args.reason:find("64", 1, true) ~= nil,
    "the refusal was not the length bound: " .. tostring(r.args.reason))
onlineRoster = {}
check(run("kitGrantTo", giver, { id = "reward" }).args.ok == false,
    "kitGrantTo accepted no username")
check(run("kitGrantTo", giver, { username = "pat" }).args.ok == false,
    "kitGrantTo accepted no kit id")

-- ---- what a player may learn ---------------------------------------------

reset()
defineKit({ id = "open", requires = nil })
defineKit({ id = "locked", requires = { flags = { "Delver" } } })
local jo = player("jo", {})
onlineRoster = { jo }

r = run("kitMine", jo, {})
check(r and r.command == "KitMine", "kitMine did not answer")
check(#r.args.kits == 1, "kitMine listed " .. #r.args.kits .. " kits, expected 1")
check(r.args.kits[1].id == "open", "kitMine listed the kit they cannot claim")
-- No requirement list. Sending one is a readout of every gate on every kit a
-- player has not earned.
check(r.args.kits[1].requires == nil,
    "kitMine sent the requirement list to the player")
check(r.args.kits[1].kind == "item", "kitMine dropped the kind the reveal needs")

RDVars.grant(jo, "Delver")
r = run("kitMine", jo, {})
check(#r.args.kits == 2, "earning the flag did not open the second kit")

-- ---- the claim -----------------------------------------------------------

reset()
defineKit()
local sam = player("sam", {})
onlineRoster = { sam }

-- THE INVARIANT. A forged grant list in the payload is not partially honoured,
-- it is never read - the handler takes the id and re-derives everything.
r = run("kitClaim", sam, { id = "reward", grants = {
    { kind = "item", type = "Base.Crowbar", count = 99 } },
    kit = { grants = { { kind = "item", type = "Base.Crowbar", count = 99 } } } })
check(r and r.args.ok == true, "a legitimate claim failed: " .. tostring(r and r.args.reason))
check(#sam._contents == 1, "the forged payload changed how much was handed over")
check(sam._contents[1].type == "Base.Axe",
    "the forged payload chose the item: got " .. tostring(sam._contents[1].type))

-- Claimed once, refused twice.
r = run("kitClaim", sam, { id = "reward" })
check(r and r.args.ok == false, "a one-time kit was claimed twice")

-- An unknown kit and an unearned kit answer IDENTICALLY, or the catalogue
-- leaks one guess at a time.
reset()
defineKit({ id = "locked", requires = { flags = { "Delver" } } })
local kim = player("kim", {})
onlineRoster = { kim }
local unearned = run("kitClaim", kim, { id = "locked" })
local unknown  = run("kitClaim", kim, { id = "nosuchkit" })
check(unearned.args.ok == false and unknown.args.ok == false,
    "an unearned or unknown kit was claimable")
check(unearned.args.reason == unknown.args.reason,
    "an unknown kit and an unearned one gave different answers, which tells a "
    .. "player which ids exist: '" .. tostring(unearned.args.reason)
    .. "' vs '" .. tostring(unknown.args.reason) .. "'")
-- The detail an admin needs is not lost, it goes to the forensic stream.
local sawDetail = false
for _, f in ipairs(forensics) do
    if f.evt == "DM.KIT_CLAIM_REFUSED" and f.payload.reason
        and f.payload.reason ~= "no such kit" then sawDetail = true end
end
check(sawDetail, "the detailed refusal reached neither the player nor the log")

check(run("kitClaim", kim, {}).args.ok == false, "kitClaim accepted no id")
check(run("kitClaim", kim, { id = 7 }).args.ok == false,
    "kitClaim accepted a numeric id")

-- ---- order of effects: record, THEN revoke -------------------------------
-- Ticket declares itself spent by "reward". Reversed, the revoke removes the
-- flag the entitlement check just passed on, and a retry is refused for a
-- reason created by the first attempt.

reset()
defineKit({ requires = { flags = { "Ticket" } } })
local eli = player("eli", {})
onlineRoster = { eli }
RDVars.grant(eli, "Ticket")

check(DMKits.entitlement(eli, "reward") == true, "the ticket did not open the kit")
r = run("kitClaim", eli, { id = "reward" })
check(r and r.args.ok == true, "the claim failed: " .. tostring(r and r.args.reason))
check(DMKits.hasClaimed("eli", "reward") == true, "the claim was not recorded")
check(RDVars.has(eli, "Ticket") == false,
    "the flag that declared itself spent by this kit was not revoked")

-- ---- nothing landed, nothing recorded ------------------------------------
-- Recording first would mark a one-time kit spent even when every grant failed.

reset()
defineKit()
local nia = player("nia", {})
onlineRoster = { nia }
liveItems["Base.Axe"] = nil          -- the script went away after authoring
r = run("kitClaim", nia, { id = "reward" })
liveItems["Base.Axe"] = true
check(DMKits.hasClaimed("nia", "reward") == false,
    "a claim where nothing landed was recorded, spending a one-time kit for "
    .. "a reward the player never received")
check(DMKits.entitlement(nia, "reward") == true,
    "the player cannot retry a claim that gave them nothing")

-- ---- a partial claim is a success that says what is missing ---------------

reset()
DMKits.define({ id = "reward", kind = "item", label = "Reward",
    claim = { once = true }, grants = {
        { kind = "item", type = "Base.Axe" },
        { kind = "item", type = "Base.Crowbar" },
    } }, "seed")
local rob = player("rob", {})
onlineRoster = { rob }
liveItems["Base.Crowbar"] = nil
r = run("kitClaim", rob, { id = "reward" })
liveItems["Base.Crowbar"] = true
check(r and r.args.ok == true,
    "a partial claim was reported as a failure, inviting a second handout")
check(r.args.partial == true, "a partial claim was not flagged as partial")
check(r.args.message:lower():find("failed", 1, true),
    "the partial claim hid what did not land: " .. tostring(r.args.message))
check(DMKits.hasClaimed("rob", "reward") == true,
    "a partial claim was not recorded, so it could be taken again")

-- ---- re-opening ----------------------------------------------------------

reset()
defineKit()
DMKits.recordClaim("a", "reward"); DMKits.recordClaim("b", "reward")
r = run("kitForget", author, { id = "reward" })
check(r and r.args.ok == true, "re-opening failed")
check(r.args.cleared == 2, "re-open cleared " .. tostring(r.args.cleared)
    .. ", expected 2 - the count is the only sign anything happened")
check(r.args.message:find("2", 1, true), "the count did not reach the admin")

-- ---- a refused caller hears the same envelope ----------------------------

sent = {}
adoptOpts.onReject(player("zed", {}), "kitDefine", "capability")
check(#sent == 1 and sent[1].args.ok == false,
    "a dispatcher refusal did not reach the caller in the reply shape the "
    .. "panel renders")
check(sent[1].args.command == "kitDefine",
    "a dispatcher refusal did not say which command it answered")

-- ---- EVERY KitResult NAMES ITS COMMAND -----------------------------------
--
-- One client is both the authoring tab and a player with a Kits window, and
-- both are answered on this one envelope. An unnamed reply leaves each of them
-- guessing whether it was theirs - and the failure is not two panels showing
-- "Saved", it is the claim window rendering an admin's delete confirmation as
-- what the player just received.
--
-- Swept rather than asserted per case, because the risk is a NEW handler added
-- later that forgets, and a list of eight named checks does not cover the ninth.

reset()
defineKit()
onlineRoster = { }

local admin  = player("boss", { "SandboxOptions", "AddItem" })
local anyone = player("pat", {})

local probes = {
    { "kitDefine",    admin,  { kit = { id = "extra", kind = "item",
        claim = { once = true },
        grants = { { kind = "item", type = "Base.Axe" } } } } },
    { "kitDefine",    admin,  { kit = { id = "" } } },          -- refusal
    { "kitDelete",    admin,  { id = "extra" } },
    { "kitDelete",    admin,  { id = "nosuchkit" } },           -- refusal
    { "kitForget",    admin,  { id = "nosuchkit" } },           -- refusal
    { "kitGrantTo",   admin,  { id = "reward", username = "gone" } }, -- refusal
    { "kitClaim",     anyone, { id = "nosuchkit" } },           -- refusal
    { "kitClaimants", anyone, {} },                             -- refusal
}
for _, probe in ipairs(probes) do
    local action, who, args = probe[1], probe[2], probe[3]
    local answer = run(action, who, args)
    if answer and answer.command == "KitResult" then
        check(answer.args.command == action,
            "A KitResult DID NOT NAME ITS COMMAND. '" .. action
            .. "' answered with command=" .. tostring(answer.args.command))
    end
end

-- The two delivery paths share ONE function and must still answer under their
-- own names: `by` is the responsible admin on a staff grant and nil on a
-- self-claim, and that is the only thing distinguishing them.
reset()
defineKit()
local claimant = character("pat")
onlineRoster = { claimant }
local granted = run("kitGrantTo", admin, { id = "reward", username = "pat" })
check(granted and granted.args.ok == true, "the staff grant did not land")
check(granted.args.command == "kitGrantTo",
    "a staff grant answered as something else: " .. tostring(granted.args.command))

reset()
defineKit()
local selfClaim = run("kitClaim", claimant, { id = "reward" })
check(selfClaim and selfClaim.args.ok == true, "the self-claim did not land")
check(selfClaim.args.command == "kitClaim",
    "A SELF-CLAIM ANSWERED AS A STAFF GRANT. They share one delivery path, so "
    .. "the player's Kits window would render an admin reply: "
    .. tostring(selfClaim.args.command))

print = realPrint
print(string.format("DMKits_Server: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
