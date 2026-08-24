-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMKits - the kit catalogue and the claim ledger (server only).
--
-- Two documents, and they could not be less alike. The CATALOGUE is what a DM
-- authored: cold, rare, precious, and the half worth restoring after a wipe.
-- The LEDGER is who has claimed what: hot, and deliberately NOT restored across
-- a wipe, because handing back "already claimed" on a fresh world would lock
-- every player out of every one-time reward on a map they have never seen.
-- RDConfigStore already draws that line - defs are exported on every edit,
-- state is batched and save-scoped - so this file only has to put each half in
-- the right place.
--
-- ---------------------------------------------------------------------------
-- WHY THE LEDGER IS NOT A VAR, which was the first design and was wrong.
--
-- "Has claimed kit X" reads like a flag, and RDVars is right there. But fifty
-- kits across two hundred players is ten thousand var records all meaning
-- "yes", every one of them needing a definition an admin has to create first,
-- and all of them cluttering the var list that quests and doors actually read.
-- Claim bookkeeping is this system's own business. The var namespace stays for
-- facts OTHER systems read.
--
-- The traffic goes the other way instead: a flag declares its own
-- revokers.kit, and this file honours it at claim time by walking the var
-- definitions. That direction is already RDVars' contract - see RDVars.lua:220
-- - and it is why a kit definition has no "consumes" field. Two places naming
-- one fact is how they drift.
--
-- ---------------------------------------------------------------------------
-- ABSENT IS NOT ZERO, and a counter requirement honours that.
--
-- RDVars keeps flags and counters in separate tables precisely so "never
-- touched" and "set to zero" stay distinguishable, and RDVars.get answers an
-- untouched counter with nil rather than 0. So a player with no Samples counter
-- does not meet `atLeast = 0`; they meet nothing about Samples at all, and the
-- refusal says so in those words. That makes `atLeast = 0` a real requirement -
-- "has engaged with this at all" - rather than a no-op, and it keeps a
-- requirement from quietly passing for every player on the server.
--
-- ---------------------------------------------------------------------------
-- EDITING A KIT DOES NOT CLEAR ITS CLAIMS, and the revision number is why.
--
-- A DM fixing a typo must not re-open a one-time reward to everyone who already
-- took it, so claims survive an edit. But a recorded roulette result is a set
-- of BRANCH INDICES, and editing the branches moves what those indices mean.
-- Every definition therefore carries a `rev` that increments on each save, the
-- ledger records the rev it was claimed under, and a recorded roll from an
-- older rev is reported as stale rather than resolved into branches that have
-- since changed places. Re-opening a kit is an explicit act - forgetClaims -
-- rather than a side effect of editing one.

if not isServer() then return end

require "RDShared"
require "RDConfigStore"
require "RDVars"
require "RDVarDefs"
require "DMKitDefs"
require "DMRegistry"

DMKits = DMKits or {}

local ensure = RDConfigStore.lazy{
    modKey    = "RFTDKits",
    defsFile  = RDShared.DIR .. "kits-defs"   .. RDShared.EXT_DOC,
    stateFile = RDShared.DIR .. "kits-claims" .. RDShared.EXT_DOC,
    flushMs   = 30000,
    label     = "RFTDDungeonMaster",
}

-- Exposed for the admin surface and for fixtures. Nothing else should reach
-- past the API below into the raw tables.
function DMKits.store() return ensure() end

-- THE CATALOGUE IS MIGRATED ON FIRST READ, once per load. Two kits are live
-- on Mosaic carrying the old `claim = { once = ... }` policy, and every reader
-- below - the entitlement gate, the wire, the authoring tab - would otherwise
-- see a definition with no cooldownHours in it and treat it as having no wait.
-- normalizeClaim is idempotent, so this is safe to run against an already
-- current document; it simply changes nothing.
--
-- NO once-only FLAG GUARDING THIS. The walk is over a catalogue of kits - tens,
-- not thousands - it is idempotent, and it disables itself: once a policy has
-- been rewritten it no longer carries `once`, so the next pass finds nothing
-- and touches nothing. A run-once flag would buy a loop this small at the cost
-- of a branch no fixture can reach.
local function catalogue()
    local defs = ensure():defs()
    local touched = 0
    for _, def in pairs(defs) do
        if type(def) == "table" and type(def.claim) == "table"
            and def.claim.once ~= nil then
            def.claim = DMKitDefs.normalizeClaim(def.claim)
            touched = touched + 1
        end
    end
    if touched > 0 then
        ensure():touchDefs()
        print("[RFTDDungeonMaster] kits: migrated " .. touched
            .. " claim policy/policies to hours")
    end
    return defs
