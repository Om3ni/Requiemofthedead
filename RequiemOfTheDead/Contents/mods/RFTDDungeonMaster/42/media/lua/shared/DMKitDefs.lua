-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMKitDefs - what a kit IS, and whether a submitted one is well formed.
--
-- The kit is the mod's reward primitive: quests hand them out, a dungeon's
-- locked room hands them out, an admin hands them out. This file owns the
-- shape and nothing else - no store, no player, no engine. Everything that can
-- be decided about a kit by looking at it decides here, where a fixture can
-- sweep it; everything needing the world (does that item script exist, is that
-- trait registered, is that var defined) is refused by the server at AUTHOR
-- time, not at claim time.
--
-- THAT SPLIT IS THE DESIGN. A kit whose item type is a typo must fail while the
-- DM is looking at the form. If it fails at claim instead, the person who finds
-- out is a player who just spent a quest chain on nothing, and the person who
-- has to work out why is whoever reads the log a week later.
--
-- WHY REFUSALS ARE SENTENCES. Every reason here is shown to an admin verbatim,
-- so it names the field, the position and the value. "grant 3 is invalid" costs
-- a hunt through a twenty-row form; "grant 3: an item count must be a whole
-- number, got 2.5" does not.
--
-- ---------------------------------------------------------------------------
-- ONE KIT, ONE REWARD TYPE. This is the shape of the whole system, not a
-- validation rule bolted on afterwards (owner, 2026-08-23).
--
-- A kit is an ITEM kit, a TRAIT kit or an XP kit. It may never be two of them.
-- Finishing an event and wanting to hand out ammunition, bandages, a backpack
-- AND a skill boost is TWO KITS, both offered at once - "Anomaly Loot" and
-- "Anomaly XP" - each claimed on its own.
--
-- Three reasons, and only the first is aesthetic:
--
--   * THE REVEAL IS PER TYPE. Items arrive as a sequence, a trait lands out of
--     a spin, XP counts up on a dial. Those are three different ceremonies and
--     a mixed kit has no coherent one - it would have to play all three or
--     pick one and misrepresent the rest. A single-kind kit knows how to
--     present itself, which is what makes the claim UI possible at all.
--   * THEY FAIL SEPARATELY. Bundling loot with a skill boost entangles two
--     unrelated rewards in one partial failure: the ammunition could not be
--     created, so what happened to the XP? Two kits have two answers.
--   * THEY LIVE ON DIFFERENT CLOCKS. An XP stipend might be claimable weekly
--     and a loot cache once ever. One kit forces one claim policy onto both.
--
-- MARKERS AND COUNTERS ARE NOT A FOURTH KIND, and are allowed in any kit. They
-- are bookkeeping, not a reward: there is nothing to reveal, nothing to roll,
-- and nothing a player sees. A "var kit" would appear in the claim list as
-- something to take that visibly does nothing, which is why the kind is not
-- simply "whatever the grants happen to be".
--
-- WHAT IS DELIBERATELY ABSENT
--
-- `claim.consumes` does not exist, and adding it would be a bug. A flag that
-- should be revoked when a kit is claimed declares that ITSELF, in its own
-- revokers.kit field, which RDVarDefs already validates and RDVars.revoke's
-- header already names as this system's job. Listing consumed vars on the kit
-- as well would be two places saying one thing - the exact failure RDVarDefs
-- calls out for resetOnDeath against revokers.death. The kit walks the var
-- definitions at claim time and revokes the ones pointing at it.
--
-- A "must NOT hold" requirement, a counter upper bound, and nested roulettes
-- are all absent because nothing has asked for them. The first two are additive
-- - a new field, no migration. The third is refused on purpose: a roulette
-- inside a roulette is unbounded recursion on a wire payload and on the
-- evaluator, for no design nobody has described.
--
-- ENGINE-FREE. Requires RDVarDefs for the two var-kind constants and nothing
-- else, so the fixture runs it directly. Reusing those constants rather than
-- respelling "flag" and "counter" is not tidiness: that pair has been renamed
-- twice already -
-- 2026-08-23 (it used to be "string"), and a private copy here would have
-- silently kept the old vocabulary alive.

require "RDVarDefs"
require "DMRoll"

DMKitDefs = DMKitDefs or {}

DMKitDefs.ID_MAX    = 48
DMKitDefs.LABEL_MAX = 64

-- One kit is a reward, not a warehouse. The bound also keeps an authored
-- definition to one sane wire payload.
DMKitDefs.GRANTS_MAX   = 32
DMKitDefs.REQUIRES_MAX = 16

