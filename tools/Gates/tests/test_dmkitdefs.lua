-- DMKitDefs fixture - the kit schema, attacked from the admin's side.
--
-- WHY THE ASSERTIONS LEAN NEGATIVE, same reason RDVarDefs' fixture does: every
-- rule here exists to REFUSE something, and a validator that has quietly
-- stopped refusing is indistinguishable from one that works. The kit it lets
-- through is not discovered until a player claims it - and for a reward, "not
-- discovered" means someone finished a quest chain for an empty box.
--
-- The other half is that a refusal must be READABLE. A DM staring at a
-- twenty-row grant list needs the position and the value, so several checks
-- here assert the text of the reason and not merely that there was one.

local ROOT = arg[1] or "."
local MOD = ROOT .. "/RequiemOfTheDead/Contents/mods"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DMKitDefs: " .. message) end
end

require = function() return true end

RDVarDefs, DMRoll, DMKitDefs = nil, nil, nil
local ok, err = pcall(dofile,
    MOD .. "/RFTDCore/42/media/lua/shared/RDVarDefs.lua")
check(ok, "RDVarDefs loads: " .. tostring(err))
ok, err = pcall(dofile,
    MOD .. "/RFTDDungeonMaster/42/media/lua/shared/DMRoll.lua")
check(ok, "DMRoll loads: " .. tostring(err))
ok, err = pcall(dofile,
    MOD .. "/RFTDDungeonMaster/42/media/lua/shared/DMKitDefs.lua")
check(ok, "DMKitDefs loads: " .. tostring(err))

local K = DMKitDefs

-- A minimal valid kit, so every case below differs from it in exactly one way.
local function kit(over)
    local d = {
        id    = "delvers_reward",
        kind  = "item",
        label = "Delver's Reward",
        claim = { cooldownHours = 0 },
        grants = { { kind = "item", type = "Base.Axe" } },
    }
    for k, v in pairs(over or {}) do
        if v == "\0nil" then d[k] = nil else d[k] = v end
    end
    return d
end

local function accepts(def, why)
    local out, reason = K.validate(def)
    check(out ~= nil, (why or "kit") .. " was refused: " .. tostring(reason))
    return out
end
local function refuses(def, why)
    local out, reason = K.validate(def)
    check(out == nil, "ACCEPTED " .. (why or "an invalid kit"))
    check(out ~= nil or (type(reason) == "string" and reason ~= ""),
        "refused " .. (why or "") .. " with no reason given")
    return reason
end
-- A kit differing from the baseline only in its grant list. One kit carries one
-- reward type, so a grant under test needs a kit of its OWN kind around it -
-- derived here rather than spelled at every call, since the alternative is
-- every trait case below silently testing "a trait in an item kit" instead of
-- the rule it means to.
local REWARD_KINDS = { item = true, trait = true, xp = true }
local function withGrants(grants, kitKind)
    return kit({ kind = kitKind or "item", grants = grants })
end
local function kindFor(g)
    return (type(g) == "table" and REWARD_KINDS[g.kind] and g.kind) or "item"
end
-- A kit must grant the thing it is named for, so a flag or counter under test
-- rides beside a real reward. Without this every var case below would be
-- refused for the wrong reason and prove nothing about the var rules.
local REWARD_FOR = {
    item  = { kind = "item",  type = "Base.Axe" },
    trait = { kind = "trait", id = "base:Brave" },
    xp    = { kind = "xp",    perk = "Woodwork", amount = 5 },
}
local function listFor(g, kitKind)
    if type(g) ~= "table" then return { g } end
    -- A roulette needs no companion: its branches carry the reward, and the
    -- kind check descends into them. Prepending one would also push the
    -- roulette to grants[2] and quietly break every assertion that indexes it.
    if REWARD_KINDS[g.kind] or g.kind == K.ROULETTE then return { g } end
    return { REWARD_FOR[kitKind], g }
end
local function grantOk(g, why, kitKind)
    kitKind = kitKind or kindFor(g)
    return accepts(withGrants(listFor(g, kitKind), kitKind), why)
end
local function grantBad(g, why, kitKind)
    kitKind = kitKind or kindFor(g)
    return refuses(withGrants(listFor(g, kitKind), kitKind), why)
end

-- ---- the baseline ---------------------------------------------------------

local base = accepts(kit(), "the minimal kit")
check(base and base.id == "delvers_reward", "the id was not normalized")
check(base and base.grants[1].count == 1,
    "an item grant with no count did not default to 1")

-- ---- ids ------------------------------------------------------------------
-- The id is the stable key a quest reward, a var's revokers.kit and the claim
-- ledger all point at, so its character set is the intersection of what
-- survives a JSON key, a command argument and a file name.

check(K.normalizeId("Delvers_Reward") == "delvers_reward",
    "ids are not matched case-insensitively")
check(K.normalizeId("  spaced  ") == "spaced", "ids are not trimmed")
check(K.normalizeId("a-b_c9") == "a-b_c9", "the legal character set shrank")

