-- SPDX-License-Identifier: GPL-3.0-or-later
-- MMSnapshotCodec.lua - character snapshot <-> plain-table codec for the journal.
-- Single purpose: define WHAT a snapshot holds, HOW it is captured, how identity is
-- compared, and how a (chosen) config is applied. Shared so server (authority) and
-- owning client (mirror) run identical code.
--
-- Apply shapes (the memoir is the SOURCE OF TRUTH - reading overwrites the respawn build):
--   * OVERWRITE -> applyToCharacter(p, snap, {profession=..., traits=...}, "overwrite")
--                  identity/body/faith = snapshot; XP = memoir restore + this life's earnings
--   * LEGACY    -> applyToCharacter(p, snap, nil, "max") - pre-v4 books whose identity
--                  matches (could be the same life, so additive is unsafe): plain top-up.
--
-- Engine API notes (verified vs decompiled source):
--   * XP transfer = 5-arg AddXP(type, amount, callLua=false, doXPBoost=false,
--     remote=false); doXPBoost=false bypasses every multiplier so the raw number
--     lands build-independent. 2/3/4-arg overloads are isLocalPlayer no-ops server-side.
--   * Profession boosts live on SurvivorDesc.xpBoostMap (getPerkBoost reads it live):
--     setProfessionSkills(def) = clear()+putAll(boosts); it wipes the WHOLE map. Apply
--     order must mirror creation: strip old traits (their boosts subtract from the
--     LIVE map), then profession, then add new traits (boosts re-stack on top).
--   * A fresh spawn CARRIES raw XP for its granted levels: creation ends with
--     setXPToLevel(perk, level) (IsoGameCharacter.applyTraits), so a never-trained
--     skill's snapshot XP is pure grant XP - indistinguishable from earned XP unless
--     we recompute the grant. That recompute is buildGrantLevels below.
--   * getPerkBoost()/XPBoostMap is NOT the starting level: creation stores
--     Math.min(3, level) with the passive base folded in. Never use it for grant math.
--
-- THE GRANT RULE: grants follow the build being restored; only earned XP carries, and
-- only MEMOIR-earned XP is taxed by the restore knob:
--     savedEarned = max(0, savedXP - grantXP(saved build))    -- recovered from the book, taxed
--     newEarned   = max(0, curXP  - grantXP(respawn build))   -- this life's play, untaxed (never lost)
--     target      = grantXP(saved build) + savedEarned * pct + newEarned
-- Consequences: never below a fresh spawn of the saved build; the respawn build's
-- starting XP is dismissed with the build (write-at-spawn -> die -> remake cycles net
-- exactly zero - no min/max laundering); post-respawn grinding always survives the
-- read. Additive newEarned relies on the current life's state being ORGANIC play:
-- the same-life guard (life-id) refuses the writing life, and the one-recall-per-life
-- gate (MMServer, md.MMRecalled) refuses a second read - without it, two books from
-- the same dead life double-count everything they share, because the first read's
-- restoration is indistinguishable from this life's earnings. Legacy no-life-id
-- books fall back to non-additive "max".

require "MMSvShared"

MMSnapshotCodec = MMSnapshotCodec or {}

local function maxn(a, b) a = a or 0; b = b or 0; if a > b then return a end return b end

local function countSet(t)
    if type(t) ~= "table" then return 0 end
    local c = 0; for _ in pairs(t) do c = c + 1 end; return c
end
MMSnapshotCodec.countSet = countSet

-- The 5 weight traits (Underweight/Very Underweight/Emaciated/Overweight/Obese) are
-- DYNAMIC labels the engine adds/removes from body weight, not identity: Nutrition
-- .applyTraitFromWeight() wipes all 5 each tick and re-adds whichever matches the current
-- weight bracket. So we never snapshot them as traits - on restore they re-derive from the
-- restored weight (see capture / identityMatches / applyBodyState). Names are resolved from
-- the engine constants, so they always match getKnownTraits():get(i):getName().
local weightTraitNames
local function isWeightTrait(name)
    if not weightTraitNames then
        weightTraitNames = {}
        local consts = { CharacterTrait.UNDERWEIGHT, CharacterTrait.VERY_UNDERWEIGHT,
                         CharacterTrait.EMACIATED, CharacterTrait.OVERWEIGHT, CharacterTrait.OBESE }
        for _, c in ipairs(consts) do
            local ok, nm = pcall(function() return c and c:getName() end)
            if ok and nm then weightTraitNames[nm] = true end
        end
    end
    return weightTraitNames[name] == true