-- Matches Dragonfly's own clamp (DFInventory_Server.lua:462-466) and for the
-- same reason, read from the same place: every unit fires an AddItem plus a
-- sendAddItemToContainer packet, so an unbounded count is a one-tick packet
-- flood. This bounds the WORST CASE across the whole kit - see worstCaseItems.
DMKitDefs.TOTAL_ITEMS_MAX = 100

-- ---------------------------------------------------------------------------
-- HOW OFTEN A KIT MAY BE TAKEN
--
-- ONE NUMBER. Hours between claims, zero for none, and that is the whole
-- policy (owner, 2026-08-24).
--
-- THERE IS NO "ONCE EVER", and removing it lost nothing, because it never
-- meant what it said. The claim ledger lives in ModData, ModData is save-
-- scoped, and a wipe destroys the save - so "once ever" has always been "once
-- per WORLD" (RDConfigStore.lua:22-25, and DMKits' own header says the same
-- from the other side: claims are deliberately not restored across a wipe, or
-- every player would be locked out of every reward on a map they have never
-- seen). A wait longer than the season expresses that exactly, and says out
-- loud what the old flag only implied.
--
-- What it costs: a season that grows past the wait re-opens those kits, where
-- a boolean would not have. That is a real difference and the honest trade for
-- one dial instead of two - so the authoring help names the season length as
-- the number to beat rather than leaving an admin to pick a magic one.
--
-- HOURS, not minutes. A kit is event-scale - daily, weekly, once a season -
-- and minutes put four extra digits on every number an admin reads. A day is
-- 24, a week 168, a month about 730, a four-month season about 2920.
--
-- REAL TIME, not game time, and it always was: the stamp is RDShared.nowMs ->
-- getTimestampMs -> System.currentTimeMillis (LuaManager.java:7471). Nothing
-- here is scaled by day length, so "24" is a day whatever the sandbox says.
--
-- The cap is a hundred years, past which the millisecond arithmetic stops
-- being exact against a wall clock.
local COOLDOWN_MAX_HOURS = 100 * 8766

DMKitDefs.COOLDOWN_MAX_HOURS = COOLDOWN_MAX_HOURS

-- Grant kinds. An OPEN SET by construction: a sixth kind is a new entry in this
-- table plus a validator, never a schema migration, because nothing outside
-- reads the list.
DMKitDefs.ITEM     = "item"
DMKitDefs.FLAG     = RDVarDefs.FLAG      -- grant a flag
DMKitDefs.COUNTER  = RDVarDefs.COUNTER   -- move a counter
DMKitDefs.TRAIT    = "trait"
DMKitDefs.XP       = "xp"
DMKitDefs.ROULETTE = "roulette"

-- The three REWARD kinds, and therefore the three kit kinds - a kit is named
-- for the one it carries. flag and counter are deliberately absent: see the
-- header, they are bookkeeping and belong to no bucket.
DMKitDefs.KIT_KINDS = {
    [DMKitDefs.ITEM]  = true,
    [DMKitDefs.TRAIT] = true,
    [DMKitDefs.XP]    = true,
}

-- Written out rather than derived from KIT_KINDS, because pairs() order is
-- arbitrary and a refusal that lists the valid set in a different order every
-- time reads as a different error.
local KIT_KIND_LIST = DMKitDefs.ITEM .. ", " .. DMKitDefs.TRAIT
    .. ", " .. DMKitDefs.XP

local ALLOWED_FIELDS = {
    id = true, kind = true, label = true, requires = true, claim = true,
    grants = true,
    note = true,          -- free-text admin commentary; never interpreted
}

-- ---------------------------------------------------------------------------
-- Ids
--
-- The id is the STABLE KEY: a quest's reward field points at it, a var's
-- revokers.kit points at it, and the claim ledger is keyed by it. Renaming one
-- silently orphans every reference, so it is constrained to the characters that
-- survive a JSON key, a command argument and a file name unaltered.
--
-- The label is separate and free - "Delver's Reward" has a space and an
-- apostrophe and should never have to be a key.
-- ---------------------------------------------------------------------------

function DMKitDefs.normalizeId(raw)
    if type(raw) ~= "string" then
        return nil, "a kit id must be a string, got " .. type(raw)
    end
    local trimmed = raw:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil, "a kit id cannot be empty"
    end
    if #trimmed > DMKitDefs.ID_MAX then
        return nil, "'" .. trimmed .. "' is longer than " .. DMKitDefs.ID_MAX
            .. " characters"
    end
    -- Same rule as a var name, and for the same reasons: a leading digit reads
    -- as an array index where these keys land, and a leading hyphen reads as a
    -- flag in a console command.
    if not trimmed:match("^%a[%w_%-]*$") then
        return nil, "'" .. trimmed .. "' must start with a letter and use only "
            .. "letters, digits, underscore and hyphen"
    end
    return trimmed:lower()
