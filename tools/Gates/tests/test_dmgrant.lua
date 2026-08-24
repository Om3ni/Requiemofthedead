-- DMGrant fixture - a kit stops being data here.
--
-- WHAT IS ACTUALLY AT RISK. Every engine surface in this file answers failure
-- QUIETLY: AddItem returns nil for a dead item script, an XP write that is
-- never replicated leaves the client showing the old number, and a trait added
-- to a character who already holds it is a no-op that reads like an error. So
-- the failures worth catching are all of the same shape - a reward that appears
-- to have been handed over and was not. Almost every assertion here is about
-- the report telling the truth.
--
-- THE FAKE CHARACTER IMPLEMENTS THE VERIFIED SURFACE AND NOTHING ELSE.
-- AddItem returns nil for an unknown type because ItemContainer.java:511-520
-- says it does; getCharacterTraits() exposes get/add because
-- CharacterTraits.java:67-88 does; nothing here throws, because none of these
-- methods can throw into Lua (MethodCaller.java:33-56). Per CLAUDE.md sect. 2:
-- a fake must not be made to throw in order to justify a guard the engine
-- cannot.

local ROOT = arg[1] or "."
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"
local DM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDungeonMaster/42/media/lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL DMGrant: " .. message) end
end

-- ---- engine stubs ---------------------------------------------------------

function isServer() return true end
print = function() end
function instanceof(o, cls) return type(o) == "table" and o.__class == cls end

local fs = {}
function getFileReader(path)
    local c = fs[path]
    if c == nil then return nil end
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
Events = { EveryTenMinutes = { Add = function() end },
           OnCharacterDeath = { Add = function() end },
           OnServerStarted = { Add = function() end } }

local clock = 1000000

-- Registries, as DMRegistry crosses them.
local function javaList(items)
    return setmetatable({}, { __index = function(_, k)
        if k == "size" then return function() return #items end end
        if k == "get"  then return function(_, i) return items[i + 1] end end
    end })
end
local traitObjects = {}
local function traitDef(id, label)
    local trait = setmetatable({}, { __tostring = function() return id end })
    traitObjects[id] = trait
    return { getType = function() return trait end,
             getLabel = function() return label end }
end
CharacterTraitDefinition = { getTraits = function()
    return javaList({ traitDef("base:Brave", "Brave"),
                      traitDef("RFTDDungeonMaster:Delver", "Delver") })
end }

local PERK_FITNESS  = { name = "Fitness" }
local PERK_WOODWORK = { name = "Woodwork" }
local MAX_SENTINEL  = { name = "MAX" }
Perks = { MAX = MAX_SENTINEL, Fitness = PERK_FITNESS, Strength = { name = "Strength" },
          FromString = function(s)
              if s == "Woodwork" then return PERK_WOODWORK end
              if s == "Fitness"  then return PERK_FITNESS  end
              return MAX_SENTINEL
          end }
CharacterStat = { FITNESS = "FITNESS", STRENGTH = "STRENGTH" }

local liveItems = { ["Base.Axe"] = true, ["Base.Crowbar"] = true,
                    ["Base.Katana"] = true, ["Base.Flaky"] = true }
function getScriptManager() return { getItem = function(_, ft)
    return liveItems[ft] and {} or nil end } end

-- Rolls are scripted; ZombRand exists only so the production default has
-- something to call if a test forgets to inject.
function ZombRand(n) return 0 end