check(K.normalizeId("") == nil, "accepted an empty id")
check(K.normalizeId("   ") == nil, "accepted a whitespace-only id")
check(K.normalizeId(nil) == nil, "accepted a nil id")
check(K.normalizeId(7) == nil, "accepted a numeric id")
check(K.normalizeId("9lives") == nil, "accepted an id starting with a digit")
check(K.normalizeId("-flag") == nil, "accepted an id starting with a hyphen")
check(K.normalizeId("has space") == nil, "accepted an id with a space")
check(K.normalizeId("has:colon") == nil, "accepted an id with a colon")
check(K.normalizeId(string.rep("a", K.ID_MAX)) ~= nil,
    "refused an id exactly at the ceiling")
check(K.normalizeId(string.rep("a", K.ID_MAX + 1)) == nil,
    "accepted an id one character over the ceiling")

refuses(kit({ id = "\0nil" }), "a kit with no id")

-- ---- labels ---------------------------------------------------------------

local defaulted = accepts(kit({ label = "\0nil" }), "a kit with no label")
check(defaulted and defaulted.label == "delvers_reward",
    "a missing label did not fall back to the id")
refuses(kit({ label = "" }), "an empty label")
refuses(kit({ label = string.rep("x", K.LABEL_MAX + 1) }), "an over-long label")
accepts(kit({ label = string.rep("x", K.LABEL_MAX) }), "a label at the ceiling")

-- ---- the shape at the top -------------------------------------------------

refuses(nil, "a nil definition")
refuses("kit", "a string definition")
refuses(kit({ colour = "red" }), "an unknown top-level field")
refuses(kit({ note = 7 }), "a non-string note")
accepts(kit({ note = "for the crypt event" }), "an admin note")

-- ---- the claim policy -----------------------------------------------------
-- No default, for the reason RDVarDefs gives for resetOnDeath: here the
-- unchosen answer is a kit that can be farmed.

refuses(kit({ claim = "\0nil" }), "a kit with no claim policy")
refuses(kit({ claim = {} }), "a claim policy that never chose a wait")
refuses(kit({ claim = { cooldownHours = nil } }), "an explicitly nil wait")
refuses(kit({ claim = { cooldownHours = "24" } }), "a wait as a string")
refuses(kit({ claim = { cooldownHours = 1.5 } }), "a fractional hour")
refuses(kit({ claim = { cooldownHours = -1 } }), "a negative wait")
refuses(kit({ claim = { cooldownHours = 24, twice = true } }),
        "an unknown claim field")
refuses(kit({ claim = { cooldownHours = DMKitDefs.COOLDOWN_MAX_HOURS + 1 } }),
        "a wait past the cap")
accepts(kit({ claim = { cooldownHours = 0 } }), "a kit with no wait")
accepts(kit({ claim = { cooldownHours = 24 } }), "a daily kit")

-- A MALFORMED `once` IS NOT AN OLD KIT. The migration recognises the boolean
-- and nothing else, so garbage falls through to the field check rather than
-- being quietly rewritten as "no wait" - the farmable default the no-default
-- rule exists to prevent, arrived at by migration instead of by omission.
refuses(kit({ claim = { once = "true" } }), "once as a string")
refuses(kit({ claim = { once = 1 } }), "once as a number")

-- ---- a kit must actually give something ------------------------------------

-- An empty grant list and a kit that grants none of its own kind are both
-- refusals now, and they must not swap messages: "a kit must grant something"
-- is the truth about an empty list, whereas the own-kind refusal talks about
-- flags and counters being bookkeeping - which is nonsense when there are no
-- grants at all, and would send a DM looking for a var they never wrote.
local emptyReason = refuses(kit({ grants = {} }), "a kit granting nothing")
check(type(emptyReason) == "string"
    and emptyReason:find("must grant something", 1, true) ~= nil,
    "an empty kit was refused with the wrong-kind message: "
    .. tostring(emptyReason))
refuses(kit({ grants = "\0nil" }), "a kit with no grants field")
refuses(kit({ grants = "Base.Axe" }), "a grants field that is not a list")
refuses(withGrants({ "Base.Axe" }), "a grant that is not a table")
refuses(withGrants({ { kind = "money", amount = 5 } }), "an unknown grant kind")

-- The unknown-kind refusal must list the kinds, or the DM is guessing.
local kindReason = refuses(withGrants({ { kind = "money" } }), "kind 'money'")
check(type(kindReason) == "string" and kindReason:find("roulette", 1, true),
    "the unknown-kind refusal did not name the valid set: "
    .. tostring(kindReason))

local tooMany = {}
for i = 1, K.GRANTS_MAX + 1 do tooMany[i] = { kind = "item", type = "Base.Axe" } end
refuses(withGrants(tooMany), "more grants than the ceiling allows")

-- ---- item grants ----------------------------------------------------------