end

-- ---------------------------------------------------------------------------
-- Grants
--
-- One validator per kind, dispatched by name. Each returns a NEW normalized
-- table or (nil, reason); the reason never carries the position, which the
-- caller prefixes, so a validator reads the same whether it was reached from
-- the top level or from inside a roulette branch.
-- ---------------------------------------------------------------------------

local function finite(v)
    return type(v) == "number" and v == v and v - v == 0
end

local function wholeCount(v, what)
    if type(v) ~= "number" then
        return nil, what .. " must be a number, got " .. type(v)
            .. " (" .. tostring(v) .. ")"
    end
    if v ~= v then return nil, what .. " cannot be NaN" end
    if v - v ~= 0 then return nil, what .. " cannot be infinite" end
    if v % 1 ~= 0 then
        return nil, what .. " must be a whole number, got " .. tostring(v)
    end
    if v < 1 then
        return nil, what .. " must be at least 1, got " .. tostring(v)
    end
    return v
end

local function nonEmptyString(v, what)
    if type(v) ~= "string" then
        return nil, what .. " must be a string, got " .. type(v)
    end
    local trimmed = v:match("^%s*(.-)%s*$")
    if trimmed == "" then return nil, what .. " cannot be empty" end
    return trimmed
end

local function onlyFields(t, allowed, what)
    for k in pairs(t) do
        if not allowed[k] then
            return nil, "'" .. tostring(k) .. "' is not a field of " .. what
        end
    end
    return true
end

local validators = {}

validators[DMKitDefs.ITEM] = function(g)
    local ok, why = onlyFields(g, { kind = true, type = true, count = true },
        "an item grant")
    if not ok then return nil, why end

    -- Not validated against the script manager here - this file has no engine.
    -- The server does it at author time (getScriptManager():getItem), because
    -- AddItem answers a bad type with nil rather than an error and the failure
    -- would otherwise surface as an empty reward.
    local ft, err = nonEmptyString(g.type, "an item type")
    if not ft then return nil, err end
    if not ft:find(".", 1, true) then
        return nil, "an item type needs its module - 'Base.Axe', not '"
            .. ft .. "'"
    end

    local count = 1
    if g.count ~= nil then
        count, err = wholeCount(g.count, "an item count")
        if not count then return nil, err end
    end
    if count > DMKitDefs.TOTAL_ITEMS_MAX then
        return nil, "an item count cannot exceed " .. DMKitDefs.TOTAL_ITEMS_MAX
            .. ", got " .. count
    end

    return { kind = DMKitDefs.ITEM, type = ft, count = count }
end

validators[DMKitDefs.FLAG] = function(g)
    local ok, why = onlyFields(g, { kind = true, name = true }, "a flag grant")
    if not ok then return nil, why end
    -- Reuses the var system's own normalizer so a kit and a var definition can
    -- never disagree about what "Anomaly" and "anomaly" mean.
    local key, reason = RDVarDefs.normalizeName(g.name)
    if not key then return nil, reason end
    return { kind = DMKitDefs.FLAG, name = key }
end

validators[DMKitDefs.COUNTER] = function(g)
    local ok, why = onlyFields(g,
        { kind = true, name = true, add = true, set = true }, "a counter grant")
    if not ok then return nil, why end

    local key, reason = RDVarDefs.normalizeName(g.name)
    if not key then return nil, reason end

    -- Exactly one of add/set. "+5 samples" and "stage becomes 3" are different
    -- operations with different meanings on a re-claim, and a grant carrying
    -- both would have to pick one silently.
    local hasAdd, hasSet = g.add ~= nil, g.set ~= nil
    if hasAdd and hasSet then
        return nil, "a counter grant takes add or set, not both"
    end
    if not hasAdd and not hasSet then
        return nil, "a counter grant needs add or set - there is no default, "
            .. "because 'add 0' and 'set 0' are different things"
    end

    local field = hasAdd and "add" or "set"
    local v = hasAdd and g.add or g.set
    if not finite(v) then
        return nil, "a counter grant's " .. field
            .. " must be a finite number, got " .. tostring(v)
    end
    if hasAdd and v == 0 then
        return nil, "a counter grant that adds 0 does nothing - remove it or "
            .. "use set"
    end

    local out = { kind = DMKitDefs.COUNTER, name = key }
    out[field] = v
    return out