end
MMSnapshotCodec.isWeightTrait = isWeightTrait

-- ========================
-- Capture (server-side, on write)
-- ========================
function MMSnapshotCodec.capture(player)
    local snap = {
        schemaVersion = MMShared.SCHEMA_VERSION,
        epoch   = MMShared.WIPE_EPOCH, -- read refuses anything stamped older (amnesty gate)
        perks   = {},
        traits  = {},
        recipes = {},
        kills   = {},
    }

    for i = 0, PerkFactory.PerkList:size() - 1 do
        local perk = PerkFactory.PerkList:get(i)
        local t = perk:getType()
        if t ~= PerkFactory.Perks.None and t ~= PerkFactory.Perks.MAX then
            local xp = player:getXp():getXP(t)
            if xp and xp > 0 then snap.perks[perk:getId()] = xp end
        end
    end

    local known = player:getCharacterTraits():getKnownTraits()
    for i = 0, known:size() - 1 do
        local nm = known:get(i):getName()
        if not isWeightTrait(nm) then table.insert(snap.traits, nm) end -- weight traits re-derive from weight
    end

    local prof = player:getDescriptor() and player:getDescriptor():getCharacterProfession()
    snap.profession = prof and prof:getName() or nil

    local recipes = player:getKnownRecipes()
    for i = 0, recipes:size() - 1 do snap.recipes[recipes:get(i)] = true end

    snap.kills = { Zombie = player:getZombieKills() or 0, Survivor = player:getSurvivorKills() or 0 }

    -- BODY STATE: the full nutrition tuple, not just weight. The engine recomputes weight
    -- from the calorie/macro balance, so restoring weight alone would drift back - we capture
    -- and restore the whole tuple so the body genuinely "is" the saved character again.
    local nut = player.getNutrition and player:getNutrition()
    if nut then
        snap.nutrition = {
            weight   = nut:getWeight(),
            calories = nut:getCalories(),
            lipids   = nut:getLipids(),
            proteins = nut:getProteins(),
            carbs    = nut:getCarbohydrates(),
        }
    end

    -- FAITH (ParanormalZ): a custom modData stat - player:getModData().exorcistFaith, 0..120 -
    -- NOT a PerkFactory skill, so the perk loop above never sees it. Captured verbatim and
    -- restored in full (like nutrition), never scaled by the XP knob. Absent when ParanormalZ
    -- isn't installed -> snap.faith stays nil and restore skips it.
    local md = player:getModData()
    if md and md.exorcistFaith ~= nil then snap.faith = md.exorcistFaith end

    -- LIFE-ID: which life wrote this book. Stamped into player modData by the write
    -- path (once per life - death wipes player modData). On read, a matching id means
    -- the same life is reading its own history: the additive XP model would double it,
    -- so the read refuses instead.
    snap.lifeId = md and md.MMLifeId or nil

    MMlog("CAPTURE for " .. MMname(player) .. " | profession=" .. tostring(snap.profession)
        .. " traits=" .. tostring(#snap.traits) .. " recipes=" .. tostring(countSet(snap.recipes)))
    MMlogTable("  CAPTURE perks(raw XP)", snap.perks)
    MMlogTable("  CAPTURE traits", snap.traits)
    return snap
end

-- ========================
-- Identity comparison (server gate: match -> silent; mismatch -> reconcile)
-- ========================
-- Returns matches(bool), reason(string|nil), detail table for the reconcile UI.
function MMSnapshotCodec.identityMatches(player, snap)
    local curProf = player:getDescriptor() and player:getDescriptor():getCharacterProfession()
    local curProfName = curProf and curProf:getName() or nil

    -- Weight traits are excluded from the identity compare on BOTH sides: they track body
    -- weight, not character identity, so weight drifting across a bracket (e.g. you grind
    -- Underweight off) must NOT register as an identity mismatch / fire the reconcile GUI.
    -- (capture already drops them, but old v1 snapshots may still carry them - filter anyway.)
    local snapTraits, curTraits = {}, {}
    for _, n in ipairs(snap.traits or {}) do if not isWeightTrait(n) then snapTraits[n] = true end end
    local known = player:getCharacterTraits():getKnownTraits()
    for i = 0, known:size() - 1 do
        local nm = known:get(i):getName()
        if not isWeightTrait(nm) then curTraits[nm] = true end
    end

    local detail = {
        snapProfession = snap.profession, curProfession = curProfName,
        snapTraits = snap.traits or {}, curTraits = {},
        -- The actual identity diff (weight traits excluded), so the mismatch can be
        -- NAMED - every "it fired on an identical build" ticket is a diff the player
        -- can't see (mod-granted trait, stale memoir). Feeds the log and the offer.
        snapOnly = {}, curOnly = {},
    }
    for n in pairs(curTraits) do table.insert(detail.curTraits, n) end
    for n in pairs(snapTraits) do if not curTraits[n] then table.insert(detail.snapOnly, n) end end
    for n in pairs(curTraits) do if not snapTraits[n] then table.insert(detail.curOnly, n) end end
    table.sort(detail.snapOnly); table.sort(detail.curOnly)

    if curProfName ~= snap.profession then return false, "profession", detail end
    if #detail.snapOnly > 0 or #detail.curOnly > 0 then return false, "traits", detail end
    return true, nil, detail
end

-- ========================
-- Budget cost (server recomputes - never trust the client's number)
-- ========================
-- Total creation point cost of a profession + trait set. The legality threshold
-- (the pool rule vanilla creation uses) is enforced by the caller; this only sums.
function MMSnapshotCodec.budgetCost(professionName, traitNames)
    local total = 0
    local profDef = professionName and MMShared.findProfessionDefByName(professionName)
    if profDef and profDef.getCost then total = total + (profDef:getCost() or 0) end
    for _, name in ipairs(traitNames or {}) do
        local trait = MMShared.findTraitByName(name)
        if trait then
            local def = CharacterTraitDefinition.getCharacterTraitDefinition(trait)
            if def and def.getCost then total = total + (def:getCost() or 0) end
        end
    end
    return total
end

-- ========================
-- Apply: identity (only on reconcile) then earnables (always merge up)
-- ========================
local function applyIdentity(player, ident)
    -- 0) GUARD: if trait definitions can't resolve AT ALL on this side (dedi boot gap -
    -- nothing runs BaseGameCharacterDetails.DoTraits on a dedicated server), proceeding
    -- would strip every current trait and re-add none: a silent trait wipe. Abort with
    -- error() instead - the server dispatcher pcalls the apply and replies "applyfail",
    -- so the player is told and the memoir is NOT consumed.
    if ident.traits and #ident.traits > 0 and not MMShared.traitDefsReady() then
        error("MMSnapshotCodec.applyIdentity: trait definitions unavailable on this side")
    end
    -- 1) STRIP current traits FIRST, while the outgoing build's boosts are still
    -- what the map holds. modifyTraitXPBoost(trait, true) blindly SUBTRACTS that
    -- trait's boosts from whatever map is live (IsoGameCharacter.modifyTraitXPBoost
    -- has no memory of what the entry came from) - stripping AFTER the profession
    -- reset subtracted the respawn build's trait boosts from the freshly installed
    -- saved-profession boosts, leaving shrunken/negative entries and permanently
    -- wrong XP rates. Order must mirror creation: clean slate, profession, traits.
    local known = player:getCharacterTraits():getKnownTraits()
    local current = {}
    for i = 0, known:size() - 1 do current[#current + 1] = known:get(i) end
    for _, trait in ipairs(current) do
        player:getCharacterTraits():remove(trait)
        player:modifyTraitXPBoost(trait, true)
    end
    -- 2) PROFESSION (setProfessionSkills = clear()+putAll: wipes the whole boost
    -- map and installs the saved profession's boosts)
    if ident.profession then
        local def = MMShared.findProfessionDefByName(ident.profession)
        if def then
            player:getDescriptor():setCharacterProfession(def:getType())
            player:getDescriptor():setProfessionSkills(def)
            MMlog("  IDENTITY profession -> " .. tostring(ident.profession))
        else
            MMlog("  IDENTITY profession '" .. tostring(ident.profession) .. "' not found - left as-is")
        end
    end
    -- 3) TRAITS: add chosen (boosts stack on top of the profession's, like creation)
    for _, name in ipairs(ident.traits or {}) do
        local trait = MMShared.findTraitByName(name)
        if trait then
            player:getCharacterTraits():add(trait)
            player:modifyTraitXPBoost(trait, false)
        else
            MMlog("  IDENTITY trait '" .. tostring(name) .. "' not found - skipped")
        end
    end
    MMlog("  IDENTITY traits -> " .. tostring(#(ident.traits or {})) .. " trait(s)")
end

-- Free starting levels a build (profession + traits) grants per skill id. Mirrors
-- IsoGameCharacter.applyTraits EXACTLY, because that is what creation actually runs:
-- Fitness/Strength start from a hard-coded base 5 (NOT in any getXpBoosts map),
-- profession + each trait sum getXpBoosts() on top (negative boosts included), and
-- the final level clamps to 0..10. getTotalXpForLevel(these levels) is therefore the
-- raw XP a fresh spawn of this build carries (creation ends with setXPToLevel).
-- Known estimate limit: weight traits picked at creation aren't in our trait lists
-- (capture drops them - they're body state), so any xpBoost they carry is missed.
-- Vanilla weight traits carry none; worst case is a small shift in the grant/earned
-- split, never a broken floor.
function MMSnapshotCodec.buildGrantLevels(professionName, traitNames)
    local levels = { Fitness = 5, Strength = 5 } -- engine's passive base, pre-boost
    local function addBoosts(boostMap)
        if not boostMap then return end
        local t = transformIntoKahluaTable(boostMap)
        if type(t) ~= "table" then return end
        for perk, lvl in pairs(t) do
            local id
            local ok = pcall(function() id = perk:getId() end)
            if not ok or not id then id = tostring(perk) end
            levels[id] = (levels[id] or 0) + (tonumber(tostring(lvl)) or 0)
        end
    end
    local profDef = professionName and MMShared.findProfessionDefByName(professionName)
    if profDef then addBoosts(profDef:getXpBoosts()) end
    for _, name in ipairs(traitNames or {}) do
        local trait = MMShared.findTraitByName(name)
        if trait then
            local def = CharacterTraitDefinition.getCharacterTraitDefinition(trait)
            if def then addBoosts(def:getXpBoosts()) end
        end
    end
    for id, lvl in pairs(levels) do -- clamp like applyTraits (Math.max(0,..)/Math.min(10,..))
        if lvl < 0 then levels[id] = 0 elseif lvl > 10 then levels[id] = 10 end
    end
    return levels
end

-- The LIVE character's current build as plain data (profession name + trait names,
-- weight traits excluded - body state, not build). Captured BEFORE an identity
-- overwrite, so the respawn build's grants - XP levels AND recipes - can be
-- dismissed along with the build.
function MMSnapshotCodec.playerBuildIdentity(player)
    local prof = player:getDescriptor() and player:getDescriptor():getCharacterProfession()
    local traitNames = {}
    local known = player:getCharacterTraits():getKnownTraits()
    for i = 0, known:size() - 1 do
        local nm = known:get(i):getName()
        if not isWeightTrait(nm) then traitNames[#traitNames + 1] = nm end
    end
    return { profession = prof and prof:getName() or nil, traits = traitNames }
end

-- Grant levels of the live character's current build (see playerBuildIdentity).
function MMSnapshotCodec.playerBuildGrantLevels(player)
    local b = MMSnapshotCodec.playerBuildIdentity(player)
    return MMSnapshotCodec.buildGrantLevels(b.profession, b.traits)
end

-- Recipe grants of a build (profession + traits), from the same defs creation unions
-- (applyProfessionRecipes / applyCharacterTraitsRecipes). Granted recipes are
-- ABILITIES in B42 (Engineer explosives, etc.) - an identity overwrite must know the
-- respawn build's set to dismiss it.
function MMSnapshotCodec.buildGrantRecipes(professionName, traitNames)
    local granted = {}
    local function addList(list)
        if not list then return end
        for i = 0, list:size() - 1 do granted[list:get(i)] = true end
    end
    local profDef = professionName and MMShared.findProfessionDefByName(professionName)
    if profDef and profDef.getGrantedRecipes then addList(profDef:getGrantedRecipes()) end
    for _, name in ipairs(traitNames or {}) do
        local trait = MMShared.findTraitByName(name)
        if trait then
            local def = CharacterTraitDefinition.getCharacterTraitDefinition(trait)
            if def and def.getGrantedRecipes then addList(def:getGrantedRecipes()) end
        end
    end
    return granted
end

-- mode:
--   "overwrite" become the memoir (new-life read): memoir restore + XP earned on the
--               new body; the respawn build's starting grants are dismissed with the
--               build (may REDUCE, never below saved-build floor + this life's play)
--   "max"       legacy top-up bridge (pre-v4 books, identity match): never below current
--
-- Per skill (THE GRANT RULE, header):
--   savedEarned = max(0, savedXP - grantXP(saved build))       -- taxed by the knob
--   newEarned   = max(0, curXP  - grantXP(pre-read build))     -- this life's play, untaxed
--   overwrite: target = grantXP(saved) + savedEarned*pct + newEarned
--   max:       target = max(cur, grantXP(saved) + savedEarned*pct)
-- We scale RAW XP, never levels, so the engine re-derives the level from the total.
-- preSwapBuild = {profession, traits} worn BEFORE applyIdentity ran (caller captures
-- it; after the swap the "current build" IS the saved build and the info is gone).
local function applyEarnables(player, snap, mode, preSwapBuild, fullRestore, xpFraction)
    mode = mode or "max"
    local xp = player:getXp()
    local savedGrant = MMSnapshotCodec.buildGrantLevels(snap.profession, snap.traits)
    local preSwapGrant = preSwapBuild
        and MMSnapshotCodec.buildGrantLevels(preSwapBuild.profession, preSwapBuild.traits) or nil

    -- Precedence, resolved once where it cannot vary per perk: an explicit
    -- xpFraction (the Players tab dial) outranks fullRestore, which outranks the
    -- sandbox knob. Only the knob can differ per perk (Individual mode), so only
    -- that case is left inside the loop.
    --
    -- WHAT THE FRACTION ACTUALLY SCALES, because it is the most misread number in
    -- this subsystem: savedEarned ONLY - the XP earned ABOVE the saved build's
    -- grant floor. grantXP(saved) always restores in full, so no fraction, not
    -- even 0, can land a character below a fresh spawn of their own build. "60%"
    -- means "60% of what they earned", never "60% of their XP bar". That is the
    -- anti-laundering invariant in the header, and a fraction must not break it.
    local fixedPct = nil
    if type(xpFraction) == "number" then
        fixedPct = xpFraction
        if fixedPct < 0 then fixedPct = 0 elseif fixedPct > 1 then fixedPct = 1 end
    elseif fullRestore then
        -- Admin recovery with no dial supplied: bypass the restore knob entirely.
        -- The knob is a death tax, not a wipe tax - players are made whole.
        fixedPct = 1.0
    end

    for i = 0, PerkFactory.PerkList:size() - 1 do
        local perk = PerkFactory.PerkList:get(i)
        local t = perk:getType()
        if t ~= PerkFactory.Perks.None and t ~= PerkFactory.Perks.MAX then
            local id = perk:getId()
            local pct = fixedPct or MMShared.xpRestoreFraction(id)
            local cur = xp:getXP(t) or 0
            local rawSaved = (snap.perks and snap.perks[id]) or 0
            local savedGrantXP = perk:getTotalXpForLevel(savedGrant[id] or 0) or 0
            local savedEarned = rawSaved - savedGrantXP
            if savedEarned < 0 then savedEarned = 0 end
            local target
            if mode == "overwrite" then
                local preGrantXP = perk:getTotalXpForLevel((preSwapGrant and preSwapGrant[id]) or 0) or 0
                local newEarned = cur - preGrantXP
                if newEarned < 0 then newEarned = 0 end
                target = savedGrantXP + savedEarned * pct + newEarned
            else -- "max": legacy top-up, never below current
                target = savedGrantXP + savedEarned * pct
                if cur > target then target = cur end
            end
            local delta = target - cur
            if delta ~= 0 then
                local lvlB = player:getPerkLevel(t)
                xp:AddXP(t, delta, false, false, false)
                MMlog("  XP[" .. mode .. "] " .. id .. " " .. tostring(cur) .. "->" .. tostring(target)
                    .. " (lvl " .. tostring(lvlB) .. "->" .. tostring(player:getPerkLevel(t)) .. ")")
            end
        end
    end

    -- RECIPES - two halves of the same dismissal rule:
    -- 1) STRIP (overwrite only): the respawn build's GRANTED recipes are abilities
    --    (Engineer explosives, ...) - leaving them behind lets chef->die->engineer->read
    --    launder profession-locked recipes for free. Strip everything the respawn build
    --    granted unless the memoir itself carries it. knownRecipes is the live ArrayList
    --    (getKnownRecipes() returns the field; the engine has no unlearn API), so we call
    --    List.remove(recipeID) on it directly - repeatedly, because creation's addAll can
    --    hold duplicates (profession + trait granting the same recipe). Recipes auto-known
    --    from skill levels survive removal harmlessly (they're knowledge from skills,
    --    which the XP model already governs).
    local stripped = 0
    if mode == "overwrite" and preSwapBuild then
        local strip = MMSnapshotCodec.buildGrantRecipes(preSwapBuild.profession, preSwapBuild.traits)
        local list = player:getKnownRecipes()
        for recipeID in pairs(strip) do
            if not (snap.recipes and snap.recipes[recipeID]) then
                local guard, callFailed = 0, false
                while player:isRecipeActuallyKnown(recipeID) and guard < 5 do
                    local ok, removedOne = pcall(function() return list:remove(recipeID) end)
                    if not ok then callFailed = true; break end
                    if removedOne == false then break end -- not in the list (auto-known via skills)
                    guard = guard + 1
                end
                if guard > 0 then stripped = stripped + 1 end
                if callFailed then
                    MMwarn("recipe strip: List.remove not callable for '" .. tostring(recipeID)
                        .. "' - respawn-build recipe grants NOT stripped; report this")
                end
            end
        end
        MMlog("  RECIPES -" .. tostring(stripped) .. " respawn-build grant(s) dismissed")
    end

    -- 2) UNION: the memoir's recipes always come back in full (they ARE the saved character).
    local learned = 0
    for recipeID, _ in pairs(snap.recipes or {}) do
        if not player:isRecipeActuallyKnown(recipeID) then
            player:learnRecipe(recipeID); learned = learned + 1
        end
    end
    MMlog("  RECIPES +" .. tostring(learned) .. " of " .. tostring(countSet(snap.recipes)))

    -- KILLS: disjoint lives on overwrite -> additive (book's tally + this life's);
    -- legacy top-up -> max (same history may overlap, never add)
    if snap.kills then
        if mode == "overwrite" then
            player:setZombieKills((snap.kills.Zombie or 0) + (player:getZombieKills() or 0))
            player:setSurvivorKills((snap.kills.Survivor or 0) + (player:getSurvivorKills() or 0))
        else
            player:setZombieKills(maxn(snap.kills.Zombie, player:getZombieKills()))
            player:setSurvivorKills(maxn(snap.kills.Survivor, player:getSurvivorKills()))
        end
    end
end

-- BODY STATE: restore the saved nutrition tuple, then let the engine RE-DERIVE the weight
-- trait from the restored weight. Set-to-saved (never merged) - weight isn't earnable, it's
-- the body you respawn into; "same character, same body." Runs last so applyTraitFromWeight()
-- fires after any identity strip, leaving no window of a stale/missing weight trait.
local function applyBodyState(player, snap)
    local n = snap.nutrition
    if not n then return end -- v1 snapshot (pre-nutrition): nothing to restore
    local nut = player.getNutrition and player:getNutrition()
    if not nut then return end
    if n.weight   ~= nil then nut:setWeight(n.weight) end
    if n.calories ~= nil then nut:setCalories(n.calories) end
    if n.lipids   ~= nil then nut:setLipids(n.lipids) end
    if n.proteins ~= nil then nut:setProteins(n.proteins) end
    if n.carbs    ~= nil then nut:setCarbohydrates(n.carbs) end
    if nut.applyTraitFromWeight then nut:applyTraitFromWeight() end -- re-derive Underweight/Obese/etc
    MMlog("  BODY weight->" .. tostring(n.weight) .. " (+macros, weight trait re-derived)")
end

-- FAITH: restore the saved ParanormalZ exorcistFaith verbatim - full fidelity, never scaled
-- or merged ("the faith you had when you wrote it"). Skipped if the snapshot predates Faith
-- capture or ParanormalZ isn't present (snap.faith == nil). The server pushes the value to the
-- client via transmitModData (MMServer.pushFields); the owning client's mirror-apply also sets
-- it here, so the Faith UI updates immediately without waiting for the modData sync.
local function applyFaith(player, snap)
    if snap.faith == nil then return end
    local md = player:getModData()
    if not md then return end
    md.exorcistFaith = snap.faith
    MMlog("  FAITH -> " .. tostring(snap.faith))
end

-- chosenIdentity: table = overwrite identity from the snapshot; nil = keep (legacy "max").
-- xpMode: "overwrite" (memoir is the source of truth) | "max" (legacy top-up bridge)
-- fullRestore: true = admin disaster recovery - XP knob bypassed (100% restore).
-- xpFraction: optional 0..1 override (the Players tab's XP% dial), outranking
--   fullRestore. Scales EARNED xp only - see the note in applyEarnables.
--   BOTH SIDES MUST BE HANDED THE SAME VALUE. The server applies authoritatively
--   and the owning client mirror-applies the identical snapshot; if one runs at
--   1.0 and the other at 0.6 they compute different targets and the character
--   desyncs until relog. MMRestore puts it in applyData, MMClient reads it back.
function MMSnapshotCodec.applyToCharacter(player, snap, chosenIdentity, xpMode, fullRestore, xpFraction)
    if not snap then return end
    MMlog("APPLY to " .. MMname(player) .. " | xpMode=" .. tostring(xpMode or "max")
        .. (chosenIdentity and " (overwrite identity)" or " (keep identity)")
        .. (type(xpFraction) == "number"
            and string.format(" (xp %d%% of earned)", math.floor(xpFraction * 100 + 0.5))
            or (fullRestore and " (FULL restore, knob bypassed)" or "")))
    -- The dismissal rule needs the build the player is wearing BEFORE the identity
    -- swap (its XP grants AND its granted recipes) - capture it first; applyIdentity
    -- rewrites it and the information is gone.
    local preSwapBuild = (xpMode == "overwrite")
        and MMSnapshotCodec.playerBuildIdentity(player) or nil
    if chosenIdentity then applyIdentity(player, chosenIdentity) end
    applyEarnables(player, snap, xpMode, preSwapBuild, fullRestore, xpFraction)
    applyBodyState(player, snap)
    applyFaith(player, snap)
end

return MMSnapshotCodec

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