grantOk({ kind = "item", type = "Base.Axe", count = 3 }, "an item grant")
grantBad({ kind = "item" }, "an item grant with no type")
grantBad({ kind = "item", type = "" }, "an empty item type")
grantBad({ kind = "item", type = 7 }, "a numeric item type")
-- The module prefix is what AddItem actually resolves against; a bare name
-- returns nil at claim time and the reward silently comes up empty.
grantBad({ kind = "item", type = "Axe" }, "an item type with no module")
grantBad({ kind = "item", type = "Base.Axe", count = 0 }, "a zero item count")
grantBad({ kind = "item", type = "Base.Axe", count = -1 }, "a negative item count")
grantBad({ kind = "item", type = "Base.Axe", count = 2.5 }, "a fractional item count")
grantBad({ kind = "item", type = "Base.Axe", count = 0/0 }, "a NaN item count")
grantBad({ kind = "item", type = "Base.Axe", count = 1/0 }, "an infinite item count")
grantBad({ kind = "item", type = "Base.Axe", weight = 3 }, "an unknown item field")

-- ---- flag grants --------------------------------------------------------
-- Normalized through the var system's own function, so a kit and a var
-- definition can never disagree about what "Anomaly" means.

-- Looked up by kind rather than by position: a var grant now rides beside a
-- real reward, so its index in the list is not something to assume.
local flag = grantOk({ kind = "flag", name = "CryptDelver" }, "a flag grant")
local flagGrant = flag and K.grantsOfKind(flag.grants, "flag")[1]
check(flagGrant and flagGrant.name == "cryptdelver",
    "a flag grant did not normalize its name")
grantBad({ kind = "flag" }, "a flag grant with no name")
grantBad({ kind = "flag", name = "9lives" }, "a flag name starting with a digit")
grantBad({ kind = "flag", name = "X", count = 1 }, "an unknown flag field")

-- ---- counter grants -------------------------------------------------------

grantOk({ kind = "counter", name = "Samples", add = 5 }, "a counter add")
grantOk({ kind = "counter", name = "Stage", set = 3 }, "a counter set")
grantOk({ kind = "counter", name = "Samples", add = -2 }, "a counter that subtracts")
grantOk({ kind = "counter", name = "Stage", set = 0 }, "setting a counter to zero")
grantBad({ kind = "counter", name = "S" }, "a counter grant with neither add nor set")
grantBad({ kind = "counter", name = "S", add = 1, set = 1 }, "both add and set")
grantBad({ kind = "counter", name = "S", add = 0 }, "adding zero")
grantBad({ kind = "counter", name = "S", add = 0/0 }, "adding NaN")
grantBad({ kind = "counter", name = "S", set = 1/0 }, "setting infinity")
grantBad({ kind = "counter", name = "S", add = "5" }, "adding a string")

-- ---- trait grants ---------------------------------------------------------
-- The SHAPE is not checked beyond a non-empty string: this module cannot see
-- the trait registry, and a guess at how vanilla ids render would either reject
-- every base trait or wave a typo through. The server resolves it at save time.

grantOk({ kind = "trait", id = "RFTDDungeonMaster:Delver" }, "a namespaced trait")
grantOk({ kind = "trait", id = "base:Brave" }, "a base-namespace trait")
grantBad({ kind = "trait" }, "a trait grant with no id")
grantBad({ kind = "trait", id = "" }, "an empty trait id")
grantBad({ kind = "trait", id = 7 }, "a numeric trait id")
grantBad({ kind = "trait", id = string.rep("x", K.ID_MAX * 2 + 1) },
    "a trait id far too long to be a registry id")
grantBad({ kind = "trait", id = "base:Brave", name = "Brave" },
    "an unknown trait field")

-- ---- xp grants ------------------------------------------------------------

grantOk({ kind = "xp", perk = "Woodwork", amount = 200 }, "an xp grant")
-- Negative is legal: it is how vanilla's own admin screen lowers a perk, and a
-- cursed kit is a design rather than a typo.
grantOk({ kind = "xp", perk = "Woodwork", amount = -50 }, "an xp penalty")
grantBad({ kind = "xp", amount = 200 }, "an xp grant with no perk")
grantBad({ kind = "xp", perk = "", amount = 200 }, "an empty perk name")
grantBad({ kind = "xp", perk = "Woodwork" }, "an xp grant with no amount")
grantBad({ kind = "xp", perk = "Woodwork", amount = 0 }, "an xp grant of zero")
grantBad({ kind = "xp", perk = "Woodwork", amount = 0/0 }, "a NaN xp amount")
grantBad({ kind = "xp", perk = "Woodwork", amount = 1/0 }, "an infinite xp amount")

-- ---- roulette grants ------------------------------------------------------

local ROULETTE = {
    kind = "roulette", pick = 1,
    from = {
        { weight = 10, grants = { { kind = "item", type = "Base.Katana" } } },
        { weight = 90, grants = { { kind = "item", type = "Base.Crowbar" } } },
    },
}
local rouletteKit = grantOk(ROULETTE, "a roulette grant")
check(rouletteKit and rouletteKit.grants[1].from[2].grants[1].type == "Base.Crowbar",
    "roulette branch grants were not normalized through")