end

validators[DMKitDefs.TRAIT] = function(g)
    local ok, why = onlyFields(g, { kind = true, id = true }, "a trait grant")
    if not ok then return nil, why end

    -- THE ID MUST BE THE tostring(trait) FORM, namespace and all. getName()
    -- strips the namespace (CharacterTrait.java:117-119), so a bare path is
    -- ambiguous the moment any mod registers the same one - which is the
    -- collision CLAUDE.md sect. 6 exists for.
    --
    -- The SHAPE is deliberately not checked here beyond being a non-empty
    -- string. This module cannot see the trait registry, and a guess about how
    -- vanilla ids render would either reject every base trait or accept a typo.
    -- The server resolves the id against CharacterTraitDefinition.getTraits()
    -- when the kit is saved and refuses one that does not exist, which is a
    -- real answer rather than a pattern that hopes.
    local id, err = nonEmptyString(g.id, "a trait id")
    if not id then return nil, err end
    if #id > DMKitDefs.ID_MAX * 2 then
        return nil, "a trait id longer than " .. (DMKitDefs.ID_MAX * 2)
            .. " characters is not a registry id"
    end
    return { kind = DMKitDefs.TRAIT, id = id }
end

validators[DMKitDefs.XP] = function(g)
    local ok, why = onlyFields(g, { kind = true, perk = true, amount = true },
        "an xp grant")
    if not ok then return nil, why end

    local perk, err = nonEmptyString(g.perk, "a perk name")
    if not perk then return nil, err end

    if not finite(g.amount) then
        return nil, "an xp amount must be a finite number, got "
            .. tostring(g.amount)
    end
    -- Negative is legal - it is how vanilla's own admin screen lowers a perk
    -- (ISPlayerStatsUI.lua:533-543) and a cursed kit is a design, not a typo.
    -- Zero is not: it is a grant that does nothing while looking like one that
    -- does, which is the shape of an unfinished form.
    if g.amount == 0 then
        return nil, "an xp grant of 0 does nothing - remove it"
    end

    return { kind = DMKitDefs.XP, perk = perk, amount = g.amount }
end

-- Forward declaration: a roulette validates the grants inside its branches.
local validateGrants

validators[DMKitDefs.ROULETTE] = function(g, depth, kitKind)
    local ok, why = onlyFields(g, { kind = true, pick = true, from = true },
        "a roulette grant")
    if not ok then return nil, why end

    -- One level, on purpose. See the header: nesting is unbounded recursion on
    -- a payload an admin can author, and nothing has described a design needing
    -- it.
    if depth > 0 then
        return nil, "a roulette cannot contain another roulette"
    end

    if type(g.from) ~= "table" then
        return nil, "a roulette needs a list of branches, got " .. type(g.from)
    end

    local branches = {}
    for i = 1, #g.from do
        local b = g.from[i]
        if type(b) ~= "table" then
            return nil, "branch " .. i .. " must be a table, got " .. type(b)
        end
        local bOk, bWhy = onlyFields(b, { weight = true, grants = true },
            "a roulette branch")
        if not bOk then return nil, "branch " .. i .. ": " .. bWhy end

        -- The kit's kind goes down into the branch too. A roulette is not an
        -- escape hatch: an item kit whose rare branch hands over a trait is
        -- exactly the mixed kit the whole rule exists to prevent, and it would
        -- be the hardest possible one to notice - it only misbehaves on the
        -- draw nobody gets.
        local inner, innerWhy = validateGrants(b.grants, depth + 1, kitKind)
        if not inner then return nil, "branch " .. i .. ": " .. innerWhy end
        -- A branch that wins and hands over nothing is indistinguishable from a
        -- broken claim from the player's side.
        if #inner == 0 then
            return nil, "branch " .. i .. " grants nothing - a branch that can "
                .. "win must hand something over"
        end
        branches[i] = { weight = b.weight, grants = inner }
    end

    -- Weights and the pick count are DMRoll's rules, asked of DMRoll rather
    -- than restated here. Two copies of "a weight must be a positive integer"
    -- is how the roulette and the thing that rolls it drift apart.
    local pick = g.pick == nil and 1 or g.pick
    local rollOk, rollWhy = DMRoll.validate(branches, pick)
    if not rollOk then return nil, rollWhy end

    return { kind = DMKitDefs.ROULETTE, pick = pick, from = branches }
end

-- ---------------------------------------------------------------------------