local replicated
function sendAddItemToContainer(container, item)
    replicated[#replicated + 1] = { container = container, item = item }
end

-- A character implementing exactly the surface DMGrant was written against.
local function character(name)
    local held, contents = {}, {}
    local xpLog, statLog, syncs = {}, {}, { n = 0 }
    -- Items whose script has gone since the kit was saved: AddItem answers nil,
    -- exactly as ItemContainer does, rather than throwing.
    local inv = {
        AddItem = function(_, ft)
            if not liveItems[ft] then return nil end
            if ft == "Base.Flaky" and #contents >= 1 then return nil end
            local item = { type = ft }
            contents[#contents + 1] = item
            return item
        end,
        contents = contents,
    }
    return {
        __class = "IsoPlayer",
        getUsername  = function() return name end,
        getInventory = function() return inv end,
        getCharacterTraits = function()
            return { get = function(_, t) return held[t] == true end,
                     add = function(_, t) held[t] = true end }
        end,
        getXp = function()
            return { AddXP = function(_, perk, amount, a, b, c, d)
                xpLog[#xpLog + 1] = { perk = perk, amount = amount,
                                      args = { a, b, c, d } }
            end }
        end,
        getPerkLevel = function() return 5 end,
        getStats = function()
            return { set = function(_, stat, value)
                statLog[#statLog + 1] = { stat = stat, value = value } end }
        end,
        getNetworkCharacterAI = function()
            return { updateXpChecker = function() syncs.n = syncs.n + 1 end }
        end,
        _held = held, _contents = contents, _xp = xpLog,
        _stats = statLog, _syncs = syncs,
    }
end

require = function() return true end
dofile(CORE .. "/shared/RDShared.lua")
RDShared.nowMs = function() return clock end
dofile(CORE .. "/shared/RDJson.lua")
dofile(CORE .. "/shared/RDVarDefs.lua")
dofile(DM .. "/shared/DMRoll.lua")
dofile(DM .. "/shared/DMKitDefs.lua")
dofile(DM .. "/shared/DMRegistry.lua")
dofile(CORE .. "/server/RDConfigStore.lua")
dofile(CORE .. "/server/RDVars.lua")

DMGrant = nil
local ok, err = pcall(dofile, DM .. "/server/DMGrant.lua")
check(ok, "module loads: " .. tostring(err))

local function reset()
    fs, modDataMap, replicated = {}, {}, {}
    DMRegistry.forget()
    dofile(CORE .. "/server/RDConfigStore.lua")
    dofile(CORE .. "/server/RDVars.lua")
    dofile(DM .. "/server/DMGrant.lua")
    RDVars.define{ kind = "flag", name = "Delver" }
    RDVars.define{ kind = "counter", name = "Samples", resetOnDeath = false }
end

-- Grants must be VALIDATED before they reach DMGrant - that is the contract, so
-- the fixture goes through DMKitDefs rather than hand-building normalized
-- tables that could drift from what the validator actually emits.
--
-- One kit carries one reward type, so the kit kind is derived from the first
-- reward grant in the list (roulette branches included). Flags and counters
-- are bookkeeping and settle nothing, which is why a var-only list has to say
-- which kind of kit it is riding in.
local REWARD_KINDS = { item = true, trait = true, xp = true }
local function deriveKind(list)
    for _, g in ipairs(list) do
        if REWARD_KINDS[g.kind] then return g.kind end
        if g.kind == "roulette" then
            for _, b in ipairs(g.from or {}) do
                for _, ig in ipairs(b.grants or {}) do
                    if REWARD_KINDS[ig.kind] then return ig.kind end
                end
            end
        end
    end
    return "item"
end
local function grantsFor(list, kitKind)
    local def, why = DMKitDefs.validate{
        id = "k", kind = kitKind or deriveKind(list),
        claim = { once = true }, grants = list }
    if not def then error("fixture built an invalid kit: " .. tostring(why), 2) end
    return def.grants
end

-- A real reward to ride alongside a var grant, since a kit that grants nothing
-- of its own kind is not a kit.
local AXE = { kind = "item", type = "Base.Axe" }

-- ---- items ----------------------------------------------------------------

reset()
local pc = character("alice")
local report = DMGrant.apply(pc, grantsFor({
    { kind = "item", type = "Base.Axe", count = 3 } }))
check(report ~= nil, "a valid item grant was refused")
check(#pc._contents == 3, "added " .. #pc._contents .. " items, expected 3")
check(#report.landed == 1 and #report.failed == 0, "an item grant did not land")

-- Every item needs its own replication packet or the owning client never sees
-- it - the reward is in the server's copy of the inventory and nowhere else.
check(#replicated == 3,
    "replicated " .. #replicated .. " items, expected one packet per item")
check(replicated[1].item ~= nil and replicated[1].container ~= nil,
    "the replication call was missing its container or item")

-- An item script that has gone since the kit was saved. AddItem answers nil,
-- which is the whole contract - there is nothing to catch, only something to
-- report.
reset()
pc = character("alice")
liveItems["Base.Katana"] = nil
report = DMGrant.apply(pc, grantsFor({ { kind = "item", type = "Base.Katana" } }))
check(#report.failed == 1, "a dead item script did not report a failure")
check(#report.landed == 0, "a dead item script reported something landed")
check(report.failed[1]:find("Base.Katana", 1, true), "the failure did not name the item")
liveItems["Base.Katana"] = true

-- A PARTIAL add is a success that says how short it fell: the player really is
-- holding the ones that worked, and calling it a failure would have the caller
-- refuse to record a claim they have already been paid for.
reset()
pc = character("alice")
report = DMGrant.apply(pc, grantsFor({
    { kind = "item", type = "Base.Flaky", count = 4 } }))
check(#pc._contents == 1, "the flaky item added more than once")
check(#report.landed == 1 and #report.failed == 0,
    "a partial add was reported as a failure rather than a short success")
check(report.landed[1]:find("of 4", 1, true),
    "a partial add did not say how short it fell: " .. tostring(report.landed[1]))

-- ---- flags and counters, through RDVars ---------------------------------

reset()
pc = character("bob")
report = DMGrant.apply(pc, grantsFor({
    AXE,
    { kind = "flag", name = "Delver" },
    { kind = "counter", name = "Samples", add = 5 },
}), "adminA")
check(RDVars.has(pc, "Delver") == true, "the flag was not granted")
check(RDVars.get(pc, "Samples") == 5, "the counter did not move")
check(#report.failed == 0, "a valid var grant reported a failure")

-- add is relative, set is absolute, and the report says which happened.
report = DMGrant.apply(pc, grantsFor({
    AXE, { kind = "counter", name = "Samples", add = 5 } }))
check(RDVars.get(pc, "Samples") == 10, "add did not accumulate")
report = DMGrant.apply(pc, grantsFor({
    AXE, { kind = "counter", name = "Samples", set = 2 } }))
check(RDVars.get(pc, "Samples") == 2, "set did not overwrite")

-- A WORLD COUNTER, THROUGH A KIT THAT DOES NOT KNOW IT IS ONE. This is the
-- whole justification for RDVars routing by definition rather than exposing a
-- second set of verbs: the grant below is byte-identical to a per-player one,
-- and a DM flipping the counter's scope must not require every kit that writes
-- to it to be re-authored.
RDVars.define{ kind = "counter", name = "Runs", scope = "world" }
local wr = DMGrant.apply(pc, { { kind = "counter", name = "Runs", add = 1 } }, "Omen")
check(wr and wr.landed and #wr.landed == 1,
    "a kit could not write to a world counter")
check(RDVars.get(nil, "Runs") == 1,
    "A KIT'S COUNTER GRANT DID NOT REACH THE WORLD SLOT: "
    .. tostring(RDVars.get(nil, "Runs")))
check(#RDVars.valuesOf("Runs") == 0,
    "the grant left a per-player holding behind, so the claiming player would "
    .. "appear as a holder of a counter that has none")
DMGrant.apply(pc, { { kind = "counter", name = "Runs", add = 1 } }, "Omen")
check(RDVars.get(nil, "Runs") == 2,
    "two claims by the SAME player did not accumulate on one world number")

-- RDVars' own refusal has to reach the report rather than being swallowed.
reset()
pc = character("bob")
report = DMGrant.apply(pc, grantsFor({ AXE, { kind = "flag", name = "Undefined" } }))
check(#report.failed == 1, "granting an undefined flag did not report a failure")
check(#report.landed == 1, "the item beside the failing flag did not land")
check(report.failed[1]:find("undefined", 1, true),
    "the failure did not name the flag: " .. tostring(report.failed[1]))

-- ---- traits ---------------------------------------------------------------

reset()
pc = character("carol")
report = DMGrant.apply(pc, grantsFor({ { kind = "trait", id = "base:Brave" } }))
check(#report.landed == 1 and #report.failed == 0, "a valid trait did not land")
check(pc._held[traitObjects["base:Brave"]] == true, "the trait was not added")

-- Already holding it is a no-op, and a SUCCESS. A repeatable kit granting the
-- same trait twice is not a fault, and reporting one sends an admin hunting.
report = DMGrant.apply(pc, grantsFor({ { kind = "trait", id = "base:Brave" } }))
check(#report.failed == 0, "re-granting a held trait was reported as a failure")
check(report.landed[1]:find("already", 1, true),
    "re-granting a held trait did not say so: " .. tostring(report.landed[1]))

-- A trait whose registry entry is gone since the kit was saved.
reset()
pc = character("carol")
report = DMGrant.apply(pc, grantsFor({ { kind = "trait", id = "Gone:Trait" } }))
check(#report.failed == 1, "an unregistered trait did not report a failure")

-- ---- skill xp -------------------------------------------------------------

reset()
pc = character("dave")
report = DMGrant.apply(pc, grantsFor({
    { kind = "xp", perk = "Woodwork", amount = 200 } }))
check(#report.landed == 1 and #report.failed == 0, "an xp grant did not land")
check(#pc._xp == 1, "AddXP was not called")
check(pc._xp[1].perk == PERK_WOODWORK, "AddXP got the wrong perk")
check(pc._xp[1].amount == 200, "AddXP got the wrong amount")
-- The six-argument overload is (perk, amount, callLua, doXPBoost, remote,
-- haloText) - IsoGameCharacter.java:15482 - so the flags are asserted by name
-- and by position. doXPBoost is the one that matters: true applies the
-- character's own trait XP boosts, so an authored 200 would become 200 x
-- whatever that player carries and two people claiming one kit would get
-- different amounts. Asserting only the first flag missed exactly this.
local flags = pc._xp[1].args
check(flags[1] == false, "AddXP fired the Lua XP hooks (callLua)")
check(flags[2] == false, "AddXP applied the character's XP boost (doXPBoost) - "
    .. "an authored amount would no longer be the amount granted")
check(flags[3] == false, "AddXP was called as a remote write")
check(flags[4] == false, "AddXP raised halo text for a granted reward")

-- Without the checker the client's copy is stale and the kit reads as having
-- given nothing at all.
check(pc._syncs.n == 1, "the XP change was never replicated")

-- Fitness and Strength keep a separate stat that must be pushed too, or the
-- character sheet and the perk level disagree.
reset()
pc = character("dave")
DMGrant.apply(pc, grantsFor({ { kind = "xp", perk = "Fitness", amount = 100 } }))
check(#pc._stats == 1, "a Fitness grant did not push the mirrored stat")
check(pc._stats[1].stat == "FITNESS", "the wrong stat was pushed")

reset()
pc = character("dave")
DMGrant.apply(pc, grantsFor({ { kind = "xp", perk = "Woodwork", amount = 100 } }))
check(#pc._stats == 0, "a non-Fitness perk pushed a mirrored stat")

reset()
pc = character("dave")
report = DMGrant.apply(pc, grantsFor({ { kind = "xp", perk = "Woodwork", amount = -50 } }))
check(pc._xp[1].amount == -50, "a negative xp grant was not passed through")

-- ---- roulette -------------------------------------------------------------
-- The draw happens HERE, on the server, and the drawn indices come back so the
-- caller can record them. A client that decides where the wheel stops decided
-- its own reward.

local ROULETTE = { kind = "roulette", pick = 1, from = {
    { weight = 10, grants = { { kind = "item", type = "Base.Katana" } } },
    { weight = 90, grants = { { kind = "item", type = "Base.Crowbar" } } },
} }

reset()
pc = character("erin")
DMGrant.rand = function(_) return 0 end          -- lands in the weight-10 band
report = DMGrant.apply(pc, grantsFor({ ROULETTE }))
check(#pc._contents == 1, "a pick-1 roulette handed over " .. #pc._contents .. " items")
check(pc._contents[1].type == "Base.Katana", "the drawn branch was not the one applied")
check(report.rolls[1] ~= nil and report.rolls[1][1] == 1,
    "the drawn branch index was not reported for recording")

reset()
pc = character("erin")
DMGrant.rand = function(_) return 50 end         -- lands in the weight-90 band
report = DMGrant.apply(pc, grantsFor({ ROULETTE }))
check(pc._contents[1].type == "Base.Crowbar", "the second branch was not applied")
check(report.rolls[1][1] == 2, "the second branch index was not reported")

-- Only the drawn branch is applied. A roulette that hands over every branch is
-- not a roulette, and it is the failure a fixture with one branch cannot see.
check(#pc._contents == 1, "a pick-1 roulette applied more than one branch")

-- Drawing two of three gives two, and both indices come back.
reset()
pc = character("erin")
local calls = 0
DMGrant.rand = function(_) calls = calls + 1; return 0 end
report = DMGrant.apply(pc, grantsFor({ { kind = "roulette", pick = 2, from = {
    { weight = 1, grants = { { kind = "item", type = "Base.Axe" } } },
    { weight = 1, grants = { { kind = "item", type = "Base.Crowbar" } } },
    { weight = 1, grants = { { kind = "item", type = "Base.Katana" } } },
} } }))
check(#report.rolls[1] == 2, "a pick-2 roulette reported "
    .. #report.rolls[1] .. " draws")
check(report.rolls[1][1] ~= report.rolls[1][2], "a pick-2 roulette drew the same branch twice")
check(#pc._contents == 2, "a pick-2 roulette handed over " .. #pc._contents .. " items")

DMGrant.rand = function(n) return ZombRand(n) end

-- ---- the player must be online --------------------------------------------
-- The engine has no server-side path that gives XP to a player with no
-- connection (AddXPCommand.java:65), and an absent one has no inventory. The
-- whole grant is refused rather than half-applied and silently short.

reset()
check(DMGrant.apply(nil, grantsFor({ { kind = "item", type = "Base.Axe" } })) == nil,
    "a kit was handed to a nil player")
check(DMGrant.apply("alice", grantsFor({ { kind = "item", type = "Base.Axe" } })) == nil,
    "a kit was handed to a username rather than a player")
check(DMGrant.apply({}, grantsFor({ { kind = "item", type = "Base.Axe" } })) == nil,
    "a kit was handed to something with no inventory")
local _, offlineWhy = DMGrant.apply(nil, {})
check(type(offlineWhy) == "string" and offlineWhy:find("online", 1, true),
    "the offline refusal did not say why: " .. tostring(offlineWhy))
check(DMGrant.apply(character("x"), "nope") == nil, "grants that are not a list were applied")

-- ---- the report is the whole point ----------------------------------------

reset()
pc = character("frank")
report = DMGrant.apply(pc, grantsFor({
    { kind = "item", type = "Base.Axe" },
    { kind = "flag", name = "Undefined" },
    { kind = "item", type = "Base.Crowbar" },
}))
check(#report.landed == 2, "a failing grant stopped the ones after it")
check(#report.failed == 1, "the failing grant was not reported")
check(DMGrant.anyLanded(report) == true, "anyLanded missed a partial success")

local text = DMGrant.summary(report)
check(text:find("failed", 1, true), "the summary hid the failure: " .. text)
check(text:find("Base.Axe", 1, true), "the summary hid what landed: " .. text)

reset()
pc = character("frank")
liveItems["Base.Katana"] = nil
report = DMGrant.apply(pc, grantsFor({ { kind = "item", type = "Base.Katana" } }))
liveItems["Base.Katana"] = true
check(DMGrant.anyLanded(report) == false,
    "anyLanded said something landed when nothing did")
check(DMGrant.anyLanded(nil) == false, "anyLanded answered for nil")
check(DMGrant.summary(nil) == "nothing", "summary threw on nil")

print = realPrint
print(string.format("DMGrant: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