-- pick defaults to 1: a roulette with no pick means "draw one", which is the
-- only reading, so it is a default rather than an unchosen answer.
local defaultPick = grantOk({ kind = "roulette", from = ROULETTE.from },
    "a roulette with no pick")
check(defaultPick and defaultPick.grants[1].pick == 1,
    "a roulette with no pick did not default to 1")

grantBad({ kind = "roulette" }, "a roulette with no branches")
grantBad({ kind = "roulette", from = {} }, "a roulette with an empty branch list")
grantBad({ kind = "roulette", from = "x" }, "a roulette whose from is not a list")
grantBad({ kind = "roulette", from = { { weight = 1 } } },
    "a branch with no grants")
grantBad({ kind = "roulette", from = { { weight = 1, grants = {} } } },
    "a branch that grants nothing")

-- The case the whole-kit check cannot see: ONE empty branch among good ones.
-- The kit grants items, so "does it grant its own kind" is satisfied - and yet
-- one draw in ten hands over nothing at all. Only the per-branch rule catches
-- this, and it is the failure that would be blamed on the server.
local emptyBranch = grantBad({ kind = "roulette", pick = 1, from = {
    { weight = 9, grants = { { kind = "item", type = "Base.Axe" } } },
    { weight = 1, grants = {} },
} }, "one empty branch among good ones")
check(type(emptyBranch) == "string" and emptyBranch:find("branch 2", 1, true),
    "the refusal did not name the empty branch: " .. tostring(emptyBranch))
grantBad({ kind = "roulette", from = { { weight = 1, grants = {
    { kind = "item", type = "Axe" } } } } },
    "a bad grant inside a branch")
grantBad({ kind = "roulette", from = { { weight = 1, grants = {
    { kind = "item", type = "Base.Axe" } }, label = "x" } } },
    "an unknown field on a branch")

-- Weight and pick rules are DMRoll's, asked of DMRoll rather than restated -
-- two copies of "a weight is a positive integer" is how the roulette and the
-- thing that rolls it drift apart. These prove the delegation is wired up.
grantBad({ kind = "roulette", from = { { weight = 0, grants = {
    { kind = "item", type = "Base.Axe" } } } } }, "a zero-weight branch")
grantBad({ kind = "roulette", from = { { weight = 1.5, grants = {
    { kind = "item", type = "Base.Axe" } } } } }, "a fractional weight")
grantBad({ kind = "roulette", pick = 3, from = ROULETTE.from },
    "picking more branches than exist")
grantBad({ kind = "roulette", pick = 0, from = ROULETTE.from },
    "picking zero branches")

-- One level only. Unbounded nesting is recursion on a payload an admin
-- authors, for a design nobody has described.
grantBad({ kind = "roulette", from = { { weight = 1, grants = { ROULETTE } } } },
    "a roulette nested inside a roulette")

-- ---- the item ceiling counts the worst case -------------------------------
-- Pessimistic on purpose: every branch is counted as if it won, even though at
-- most `pick` can. An over-estimate that passes guarantees the real claim does.

check(K.worstCaseItems({ { kind = "item", type = "Base.Axe", count = 4 } }) == 4,
    "worstCaseItems miscounted a plain item grant")
check(K.worstCaseItems({ ROULETTE }) == 2,
    "worstCaseItems did not count both branches of a pick-1 roulette")
check(K.worstCaseItems({ { kind = "flag", name = "x" } }) == 0,
    "worstCaseItems counted a non-item grant")

refuses(withGrants({
    { kind = "item", type = "Base.Axe", count = K.TOTAL_ITEMS_MAX },
    { kind = "item", type = "Base.Crowbar", count = 1 },
}), "a kit one item over the total ceiling")
accepts(withGrants({
    { kind = "item", type = "Base.Axe", count = K.TOTAL_ITEMS_MAX },
}), "a kit exactly at the total ceiling")

-- The per-grant ceiling and the whole-kit ceiling look redundant - anything
-- over the first is over the second - and they are not, because they refuse
-- with DIFFERENT sentences. One oversized grant must be blamed on that grant by
-- position; several legal grants that only overflow together cannot be, and get
-- the aggregate. Deleting the per-grant check leaves a DM with a twenty-row
-- form and a total they have to add up by hand.
local single = refuses(withGrants({
    { kind = "item", type = "Base.Axe", count = K.TOTAL_ITEMS_MAX + 400 },
}), "one item grant far over the ceiling")
check(type(single) == "string" and single:find("grant 1", 1, true) ~= nil,
    "an oversized single grant was blamed on the kit rather than the grant: "
    .. tostring(single))

local spread = refuses(withGrants({
    { kind = "item", type = "Base.Axe", count = 60 },
    { kind = "item", type = "Base.Crowbar", count = 60 },
}), "two legal grants that overflow together")
check(type(spread) == "string" and spread:find("grant ", 1, true) == nil,
    "an overflow no single grant caused was blamed on one of them: "
    .. tostring(spread))