end
-- THE STATE DOCUMENT HAS TWO HALVES, and the split is here rather than a
-- reserved key inside the player map for the reason RDVars learned the hard
-- way: any sentinel ("__log", "") is a username somebody can hold, and the
-- collision would silently merge one player's claims into the log.
--
-- THE MIGRATION IS LIVE, not theoretical. Kits were authored and claimed on
-- Mosaic before this split existed (owner, 2026-08-23), so a flat document -
-- every top-level table a player record - is a real thing on disk right now.
-- Everything that is not the log half moves under `players` on first read,
-- once, and the log starts empty beside it. Claims made before the log existed
-- therefore have no lines, which is correct: the log records claims as they
-- happen and cannot invent a past it did not watch.
local function stateDoc()
    local st = ensure():state()
    if not st.players then
        local moved = {}
        for k, v in pairs(st) do
            if k ~= "log" and type(v) == "table" then moved[k] = v end
        end
        for k in pairs(moved) do st[k] = nil end
        st.players = moved
    end
    st.log = st.log or {}
    return st
end

local function ledger()  return stateDoc().players end
local function claimLog() return stateDoc().log    end

-- Core's, not a copy: the ledger is keyed by exactly the same identity RDVars
-- keys flags by, and two rules for "what counts as a player" is how a kit
-- ends up recorded against a name a var lookup cannot find.
local userKey = RDShared.username

-- ---------------------------------------------------------------------------
-- Defining a kit
--
-- Three gates, in widening order of cost: the SHAPE (DMKitDefs, pure), the
-- WORLD (DMRegistry - do these items, traits and skills exist), and the VARS
-- (RDVars - are these flags and counters defined, and of the right kind).
-- All three run at SAVE time. Every registry involved answers an unknown id
-- with a quiet miss, so a kit that skipped these would not fail at claim - it
-- would succeed and hand over less than it said.
-- ---------------------------------------------------------------------------

-- The var half, which DMRegistry deliberately leaves alone because RDVars is
-- server-only and DMRegistry is shared.
local function checkVars(def)
    local function checkOne(name, wantKind, where)
        local vd = RDVars.definition(name)
        if not vd then
            return nil, where .. ": no var named '" .. name .. "' is defined - "
                .. "define it on the Vars tab first"
        end
        if vd.kind ~= wantKind then
            return nil, where .. ": '" .. vd.name .. "' is a " .. vd.kind
                .. " var, not a " .. wantKind
        end
        return true
    end

    for i, g in ipairs(DMKitDefs.grantsOfKind(def.grants, DMKitDefs.FLAG)) do
        local ok, why = checkOne(g.name, RDVarDefs.FLAG, "flag grant " .. i)
        if not ok then return nil, why end
    end
    for i, g in ipairs(DMKitDefs.grantsOfKind(def.grants, DMKitDefs.COUNTER)) do
        local ok, why = checkOne(g.name, RDVarDefs.COUNTER, "counter grant " .. i)
        if not ok then return nil, why end
    end
    for i, name in ipairs(def.requires.flags) do
        local ok, why = checkOne(name, RDVarDefs.FLAG, "requires.flags " .. i)
        if not ok then return nil, why end
    end
    for i, c in ipairs(def.requires.counters) do
        local ok, why = checkOne(c.name, RDVarDefs.COUNTER, "requires.counters " .. i)
        if not ok then return nil, why end
    end
    return true
end

-- Returns the stored definition, or (nil, reason). `by` is the admin who saved
-- it, kept for "who wrote this and when". Saving over an existing id is an
-- EDIT: it keeps the claims and bumps the revision.
function DMKits.define(rawDef, by)
    local def, why = DMKitDefs.validate(rawDef)
    if not def then return nil, why end

    local ok
    ok, why = DMRegistry.checkGrants(def.grants)
    if not ok then return nil, why end

    ok, why = checkVars(def)
    if not ok then return nil, why end

    local c = catalogue()
    local previous = c[def.id]

    def.rev = (previous and previous.rev or 0) + 1
    def.at  = RDShared.nowMs()
    def.by  = by

    c[def.id] = def
    ensure():touchDefs()
    return def
end