validateGrants = function(grants, depth, kitKind)
    if type(grants) ~= "table" then
        return nil, "grants must be a list, got " .. type(grants)
    end
    local n = #grants
    if n > DMKitDefs.GRANTS_MAX then
        return nil, "a kit cannot hold more than " .. DMKitDefs.GRANTS_MAX
            .. " grants, got " .. n
    end

    local out = {}
    for i = 1, n do
        local g = grants[i]
        if type(g) ~= "table" then
            return nil, "grant " .. i .. " must be a table, got " .. type(g)
        end
        local validator = validators[g.kind]
        if not validator then
            return nil, "grant " .. i .. ": '" .. tostring(g.kind)
                .. "' is not a grant kind - the set is " .. DMKitDefs.ITEM
                .. ", " .. DMKitDefs.FLAG .. ", " .. DMKitDefs.COUNTER .. ", "
                .. DMKitDefs.TRAIT .. ", " .. DMKitDefs.XP .. ", "
                .. DMKitDefs.ROULETTE
        end
        -- One kit, one reward type. Flags, counters and the roulette itself
        -- are not reward kinds and pass through - see the header.
        if DMKitDefs.KIT_KINDS[g.kind] and g.kind ~= kitKind then
            return nil, "grant " .. i .. ": this is a " .. kitKind
                .. " kit, so it cannot carry a " .. g.kind
                .. " grant - that belongs in a " .. g.kind
                .. " kit of its own, offered alongside this one"
        end

        local normalized, why = validator(g, depth, kitKind)
        if not normalized then return nil, "grant " .. i .. ": " .. why end
        out[i] = normalized
    end
    return out
end

-- ---------------------------------------------------------------------------
-- How many items could this kit possibly hand over?
--
-- Deliberately PESSIMISTIC: every roulette branch is counted as if it won, even
-- though at most `pick` of them can. An over-estimate that passes guarantees the
-- real claim passes, and the alternative - summing the `pick` heaviest branches
-- - is arithmetic nobody can check by reading the form.
-- ---------------------------------------------------------------------------

function DMKitDefs.worstCaseItems(grants)
    local total = 0
    for _, g in ipairs(grants or {}) do
        if g.kind == DMKitDefs.ITEM then
            total = total + (g.count or 1)
        elseif g.kind == DMKitDefs.ROULETTE then
            for _, b in ipairs(g.from or {}) do
                total = total + DMKitDefs.worstCaseItems(b.grants)
            end
        end
    end
    return total
end

-- ---------------------------------------------------------------------------
-- Requirements
-- ---------------------------------------------------------------------------