-- A roulette that cannot exceed the cap in play still can on paper, and the cap
-- is deliberately the paper number.
refuses(withGrants({ {
    kind = "roulette", pick = 1,
    from = {
        { weight = 1, grants = { { kind = "item", type = "Base.Axe",
            count = K.TOTAL_ITEMS_MAX } } },
        { weight = 1, grants = { { kind = "item", type = "Base.Crowbar",
            count = K.TOTAL_ITEMS_MAX } } },
    },
} }), "a roulette whose branches together exceed the ceiling")

-- ---- requirements ---------------------------------------------------------

local req = accepts(kit({ requires = {
    flags = { "CryptDelver" },
    counters = { { name = "Samples", atLeast = 10 } },
} }), "a kit with requirements")
check(req and req.requires.flags[1] == "cryptdelver",
    "a required flag was not normalized")
check(req and req.requires.counters[1].name == "samples",
    "a required counter was not normalized")

accepts(kit({ requires = "\0nil" }), "a kit with no requirements at all")
local none = accepts(kit({ requires = {} }), "an empty requirement set")
check(none and #none.requires.flags == 0 and #none.requires.counters == 0,
    "an empty requirement set did not normalize to empty lists")

refuses(kit({ requires = "x" }), "a requires that is not a table")
refuses(kit({ requires = { unless = {} } }), "an unknown requirement field")
refuses(kit({ requires = { flags = "x" } }), "a flags list that is not a list")
refuses(kit({ requires = { flags = { "9lives" } } }), "a bad required flag name")
-- A duplicate evaluates harmlessly, but it means the DM believes they wrote two
-- different requirements. Saying so beats obeying it.
refuses(kit({ requires = { flags = { "A", "a" } } }),
    "the same flag required twice under different casing")
refuses(kit({ requires = { counters = { { name = "S", atLeast = 1 },
    { name = "s", atLeast = 2 } } } }), "the same counter required twice")
refuses(kit({ requires = { counters = { { name = "S" } } } }),
    "a counter requirement with no atLeast")
refuses(kit({ requires = { counters = { { name = "S", atLeast = 0/0 } } } }),
    "a NaN atLeast")
refuses(kit({ requires = { counters = { { name = "S", atLeast = 1/0 } } } }),
    "an infinite atLeast")
refuses(kit({ requires = { counters = { { name = "S", atMost = 1 } } } }),
    "an unknown counter requirement field")
accepts(kit({ requires = { counters = { { name = "S", atLeast = 0 } } } }),
    "requiring a counter of at least zero")

local manyChars, tooManyChars = {}, {}
for i = 1, K.REQUIRES_MAX do manyChars[i] = "m" .. i end
for i = 1, K.REQUIRES_MAX + 1 do tooManyChars[i] = "m" .. i end
accepts(kit({ requires = { flags = manyChars } }), "requirements at the ceiling")
refuses(kit({ requires = { flags = tooManyChars } }),
    "one requirement over the ceiling")

-- ---- validate never hands back the caller's table -------------------------
-- A form still being edited must not be able to mutate a stored kit behind the
-- store's back.

local form = kit({ requires = { flags = { "Live" } } })
local stored = K.validate(form)
check(stored ~= form, "validate returned the caller's own table")
form.grants[1].type = "Base.Crowbar"
form.requires.flags[1] = "Changed"
form.claim.cooldownHours = 999
check(stored.grants[1].type == "Base.Axe", "editing the form mutated the grants")
check(stored.requires.flags[1] == "live", "editing the form mutated the requirements")
check(stored.claim.cooldownHours ~= 999, "editing the form mutated the claim policy")

-- ---- questions consumers ask ----------------------------------------------

-- ---- THE CLAIM POLICY, now one number ------------------------------------
--
-- "Once ever" is gone (owner, 2026-08-24). It never meant what it said: the
-- ledger lives in save-scoped ModData, so a wipe clears it and the flag only
-- ever meant "once per world". A wait longer than the season says that out
-- loud - and takes one dial instead of two.

check(K.cooldownHours(accepts(kit({ claim = { cooldownHours = 0 } }))) == 0,
    "a kit with no wait reported one")
check(K.cooldownHours(accepts(kit({ claim = { cooldownHours = 72 } }))) == 72,
    "the wait did not survive validation")
check(K.cooldownHours(nil) == 0, "cooldownHours answered oddly for nil")
check(K.cooldownMs(accepts(kit({ claim = { cooldownHours = 2 } }))) == 7200000,
    "hours were not converted to milliseconds")
check(K.cooldownMs(accepts(kit({ claim = { cooldownHours = 0 } }))) == nil,
    "a kit with no wait reported a millisecond figure rather than none")

-- THE MIGRATION. Two kits are live on Mosaic carrying the old policy.
local migCap = K.normalizeClaim{ once = true }
check(migCap.cooldownHours == K.COOLDOWN_MAX_HOURS,
    "A ONCE-EVER KIT DID NOT MIGRATE TO THE CAP. Anything less re-opens a "
    .. "reward somebody already took, silently, on whatever day the number "
    .. "happened to land on.")