-- Removing a kit does NOT remove its claims: an id that comes back is the same
-- kit as far as anyone claiming it is concerned, and silently re-opening a
-- one-time reward because a DM deleted and retyped it is the kind of exploit
-- nobody notices until it has been used. forgetClaims is the explicit way.
function DMKits.undefine(id)
    local key, why = DMKitDefs.normalizeId(id)
    if not key then return nil, why end
    local c = catalogue()
    if not c[key] then
        return nil, "no kit called '" .. tostring(id) .. "'"
    end
    c[key] = nil
    ensure():touchDefs()
    return true
end

function DMKits.definition(id)
    local key = DMKitDefs.normalizeId(id)
    return key and catalogue()[key] or nil
end

-- Sorted by id so an admin list is stable between calls - pairs() order is not.
function DMKits.definitions()
    local out = {}
    for _, def in pairs(catalogue()) do out[#out + 1] = def end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- ---------------------------------------------------------------------------
-- The claim ledger
-- ---------------------------------------------------------------------------

local function claims(user, create)
    local l = ledger()
    local r = l[user]
    if not r and create then
        r = {}
        l[user] = r
    end
    return r
end

-- How many times has this player claimed this kit, and what happened the last
-- time. Returns (count, record) - count is 0 and record nil for a kit they have
-- never taken, which is deliberately distinguishable from a record with n = 0
-- that should never exist.
function DMKits.claimCount(subject, id)
    local user = userKey(subject)
    local key = DMKitDefs.normalizeId(id)
    if not user or not key then return 0, nil end
    local r = claims(user, false)
    local rec = r and r[key]
    if not rec then return 0, nil end
    return rec.n or 0, rec
end

function DMKits.hasClaimed(subject, id)
    local n = DMKits.claimCount(subject, id)
    return n > 0
end

-- What did this player actually get last time? Returns (rolls, stale) where
-- `rolls` maps a grant index to the branch indices drawn, or nil if they have
-- never claimed it.
--
-- `stale` is true when the kit has been edited since - the indices still exist
-- but no longer point at the same branches, so a caller must report "an earlier
-- version of this kit" rather than resolve them and confidently name the wrong
-- prize. This is the whole reason a definition carries a revision.
function DMKits.lastRoll(subject, id)
    local _, rec = DMKits.claimCount(subject, id)
    if not rec then return nil end
    local def = DMKits.definition(id)
    local stale = not def or rec.rev ~= def.rev
    return rec.rolls or {}, stale
end

-- ---------------------------------------------------------------------------
-- Entitlement
--
-- "May this player claim this kit right now", and WHY NOT when the answer is
-- no. The reason is written for an ADMIN - it names the flag or the counter
-- and the shortfall. A player-facing surface must not repeat it verbatim, or
-- the requirement list of every unearned kit is readable by anyone who clicks;
-- deciding how much to reveal belongs to the caller, which is why this returns
-- detail rather than a sanitized string.
-- ---------------------------------------------------------------------------

-- Milliseconds until this player may claim this kit again: 0 when they may
-- take it now, a positive number while they wait, and nil when the kit has no
-- cooldown at all. Split out because three callers ask - the entitlement gate,
-- the claim panel's countdown, and the admin summary - and a second copy of
-- this arithmetic is a kit that is claimable to one of them and not the other.
--
-- SIGNED, deliberately, exactly as RDVars' expiry is. The stamp is a wall
-- clock (RDShared.nowMs) and an NTP correction can step it backwards, which
-- makes `elapsed` negative and the remaining LONGER. That errs toward making a
-- player wait, never toward handing out a free extra claim - which is the
-- right way round for a gate, and the opposite of the way RDVars breaks the
-- same tie for an expiry that TAKES something away.
function DMKits.cooldownLeft(subject, id)
    local def = DMKits.definition(id)
    local ms = DMKitDefs.cooldownMs(def)
    if not ms then return nil end
    local _, rec = DMKits.claimCount(subject, id)
    if not rec or not rec.at then return 0 end
    local left = ms - (RDShared.nowMs() - rec.at)
    if left < 0 then left = 0 end
    return left
end

function DMKits.entitlement(subject, id)
    local user = userKey(subject)
    if not user then return false, "no player" end

    local def = DMKits.definition(id)
    if not def then
        return false, "no kit called '" .. tostring(id) .. "'"
    end

    -- There is no once-ever branch any more: a kit meant to be taken once
    -- carries a wait longer than the season, and the ledger clears on a wipe
    -- regardless (owner, 2026-08-24). One gate, one number.
    --
    -- The cooldown is checked BEFORE the requirements, and the order matters
    -- for what the refusal says: a player waiting on a kit they have already
    -- earned should be told about the wait, not told they are missing a flag
    -- they might also happen to have lost since.
    local left = DMKits.cooldownLeft(user, def.id)
    if left and left > 0 then
        return false, user .. " claimed '" .. def.label .. "' too recently - "
            .. math.ceil(left / 60000) .. " more minute(s)", left
    end

    for _, name in ipairs(def.requires.flags) do
        if not RDVars.has(user, name) then
            local vd = RDVars.definition(name)
            return false, user .. " does not hold '"
                .. ((vd and vd.name) or name) .. "'"
        end
    end

    for _, c in ipairs(def.requires.counters) do
        local vd = RDVars.definition(c.name)
        local label = (vd and vd.name) or c.name
        local value = RDVars.get(user, c.name)
        -- Absent is not zero. See the header: RDVars answers an untouched
        -- counter with nil on purpose, and collapsing that into 0 here would
        -- undo the distinction the whole var system is shaped around.
        if value == nil then
            return false, user .. " has no '" .. label .. "' counter at all"
        end
        if value < c.atLeast then
            return false, user .. " has " .. tostring(value) .. " '" .. label
                .. "', needs " .. tostring(c.atLeast)
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Recording a claim
--
-- Called by the claim path AFTER the grants have actually landed, never before:
-- a ledger entry written first would mark a one-time kit spent even if every
-- grant failed. `rolls` maps a grant index to the branch indices DMRoll drew,
-- and is stored alongside the revision it was drawn against.
-- ---------------------------------------------------------------------------

function DMKits.recordClaim(subject, id, rolls, by)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local def = DMKits.definition(id)
    if not def then
        return nil, "no kit called '" .. tostring(id) .. "'"
    end

    local r = claims(user, true)
    local rec = r[def.id]
    if not rec then
        rec = { n = 0 }
        r[def.id] = rec
    end

    rec.n     = (rec.n or 0) + 1
    rec.at    = RDShared.nowMs()
    rec.rev   = def.rev
    rec.rolls = rolls or {}
    rec.by    = by

    DMKits.logClaim{
        at    = rec.at,
        id    = def.id,
        label = def.label or def.id,
        user  = user,
        by    = by,
    }

    ensure():touchState()
    return rec
end

-- ---------------------------------------------------------------------------
-- The claim log
--
-- WHO TOOK WHAT, WHEN - one line per claim, which the per-player ledger cannot
-- answer. That record collapses every claim of a kit into a count and a LAST
-- time, deliberately, because its job is "may they take it again". A log is
-- the other question, asked by a staff member after the fact: what happened
-- here, in order.
--
-- BOUNDED, and the bound is not negotiable. This rides in the save document, so
-- an unbounded list is a file that grows for the life of a server and takes the
-- claim ledger down with it when it finally becomes unwritable. LOG_MAX is a
-- window, not an archive; the forensic stream (DM.KIT_CLAIMED, already written
-- on every claim) is the archive, and it rotates on its own terms.
--
-- NEWEST FIRST, because every reader of this wants the last thing that
-- happened, and a surface that has to reverse a list to be useful invites two
-- surfaces that disagree about order.
-- ---------------------------------------------------------------------------

DMKits.LOG_MAX = 250

-- `items` is the delivery summary the grant path produced - prose, already
-- textSafe'd by its caller. It is written SEPARATELY from the rest of the line
-- (see attachDelivery) because what landed is not known until after the grants
-- run, and the claim is recorded first so a mid-delivery failure still leaves
-- the claim on the books.
function DMKits.logClaim(entry)
    if type(entry) ~= "table" then return nil end
    local log = claimLog()
    table.insert(log, 1, {
        at    = entry.at or RDShared.nowMs(),
        id    = entry.id,
        label = entry.label,
        user  = entry.user,
        by    = entry.by,
        items = entry.items,
    })
    while #log > DMKits.LOG_MAX do table.remove(log) end
    return log[1]
end

-- Fill in what actually landed, on the line just written. Matched by position
-- rather than by id: the newest line IS this claim, because recordClaim wrote
-- it a few statements ago on the same server thread and nothing else can have
-- claimed in between.
function DMKits.attachDelivery(user, id, items)
    local log = claimLog()
    local top = log[1]
    if not top or top.user ~= user or top.id ~= id then return false end
    top.items = items
    ensure():touchState()
    return true
end

-- The newest `limit` lines, copied. A caller gets its own tables so a wire
-- handler cannot hand the store's own rows to the serializer and have them
-- mutated underneath it.
function DMKits.log(limit)
    local n = tonumber(limit) or DMKits.LOG_MAX
    if n < 1 then n = 1 end
    if n > DMKits.LOG_MAX then n = DMKits.LOG_MAX end
    local src, out = claimLog(), {}
    for i = 1, math.min(n, #src) do
        local e = src[i]
        out[i] = { at = e.at, id = e.id, label = e.label,
                   user = e.user, by = e.by, items = e.items }
    end
    return out
end

-- How many times each kit has been claimed, over everyone. ONE walk of the
-- ledger answering every row of the admin list at once - the alternative is
-- claimants() per kit, which is the same walk repeated once per kit for a
-- number that fits in a corner of a row.
--
-- Returns a map keyed by kit id; a kit nobody has taken is simply absent, and
-- a caller renders that as 0. Kits that no longer exist still count here, and
-- that is correct: the ledger outlives a deleted definition on purpose, which
-- is the whole reason re-opening a kit is an explicit act.
function DMKits.claimTotals()
    local out = {}
    for _, r in pairs(ledger()) do
        for id, rec in pairs(r) do
            out[id] = (out[id] or 0) + (rec.n or 0)
        end
    end
    return out
end

-- Every player who has claimed this kit, for the admin surface. Sorted by
-- username so the list is stable between calls.
function DMKits.claimants(id)
    local key, why = DMKitDefs.normalizeId(id)
    if not key then return nil, why end
    local out = {}
    for user, r in pairs(ledger()) do
        local rec = r[key]
        if rec then
            out[#out + 1] = { user = user, n = rec.n or 0, at = rec.at,
                rev = rec.rev, by = rec.by }
        end
    end
    table.sort(out, function(a, b) return a.user < b.user end)
    return out
end

-- Re-open a kit. An EXPLICIT admin act rather than a side effect of editing or
-- deleting one, because the failure mode is silent: everybody who already took
-- a one-time reward can take it again and nothing says so.
--
-- Returns the number of players whose claim was cleared.
-- Clear ONE player's claim on ONE kit. The lost-packet case, and it is not
-- hypothetical: a claim is recorded before the grants run, so a delivery that
-- dies mid-flight leaves a player charged for something they never received
-- and - on a once-ever kit - locked out permanently with no way back
-- (owner, 2026-08-24).
--
-- A SEPARATE VERB FROM forgetClaims, never the same one with an optional user.
-- The two acts differ by two hundred players, and a `user` field that failed to
-- serialise would silently promote "give Kriegan his axe back" into "re-open
-- this reward for the entire server". A missing user here is a refusal.
--
-- Returns (true, hadClaims) or (nil, reason). `hadClaims` is false when there
-- was nothing to clear, which the caller reports rather than dressing up as a
-- success - "cleared" for a player who never claimed it hides a typo'd name.
function DMKits.forgetClaim(subject, id)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local key, why = DMKitDefs.normalizeId(id)
    if not key then return nil, why end
    local r = claims(user, false)
    if not r or not r[key] then return true, false end
    r[key] = nil
    ensure():touchState()
    return true, true
end

function DMKits.forgetClaims(id)
    local key, why = DMKitDefs.normalizeId(id)
    if not key then return nil, why end
    local cleared = 0
    for _, r in pairs(ledger()) do
        if r[key] then
            r[key] = nil
            cleared = cleared + 1
        end
    end
    if cleared > 0 then ensure():touchState() end
    return cleared
end

-- Everything one player has claimed, as a COPY - an admin panel holding a
-- reference to the store's own record can mutate it by rendering.
function DMKits.claimsOf(subject)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local r = claims(user, false) or {}
    local out = {}
    for kitId, rec in pairs(r) do
        local def = DMKits.definition(kitId)
        out[#out + 1] = {
            id    = kitId,
            label = def and def.label or kitId,
            n     = rec.n or 0,
            at    = rec.at,
            stale = (not def) or rec.rev ~= def.rev,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- ---------------------------------------------------------------------------
-- The flags a claim consumes
--
-- Declared on the VAR, not on the kit - see the header. This answers "which
-- flags say they are spent by this kit", so the claim path can revoke them
-- without either side carrying a copy of the other's list.
-- ---------------------------------------------------------------------------

function DMKits.consumedBy(id)
    local key = DMKitDefs.normalizeId(id)
    if not key then return {} end
    local out = {}
    for _, vd in ipairs(RDVars.definitions()) do
        if vd.kind == RDVarDefs.FLAG and vd.revokers
            and vd.revokers.kit == key then
            out[#out + 1] = vd.key
        end
    end
    return out
end

return DMKits

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