local function validateRequires(requires)
    if requires == nil then return { flags = {}, counters = {} } end
    if type(requires) ~= "table" then
        return nil, "requires must be a table, got " .. type(requires)
    end
    local ok, why = onlyFields(requires, { flags = true, counters = true },
        "a requirement set")
    if not ok then return nil, why end

    local out = { flags = {}, counters = {} }

    local flags = requires.flags or {}
    if type(flags) ~= "table" then
        return nil, "requires.flags must be a list, got " .. type(flags)
    end
    if #flags > DMKitDefs.REQUIRES_MAX then
        return nil, "a kit cannot require more than " .. DMKitDefs.REQUIRES_MAX
            .. " flags, got " .. #flags
    end
    local seen = {}
    for i = 1, #flags do
        local key, reason = RDVarDefs.normalizeName(flags[i])
        if not key then return nil, "requires.flags " .. i .. ": " .. reason end
        -- A duplicate is not harmful to evaluate, but it means the DM believes
        -- they wrote two different requirements. Saying so beats obeying it.
        if seen[key] then
            return nil, "requires.flags names '" .. key .. "' twice"
        end
        seen[key] = true
        out.flags[#out.flags + 1] = key
    end

    local counters = requires.counters or {}
    if type(counters) ~= "table" then
        return nil, "requires.counters must be a list, got " .. type(counters)
    end
    if #counters > DMKitDefs.REQUIRES_MAX then
        return nil, "a kit cannot require more than " .. DMKitDefs.REQUIRES_MAX
            .. " counters, got " .. #counters
    end
    local seenCounter = {}
    for i = 1, #counters do
        local c = counters[i]
        if type(c) ~= "table" then
            return nil, "requires.counters " .. i .. " must be a table, got "
                .. type(c)
        end
        local cOk, cWhy = onlyFields(c, { name = true, atLeast = true },
            "a counter requirement")
        if not cOk then return nil, "requires.counters " .. i .. ": " .. cWhy end

        local key, reason = RDVarDefs.normalizeName(c.name)
        if not key then
            return nil, "requires.counters " .. i .. ": " .. reason
        end
        if seenCounter[key] then
            return nil, "requires.counters names '" .. key .. "' twice"
        end
        seenCounter[key] = true

        if not finite(c.atLeast) then
            return nil, "requires.counters " .. i
                .. ": atLeast must be a finite number, got "
                .. tostring(c.atLeast)
        end
        out.counters[#out.counters + 1] = { name = key, atLeast = c.atLeast }
    end

    return out
end

-- ---------------------------------------------------------------------------
-- The whole definition
--
-- Returns a NEW normalized table or (nil, reason). Never the caller's table: a
-- form still being edited must not be able to mutate a stored kit behind the
-- store's back.
-- ---------------------------------------------------------------------------

function DMKitDefs.validate(def)
    if type(def) ~= "table" then
        return nil, "a kit definition must be a table, got " .. type(def)
    end

    local ok, why = onlyFields(def, ALLOWED_FIELDS, "a kit definition")
    if not ok then return nil, why end

    local id, reason = DMKitDefs.normalizeId(def.id)
    if not id then return nil, reason end

    -- Required, with no default and nothing inferred from the grants. The kind
    -- decides how the kit PRESENTS itself, and a presentation should be
    -- authored rather than derived - inferring it would also mean a DM building
    -- an XP kit who mistypes one grant gets a silently reclassified kit instead
    -- of a sentence telling them which grant does not belong.
    if not DMKitDefs.KIT_KINDS[def.kind] then
        return nil, "a kit's kind must be " .. KIT_KIND_LIST .. ", got "
            .. tostring(def.kind) .. " - one kit carries one reward type, and "
            .. "handing out loot and a skill boost together is two kits"
    end

    local label = def.label
    if label == nil then
        label = def.id:match("^%s*(.-)%s*$")
    else
        label, reason = nonEmptyString(label, "a kit label")
        if not label then return nil, reason end
    end
    if #label > DMKitDefs.LABEL_MAX then
        return nil, "a kit label longer than " .. DMKitDefs.LABEL_MAX
            .. " characters will not fit the panel"
    end

    if def.note ~= nil and type(def.note) ~= "string" then
        return nil, "note must be a string, got " .. type(def.note)
    end

    local claim = DMKitDefs.normalizeClaim(def.claim)
    if type(claim) ~= "table" then
        return nil, "a kit needs a claim policy - "
            .. "claim = { cooldownHours = 0 } for no wait, or the hours between "
            .. "claims"
    end
    ok, why = onlyFields(claim, { cooldownHours = true }, "a claim policy")
    if not ok then return nil, why end

    -- NO DEFAULT, for the reason RDVarDefs gives for resetOnDeath: an unset
    -- default is how behaviour nobody chose is discovered months later. Here
    -- the unchosen answer is a kit with no wait at all, which is a farm. Zero
    -- is a legitimate answer and must be TYPED, not arrived at by omission.
    if type(claim.cooldownHours) ~= "number"
        or claim.cooldownHours ~= math.floor(claim.cooldownHours)
        or claim.cooldownHours < 0 then
        return nil, "claim.cooldownHours is required and must be a whole "
            .. "number of hours, zero or more - there is deliberately no "
            .. "default, because the unchosen answer is a kit that can be "
            .. "farmed"
    end
    if claim.cooldownHours > COOLDOWN_MAX_HOURS then
        return nil, "claim.cooldownHours is capped at " .. COOLDOWN_MAX_HOURS
            .. " (a hundred years). Past that the arithmetic stops being exact "
            .. "against a wall clock"
    end

    local requires, requiresWhy = validateRequires(def.requires)
    if not requires then return nil, requiresWhy end

    local grants, grantsWhy = validateGrants(def.grants, 0, def.kind)
    if not grants then return nil, grantsWhy end
    if #grants == 0 then
        return nil, "a kit must grant something"
    end

    -- And it must grant the thing it is NAMED for. Without this the kind is a
    -- label that can lie: an "item kit" carrying nothing but a flag would sit
    -- in the claim list as something to take and hand over nothing a player can
    -- see. Same rule as a roulette branch that grants nothing, one level up.
    -- grantsOfKind descends into branches, so a kit whose only item is a
    -- roulette prize counts.
    if #DMKitDefs.grantsOfKind(grants, def.kind) == 0 then
        return nil, "this is a " .. def.kind .. " kit but it grants no "
            .. def.kind .. " - flags and counters are bookkeeping, so a kit "
            .. "made only of them is a claim that visibly does nothing"
    end

    local worst = DMKitDefs.worstCaseItems(grants)
    if worst > DMKitDefs.TOTAL_ITEMS_MAX then
        return nil, "this kit could hand over " .. worst .. " items and the "
            .. "ceiling is " .. DMKitDefs.TOTAL_ITEMS_MAX
            .. " - every item is its own pair of packets"
    end

    return {
        id       = id,
        kind     = def.kind,
        label    = label,
        note     = def.note,
        claim    = { cooldownHours = claim.cooldownHours },
        requires = requires,
        grants   = grants,
    }
end

-- ---------------------------------------------------------------------------
-- Questions consumers ask about a kit
-- ---------------------------------------------------------------------------

-- An old claim policy -> the current one. Kits authored before 2026-08-24
-- carry `once` and `cooldownMins`; two of them are live on Mosaic right now,
-- so this is a migration rather than a courtesy.
--
--   once = true            -> the cap. It meant "not again this world", and
--                             the cap is the honest spelling of that. An admin
--                             who wants "once per season" edits it down to the
--                             season, which is the number they actually mean.
--   cooldownMins = N       -> ceil(N/60) hours, rounding UP so a migrated wait
--                             is never SHORTER than it was.
--   once = false, no mins  -> zero.
--
-- Idempotent: a policy already in the new shape passes through untouched, so
-- the read-time pass in DMKits can run on every load without compounding.
function DMKitDefs.normalizeClaim(claim)
    if type(claim) ~= "table" then return claim end
    -- ONLY A RECOGNISED OLD POLICY IS MIGRATED - `once` as an actual boolean.
    -- Anything else passes through untouched so the validation below can refuse
    -- it by name. A looser test here would quietly turn a malformed policy, or
    -- an EMPTY one, into "no wait at all" - which is the farmable default the
    -- no-default rule exists to prevent, arrived at by migration instead of by
    -- omission.
    if type(claim.once) == "boolean" then
        if claim.once then return { cooldownHours = COOLDOWN_MAX_HOURS } end
        local mins = tonumber(claim.cooldownMins) or 0
        -- Rounded UP, so a migrated wait is never shorter than it was.
        return { cooldownHours = (mins > 0) and math.ceil(mins / 60) or 0 }
    end
    return claim
end

-- The wait between claims, in milliseconds, or nil when there is none. One
-- expression of it, because the entitlement check, the claim panel's countdown
-- and the authoring summary must never disagree about when a kit comes round.
function DMKitDefs.cooldownMs(def)
    if type(def) ~= "table" or type(def.claim) ~= "table" then return nil end
    local hours = def.claim.cooldownHours
    if type(hours) ~= "number" or hours < 1 then return nil end
    return hours * 3600000
end

function DMKitDefs.cooldownHours(def)
    if type(def) ~= "table" or type(def.claim) ~= "table" then return 0 end
    return tonumber(def.claim.cooldownHours) or 0
end

-- The policy in words, for every surface that shows one.
--
-- DAYS AND HOURS, the same two units the authoring form takes (owner,
-- 2026-08-24) - no months, no years. A readout in units the admin cannot type
-- is a number they have to convert before they can check it against what they
-- meant, and the conversion is where "every 4 months" and "every 122 days"
-- stop being obviously the same thing.
function DMKitDefs.claimText(def)
    local h = DMKitDefs.cooldownHours(def)
    if h <= 0 then return "any time" end
    if h < 24 then return "every " .. h .. " hr" end
    local days, rem = math.floor(h / 24), h % 24
    if rem == 0 then
        return "every " .. days .. (days == 1 and " day" or " days")
    end
    return "every " .. days .. "d " .. rem .. "h"
end

-- One stored number -> the two dials that build it, and back. Split out so the
-- form and any importer agree about which way round the arithmetic goes.
function DMKitDefs.splitCooldown(hours)
    local h = math.max(0, math.floor(tonumber(hours) or 0))
    return math.floor(h / 24), h % 24        -- days, hours
end

function DMKitDefs.joinCooldown(days, hours)
    local d = math.max(0, math.floor(tonumber(days) or 0))
    local h = math.max(0, math.floor(tonumber(hours) or 0))
    return d * 24 + h
end

-- Does anything about this kit depend on the player? A kit requiring nothing
-- can be offered without reading a single var, which is what lets the claim
-- list stay cheap on a busy server.
--
-- pairs(), never next() - B42's Kahlua registers no `next` global, so
-- `next(t) == nil` passes every fixture here and throws on a live server
-- (CLAUDE.md sect. 3).
function DMKitDefs.isUnconditional(def)
    if type(def) ~= "table" or type(def.requires) ~= "table" then return false end
    local r = def.requires
    return #(r.flags or {}) == 0 and #(r.counters or {}) == 0
end

-- ---------------------------------------------------------------------------
-- WHAT A KIT SHOWS
--
-- One projection, two audiences, and the ONLY difference between them is the
-- odds (owner, 2026-08-23: "contents always, odds only on the admin surface").
--
-- A player sees everything a kit can hand over, roulette branches included -
-- they are choosing whether to spend a one-time claim, and a sealed box is not
-- a choice. What they do not see is how the table is TUNED: a branch's weight
-- is the DM's dial, and publishing it turns "what might I get" into "what is
-- this worth farming". The admin surface gets both, because tuning a table you
-- cannot see the shape of is guesswork.
--
-- WEIGHTS ARE NORMALISED TO PERCENT for the admin, never passed raw. Authors
-- write 10 and 90, or 1 and 3, or 7 and 7 - all meaningful ratios and none of
-- them readable as a chance. The percentage is what a DM is actually asking
-- for when they look, and doing the division here means the two surfaces that
-- show it cannot disagree about how.
--
-- PICK > 1 IS STATED, NOT FOLDED IN. Drawing 2 of 5 makes each branch's real
-- chance higher than its share of the weight, and the arithmetic for "without
-- replacement" is not something to bury in a percentage nobody can check. The
-- row carries `pick` and the per-branch share; a surface says "2 of these".
--
-- Pure, engine-free, and it resolves NOTHING: an item type stays "Base.Axe",
-- a trait stays its registry id. Turning those into names and icons is the
-- client's job, done against its own script manager, so the wire stays small
-- and the display localises in the reader's language rather than the server's.
-- ---------------------------------------------------------------------------

local function contentRow(g)
    if type(g) ~= "table" then return nil end
    local kind = g.kind
    if kind == DMKitDefs.ITEM then
        return { kind = kind, ref = g.type, count = g.count or 1 }
    elseif kind == DMKitDefs.TRAIT then
        return { kind = kind, ref = g.id }
    elseif kind == DMKitDefs.XP then
        return { kind = kind, ref = g.perk, count = g.amount }
    end
    -- Flags and counters are BOOKKEEPING and are deliberately absent. They are
    -- how the suite remembers things about a character, and a claim panel
    -- listing "you will receive: the Delver flag" both means nothing to a
    -- player and advertises the substrate that gates everything else.
    return nil
end

function DMKitDefs.contents(def, withOdds)
    local out = {}
    for _, g in ipairs((type(def) == "table" and def.grants) or {}) do
        if g.kind == DMKitDefs.ROULETTE then
            local branches, total = {}, 0
            for _, b in ipairs(g.from or {}) do
                local w = tonumber(b.weight) or 0
                if w > 0 then total = total + w end
            end
            for _, b in ipairs(g.from or {}) do
                local rows = {}
                for _, inner in ipairs(b.grants or {}) do
                    local r = contentRow(inner)
                    if r then rows[#rows + 1] = r end
                end
                -- A branch whose every grant was bookkeeping still EXISTS as an
                -- outcome, and dropping it would make the odds of the visible
                -- ones read higher than they are.
                local entry = { rows = rows }
                if withOdds and total > 0 then
                    entry.percent = ((tonumber(b.weight) or 0) / total) * 100
                end
                branches[#branches + 1] = entry
            end
            if #branches > 0 then
                out[#out + 1] = { kind = DMKitDefs.ROULETTE,
                                  pick = g.pick or 1, branches = branches }
            end
        else
            local r = contentRow(g)
            if r then out[#out + 1] = r end
        end
    end
    return out
end

-- Every grant of one kind, flattened out of roulette branches. An authoring
-- surface listing "this kit can give you these traits" needs the branches
-- included; the claim path does not, and uses the roll instead.
function DMKitDefs.grantsOfKind(grants, kind)
    local out = {}
    for _, g in ipairs(grants or {}) do
        if g.kind == kind then
            out[#out + 1] = g
        elseif g.kind == DMKitDefs.ROULETTE then
            for _, b in ipairs(g.from or {}) do
                for _, inner in ipairs(DMKitDefs.grantsOfKind(b.grants, kind)) do
                    out[#out + 1] = inner
                end
            end
        end
    end
    return out
end

return DMKitDefs

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