check(K.normalizeClaim{ once = false }.cooldownHours == 0,
    "a plain repeatable kit did not migrate to no wait")
check(K.normalizeClaim{ once = false, cooldownMins = 90 }.cooldownHours == 2,
    "90 minutes did not round UP to 2 hours - rounding down would make a "
    .. "migrated wait SHORTER than it was")
check(K.normalizeClaim{ once = false, cooldownMins = 120 }.cooldownHours == 2,
    "an exact two hours did not migrate exactly")
-- Idempotent, because the read-time pass runs on every load.
local twice = K.normalizeClaim(K.normalizeClaim{ once = false, cooldownMins = 90 })
check(twice.cooldownHours == 2, "the migration compounded when run twice")
check(K.normalizeClaim{ cooldownHours = 5 }.cooldownHours == 5,
    "a current policy was disturbed by the migration")
check(K.normalizeClaim(nil) == nil, "a nil policy faulted the migration")

-- THE WORDS, in the same two units the form takes. A readout in units nobody
-- can type is a conversion an admin has to do before they can check it.
check(K.claimText{ claim = { cooldownHours = 0 } } == "any time",
    "no wait did not read as any time")
check(K.claimText{ claim = { cooldownHours = 23 } } == "every 23 hr",
    "sub-day did not render in hours: " .. K.claimText{ claim = { cooldownHours = 23 } })
check(K.claimText{ claim = { cooldownHours = 24 } } == "every 1 day",
    "24 hours did not read as a day: " .. K.claimText{ claim = { cooldownHours = 24 } })
check(K.claimText{ claim = { cooldownHours = 2160 } } == "every 90 days",
    "90 days did not render: " .. K.claimText{ claim = { cooldownHours = 2160 } })
check(K.claimText{ claim = { cooldownHours = 25 } } == "every 1d 1h",
    "a mixed wait lost its remainder: " .. K.claimText{ claim = { cooldownHours = 25 } })

-- The two dials <-> the one stored number.
local d, h = K.splitCooldown(2160)
check(d == 90 and h == 0, "90 days did not split cleanly: " .. d .. "/" .. h)
d, h = K.splitCooldown(23)
check(d == 0 and h == 23, "23 hours split into days")
check(K.joinCooldown(90, 0) == 2160, "the dials did not rejoin")
check(K.joinCooldown(1, 1) == 25, "a mixed pair did not rejoin")
check(K.joinCooldown(0, 0) == 0, "an empty pair did not rejoin to zero")
check(K.joinCooldown(-5, -5) == 0, "negative dials produced a negative wait")
for _, n in ipairs({ 0, 1, 23, 24, 25, 2160, 8765 }) do
    check(K.joinCooldown(K.splitCooldown(n)) == n,
        "the split/join round trip lost " .. n)
end

check(K.isUnconditional(base) == true,
    "a kit requiring nothing did not read as unconditional")
check(K.isUnconditional(req) == false,
    "a kit with requirements read as unconditional")
check(K.isUnconditional(nil) == false, "isUnconditional answered for nil")

-- grantsOfKind flattens roulette branches, because an authoring surface listing
-- "this kit can give you these traits" must include the ones you might not win.
-- A flag rides along, since bookkeeping is allowed in any kit and must not be
-- confused with the reward it accompanies.
local mixed = accepts(withGrants({
    { kind = "trait", id = "base:Brave" },
    { kind = "flag", name = "InductedDelver" },
    { kind = "roulette", pick = 1, from = {
        { weight = 1, grants = { { kind = "trait", id = "base:Lucky" } } },
        { weight = 1, grants = { { kind = "trait", id = "base:Brawler" } } },
    } },
}, "trait"), "a trait kit with a roulette and a flag")
local traits = K.grantsOfKind(mixed.grants, "trait")
check(#traits == 3, "grantsOfKind found " .. #traits .. " traits, expected 3")
check(K.grantsOfKind(mixed.grants, "flag")[1].name == "inducteddelver",
    "grantsOfKind did not find the flag riding along")
check(#K.grantsOfKind(mixed.grants, "xp") == 0,
    "grantsOfKind invented a grant of an absent kind")
check(#K.grantsOfKind(nil, "item") == 0, "grantsOfKind threw on nil")

-- ---- one kit, one reward type ---------------------------------------------
-- Handing out ammunition and a skill boost after an event is TWO kits offered
-- together, not one kit carrying both. The rule is structural because the kind
-- decides how the kit presents itself: a drum, a spin and a dial are three
-- ceremonies and a mixed kit has none.

refuses(kit({ kind = "\0nil" }), "a kit that never chose a kind")
refuses(kit({ kind = "items" }), "a pluralised kind")
refuses(kit({ kind = "flag" }), "a flag used as a kit kind")
refuses(kit({ kind = "counter" }), "a counter used as a kit kind")
refuses(kit({ kind = "roulette" }), "a roulette used as a kit kind")
refuses(kit({ kind = true }), "a boolean kind")

local kindReason2 = refuses(kit({ kind = "loot" }), "an invented kind")
check(type(kindReason2) == "string" and kindReason2:find("trait", 1, true),
    "the kind refusal did not list the valid set: " .. tostring(kindReason2))

accepts(withGrants({ { kind = "item", type = "Base.Axe" } }, "item"), "an item kit")
accepts(withGrants({ { kind = "trait", id = "base:Brave" } }, "trait"), "a trait kit")
accepts(withGrants({ { kind = "xp", perk = "Woodwork", amount = 5 } }, "xp"), "an xp kit")

-- Every crossed pair. Each of these is a real authoring mistake and each must
-- be named rather than quietly accepted.
local CROSS = {
    { kit = "item",  grant = { kind = "trait", id = "base:Brave" } },
    { kit = "item",  grant = { kind = "xp", perk = "Woodwork", amount = 5 } },
    { kit = "trait", grant = { kind = "item", type = "Base.Axe" } },
    { kit = "trait", grant = { kind = "xp", perk = "Woodwork", amount = 5 } },
    { kit = "xp",    grant = { kind = "item", type = "Base.Axe" } },
    { kit = "xp",    grant = { kind = "trait", id = "base:Brave" } },
}
for _, c in ipairs(CROSS) do
    local reason = refuses(withGrants({ c.grant }, c.kit),
        "a " .. c.grant.kind .. " grant in a " .. c.kit .. " kit")
    check(type(reason) == "string" and reason:find(c.kit, 1, true)
        and reason:find(c.grant.kind, 1, true),
        "the refusal named neither the kit kind nor the grant kind: "
        .. tostring(reason))
end

-- Flags and counters are not a reward type and ride in any kit. They are
-- bookkeeping - nothing to reveal, nothing to roll - and a kit made only of
-- them would appear in the claim list as something to take that does nothing.
for _, k in ipairs({ "item", "trait", "xp" }) do
    local reward = (k == "item" and { kind = "item", type = "Base.Axe" })
        or (k == "trait" and { kind = "trait", id = "base:Brave" })
        or { kind = "xp", perk = "Woodwork", amount = 5 }
    accepts(withGrants({ reward, { kind = "flag", name = "Claimed" } }, k),
        "a flag riding in a " .. k .. " kit")
    accepts(withGrants({ reward, { kind = "counter", name = "Kits", add = 1 } }, k),
        "a counter riding in a " .. k .. " kit")
end

-- And the kind cannot LIE. A kit made only of bookkeeping is a claim that
-- visibly does nothing.
refuses(withGrants({ { kind = "flag", name = "Claimed" } }, "item"),
    "an item kit that grants no items")
refuses(withGrants({ { kind = "counter", name = "Kits", add = 1 } }, "xp"),
    "an xp kit that grants no xp")
refuses(withGrants({ { kind = "flag", name = "A" },
    { kind = "counter", name = "B", add = 1 } }, "trait"),
    "a trait kit made entirely of bookkeeping")

-- A kit whose only reward is a roulette prize still counts - the check has to
-- descend into branches or every roulette-only kit is refused.
accepts(withGrants({ { kind = "roulette", pick = 1, from = {
    { weight = 1, grants = { { kind = "item", type = "Base.Axe" } } },
} } }, "item"), "an item kit whose only item is a roulette prize")

-- A ROULETTE IS NOT AN ESCAPE HATCH. An item kit whose rare branch hands over a
-- trait is the hardest mixed kit to notice, because it only misbehaves on the
-- draw almost nobody gets.
refuses(withGrants({ { kind = "roulette", pick = 1, from = {
    { weight = 99, grants = { { kind = "item", type = "Base.Crowbar" } } },
    { weight = 1,  grants = { { kind = "trait", id = "base:Lucky" } } },
} } }, "item"), "a trait hidden in the rare branch of an item kit's roulette")

accepts(withGrants({ { kind = "roulette", pick = 1, from = {
    { weight = 99, grants = { { kind = "xp", perk = "Woodwork", amount = 10 } } },
    { weight = 1,  grants = { { kind = "xp", perk = "Fitness", amount = 500 } } },
} } }, "xp"), "an xp roulette in an xp kit")

-- The kind survives validation onto the stored definition - the claim UI reads
-- it to decide which reveal to play.
local typed = accepts(withGrants({ { kind = "xp", perk = "Woodwork", amount = 5 } }, "xp"))
check(typed and typed.kind == "xp", "the kit kind was not carried through")

-- ---- CONTENTS: the two audiences ------------------------------------------
--
-- One projection, and the ONLY difference is the odds (owner, 2026-08-23:
-- "contents always, odds only on the admin surface"). What is at risk is the
-- filtering being a DISPLAY choice rather than a payload one - a client asked
-- to hide a number it was sent is a client that can decline.

local SHOWY = {
    id = "showy", kind = "item", label = "Showy", claim = { once = true },
    grants = {
        { kind = "item", type = "Base.Axe", count = 2 },
        { kind = "flag", name = "Delver" },
        { kind = "counter", name = "Runs", add = 1 },
        { kind = "roulette", pick = 1, from = {
            { weight = 10, grants = { { kind = "item", type = "Base.Katana" } } },
            { weight = 30, grants = { { kind = "item", type = "Base.Crowbar" } } },
        } },
    },
}

local player = DMKitDefs.contents(SHOWY, false)
local admin  = DMKitDefs.contents(SHOWY, true)

check(#player == 2, "expected the item and the roulette, got " .. #player)
check(player[1].kind == "item" and player[1].ref == "Base.Axe"
      and player[1].count == 2, "the item row lost its type or count")
check(player[2].kind == "roulette" and #player[2].branches == 2,
    "the roulette did not survive the projection")

-- Bookkeeping is absent from BOTH. A claim panel listing "you will receive:
-- the Delver flag" means nothing to a player and advertises the substrate.
for _, row in ipairs(admin) do
    check(row.kind ~= "flag" and row.kind ~= "counter",
        "A BOOKKEEPING GRANT REACHED THE CONTENTS LIST (" .. tostring(row.kind)
        .. "). Flags and counters are how the suite remembers things, not "
        .. "rewards to advertise.")
end

-- THE ODDS RULE.
check(player[2].branches[1].percent == nil,
    "A WEIGHT REACHED THE PLAYER. Filtering must happen in the payload, not "
    .. "in the drawing - a client sent the number can choose to show it.")
check(admin[2].branches[1].percent == 25,
    "the admin projection did not normalise 10 of 40 to 25%: "
    .. tostring(admin[2].branches[1].percent))
check(admin[2].branches[2].percent == 75,
    "the second branch normalised wrong: " .. tostring(admin[2].branches[2].percent))

-- pick travels so a surface can say "2 of these" rather than implying one.
check(player[2].pick == 1, "pick did not travel")
local multi = DMKitDefs.contents({ grants = { { kind = "roulette", pick = 2, from = {
    { weight = 1, grants = { { kind = "item", type = "A.a" } } },
    { weight = 1, grants = { { kind = "item", type = "B.b" } } },
    { weight = 2, grants = { { kind = "item", type = "C.c" } } },
} } } }, true)
check(multi[1].pick == 2, "a multi-draw roulette reported pick 1")
check(multi[1].branches[3].percent == 50, "weights of 1/1/2 did not normalise")

-- A branch of pure bookkeeping is still an OUTCOME. Dropping it would make the
-- visible branches read likelier than they are.
local sneaky = DMKitDefs.contents({ grants = { { kind = "roulette", pick = 1, from = {
    { weight = 50, grants = { { kind = "item", type = "Base.Axe" } } },
    { weight = 50, grants = { { kind = "flag", name = "Consolation" } } },
} } } }, true)
check(#sneaky[1].branches == 2,
    "A BRANCH WAS DROPPED FOR HOLDING NOTHING VISIBLE. The remaining branch "
    .. "would then read as a certainty when it is a coin flip.")
check(sneaky[1].branches[2].percent == 50,
    "the invisible branch lost its share of the odds")

-- Zero total weight cannot divide. It is refused by validate, but contents()
-- is called on stored kits and must not fault on one that got in another way.
local okZero = pcall(DMKitDefs.contents, { grants = { { kind = "roulette", from = {
    { weight = 0, grants = {} },
} } } }, true)
check(okZero, "a zero-weight table faulted the projection")

check(#DMKitDefs.contents(nil, false) == 0, "a nil kit did not project empty")
check(#DMKitDefs.contents({}, true) == 0, "a kit with no grants did not project empty")

-- ---- THE COOLDOWN, end to end -------------------------------------------
--
-- The policy the whole system reads. Covered above field by field; this pins
-- the shapes an authoring surface actually produces.

local function withWait(hours)
    return DMKitDefs.validate{
        id = "cd", kind = "item", claim = { cooldownHours = hours },
        grants = { { kind = "item", type = "Base.Axe" } },
    }
end

check(withWait(0) ~= nil, "a kit with no wait was refused")
check(withWait(24) ~= nil, "a daily kit was refused")
check(withWait(2920) ~= nil, "a season-long kit was refused")
check(withWait(DMKitDefs.COOLDOWN_MAX_HOURS) ~= nil, "the cap itself was refused")
check(withWait(-1) == nil, "a negative wait was accepted")
check(withWait(0.5) == nil, "a half hour was accepted")

local seasoned = withWait(2920)
check(DMKitDefs.cooldownMs(seasoned) == 2920 * 3600000,
    "a season-long wait converted wrong")
-- 2920 hours is 121 days and 16 hours, and it SAYS so rather than rounding to
-- a whole number of days. A wait shown shorter than it is sends a player back
-- early; shown longer, it looks like the panel is wrong.
check(DMKitDefs.claimText(seasoned) == "every 121d 16h",
    "a four-month season did not render exactly: " .. DMKitDefs.claimText(seasoned))
check(DMKitDefs.claimText{ claim = { cooldownHours = 2880 } } == "every 120 days",
    "an exact 120 days picked up a spurious remainder")

print(string.format("DMKitDefs: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
