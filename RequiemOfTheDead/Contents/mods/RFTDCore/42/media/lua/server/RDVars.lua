-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDVars.lua - player variables: who holds what, and for how long (server only).
--
-- The substrate Kits and Quests are built on. The game has no way to express
-- "this character attended the Anomaly event" or "has collected 5 of 10
-- samples": setVariable is animation state, and player modData is forgeable by
-- the client that owns it (ObjectModDataPacket, gated only on
-- Capability.LoginOnServer). So this exists, and it is server-authoritative by
-- construction - see RDConfigStore's header for why ModData is the one store a
-- client cannot reach.
--
-- ---------------------------------------------------------------------------
-- ADMINISTRATIVE BACKEND. NOT A PLAYER-FACING SYSTEM.
--
-- Decided 2026-08-22 and stated here because it is the kind of boundary that
-- erodes by accident: **vars are never exposed to players.** No wire token, no
-- per-player push, no client module, no tooltip, no chat reply that reads a var
-- back. A player learns they were part of something by what a kit gives them,
-- not by inspecting a flag.
--
-- This is why there is no client half of this file, and it is not an oversight
-- or a deferral - the absence IS the design. Anything that needs vars on a
-- client is a change of that decision, not an extension of it.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FILE DOES NOT DO. Vars hold INFORMATION. No thresholds, no
-- triggers, no events fired when a counter crosses a line. Consumers read
-- values and decide what they mean, which is what keeps Core ignorant of what
-- a quest is (CLAUDE.md sect. 12). Of the three revokers a definition can
-- carry, this file evaluates exactly the two it can without domain knowledge -
-- `expires` (it has a clock) and `death` (it has the event). `kit` is opaque:
-- the kit system calls revoke() when that kit is claimed.
--
-- ---------------------------------------------------------------------------
-- KEYED BY USERNAME, which is the suite's identity model everywhere - Memoir
-- gates on it, RCRegistry keys claims by it, resolveTarget resolves by it. It
-- also survives a display-name change, and it is the one identifier that is
-- exact: a 17-digit SteamID exceeds 2^53 and flattens through a Lua double, so
-- two accounts can compare equal (RDIdentity.lua:9-14).
--
-- ---------------------------------------------------------------------------
-- DEATH IS ITS OWN LISTENER, deliberately not folded into RDLife's. RDLife
-- owns the family's death CAPTURE and its handler sits behind
-- SandboxVars.RFTDCore.DeathCaptureEnabled - a switch for chronicle logging.
-- Binding var lifecycle to it would mean an admin turning off logging silently
-- stops resetOnDeath from working, and nothing would say so. Two listeners on
-- one event is not duplication when they have opposite kill-switch semantics;
-- the engine wraps each listener in its own try/catch anyway
-- (Event.java:53-63), so they cannot affect each other.
--
-- OnPlayerDeath is NOT usable here: IsoPlayer.OnDeath returns early under
-- GameServer.server before firing it (IsoPlayer.java:6110-6122).
-- OnCharacterDeath fires from super.OnDeath() (IsoGameCharacter.java:4589) and
-- is the only reachable hook - but it fires for zombies and animals too, so
-- the player test is the first statement and does not allocate.

if not isServer() then return end

require "RDShared"
require "RDVarDefs"
require "RDConfigStore"

RDVars = RDVars or {}

-- One store, two documents. defs are cold and precious - what a var IS, the
-- half an admin wants back after a wipe. state is hot and deliberately NOT
-- restored across one: handing back flags players already spent their kit
-- claims on is the exploit the save-scoping exists to prevent.
local ensure = RDConfigStore.lazy{
    modKey    = "RFTDVars",
    defsFile  = RDShared.DIR .. "vars-defs"  .. RDShared.EXT_DOC,
    stateFile = RDShared.DIR .. "vars-state" .. RDShared.EXT_DOC,
    flushMs   = 30000,
    label     = "RFTDCore",
}

-- Exposed for the admin surface and for fixtures. Nothing else should reach
-- past the API below into the raw tables.
function RDVars.store() return ensure() end

local function defs()  return ensure():defs()  end
local function state() return ensure():state() end

-- ---------------------------------------------------------------------------
-- THE STATE DOCUMENT HAS TWO HALVES since 2026-08-23:
--
--   state.players[user] = { flags = {}, numbers = {} }
--   state.world[key]    = number
--
-- World counters could not simply take a reserved key in the player map. A
-- player record and a world value are different shapes, the map is keyed by
-- whatever string the engine reports as a username, and any sentinel picked
-- here - "__world", "" - is a username somebody can eventually hold. The
-- collision would not throw; record() would hand back the number map and
-- immediately give it a `flags` table.
--
-- THE MIGRATION IS ONE-WAY AND RUNS ONCE, on the first read of a document
-- written before the split. Everything at the top level that is a table and is
-- not the world half was a player record, because that is the only thing the
-- old shape held. Discarding it instead was not an option: this document holds
-- flags players earned, and state is already the half that does not come back
-- after a wipe (see the store spec above) - losing it twice over is not a
-- migration, it is the bug the scoping was meant to avoid.
--
-- ONE shape check, reached through BOTH accessors. Splitting it would make the
-- migration depend on which half of the document a caller happened to touch
-- first, and which call comes first in a session is not something this file
-- gets to decide.
local function ensureShape()
    local st = state()
    if not st.players then
        -- Collected first, cleared second, assigned third. Adding a NEW key to
        -- a table being traversed is undefined in Lua 5.1; clearing existing
        -- ones during traversal is explicitly allowed.
        --
        -- `world` is skipped by name because a half-migrated document is real:
        -- one written by a build that had world counters and re-read after the
        -- players half was lost would otherwise file the world map as a player
        -- named "world", complete with a flags table.
        local moved = {}
        for k, v in pairs(st) do
            if k ~= "world" and type(v) == "table" then moved[k] = v end
        end
        for k in pairs(moved) do st[k] = nil end
        st.players = moved
    end
    st.world = st.world or {}
    return st
end

local function players()     return ensureShape().players end
local function worldValues() return ensureShape().world   end

-- A player's record, created on demand. `flags` are the markers a player
-- holds, with provenance; `numbers` are counters. Kept as two tables rather than one tagged map so
-- "absent" and "zero" can never be confused - see RDVarDefs' header.
local function record(username, create)
    local s = players()
    local r = s[username]
    if not r and create then
        r = { flags = {}, numbers = {} }
        s[username] = r
    end
    if r then
        r.flags   = r.flags   or {}
        r.numbers = r.numbers or {}
    end
    return r
end

-- Resolve a name to (key, def) or (nil, reason). Every public call starts here,
-- so an undefined var is refused once, in one place, with one message.
local function resolve(name, wantKind)
    local key, why = RDVarDefs.normalizeName(name)
    if not key then return nil, why end
    local def = defs()[key]
    if not def then
        return nil, "no var named '" .. tostring(name) .. "' is defined"
    end
    if wantKind and def.kind ~= wantKind then
        return nil, "'" .. def.name .. "' is a " .. def.kind
            .. " var - " .. (wantKind == RDVarDefs.FLAG
                and "grant/revoke/has are for flags"
                or  "get/set/add/reset are for counters")
    end
    return key, def
end

-- Moved to RDShared on 2026-08-23, when DMKits needed the same rule and a
-- second copy would have been two chances for "what counts as a player" to
-- drift. Aliased rather than called through, because ten call sites below read
-- better with the short name.
local userKey = RDShared.username

-- ---------------------------------------------------------------------------
-- The owner mirror's seam
--
-- ONE listener, notified with a username after any change to that player's
-- record. RDVarsPush subscribes and replicates the player's own document to
-- their client; this file stays wire-free, which is what keeps its fixture
-- pure. World counter writes notify nobody - they are in nobody's mirror.
-- A verb that changed nothing (reset of an absent counter, a refused revoke)
-- does not notify: a push per no-op would be wire spent restating the truth.
-- ---------------------------------------------------------------------------
RDVars.onTouched = nil

local function notifyTouched(user)
    local fn = RDVars.onTouched
    if fn then fn(user) end
end

-- Milliseconds until this holding expires: positive = still live, <= 0 =
-- expired, nil = never expires. THE one expression of the expiry rule - has(),
-- sweep() and mirrorOf() all ask it, so a permission can never be expired to
-- one reader and live to another.
--
-- Signed, deliberately (see the Expiry section header): a backwards clock step
-- makes `now - at` negative, so the remaining GROWS past ms rather than going
-- negative - a live grant can never expire early off an NTP correction.
local function remainingMs(ms, at, now)
    if not ms or not at then return nil end
    return ms - (now - at)
end

-- ---------------------------------------------------------------------------
-- Definitions
-- ---------------------------------------------------------------------------

-- Returns the stored definition, or (nil, reason). `by` is the admin who
-- created it, kept for the audit question "who added this and when".
function RDVars.define(rawDef, by)
    local def, why = RDVarDefs.validate(rawDef)
    if not def then return nil, why end

    local d = defs()
    local existing = d[def.key]
    if existing and existing.kind ~= def.kind then
        -- Changing kind under a live name would leave every holder's state in
        -- the wrong half of their record, silently. Undefine it deliberately.
        return nil, "'" .. def.name .. "' already exists as a " .. existing.kind
            .. " var - undefine it first to change its kind"
    end
    if existing and existing.scope ~= def.scope then
        -- SCOPE IS AS UNMOVABLE AS KIND, for the identical reason one line up.
        -- A per-player counter's values live in the player records and a world
        -- counter's lives once; there is no move between them, so a scope
        -- change under a live name silently strands whichever set already
        -- exists - and the panel would then read a counter that has plainly
        -- been in use as one nothing has ever written to.
        return nil, "'" .. def.name .. "' already exists, counted for "
            .. tostring(existing.scope) .. " - undefine it first to change "
            .. "what it is counted for. Its current values cannot move."
    end

    def.createdMs = existing and existing.createdMs or RDShared.nowMs()
    def.by        = existing and existing.by        or by
    d[def.key]    = def
    ensure():touchDefs()
    -- A redefinition can change the expiry every holder's remaining time is
    -- computed from, so their mirrors are stale the moment this returns.
    if existing then
        for user, r in pairs(players()) do
            if (r.flags and r.flags[def.key] ~= nil)
                or (r.numbers and r.numbers[def.key] ~= nil) then
                notifyTouched(user)
            end
        end
    end
    return def
end

-- Removing a definition PURGES every player's holding of it, and that is the
-- point rather than a side effect. Leaving orphaned state behind means
-- redefining the same name next season silently resurrects last season's
-- holders - an admin deletes "Anomaly" when the event ends, recreates it a
-- year later, and everyone who attended the first one is already flagged.
-- Returns (true, playersAffected).
function RDVars.undefine(name)
    local key, why = RDVarDefs.normalizeName(name)
    if not key then return nil, why end
    local d = defs()
    if not d[key] then return nil, "no var named '" .. tostring(name) .. "' is defined" end

    d[key] = nil
    local touched = 0
    -- A world counter has no holders, so the purge is one slot. It still
    -- counts: an admin deleting a var is told how much was cleared, and
    -- reporting 0 for a counter that held 43 reads as "nothing was lost".
    if worldValues()[key] ~= nil then
        worldValues()[key] = nil
        touched = touched + 1
    end
    for user, r in pairs(players()) do
        if r.flags and r.flags[key] ~= nil then
            r.flags[key] = nil; touched = touched + 1; notifyTouched(user)
        elseif r.numbers and r.numbers[key] ~= nil then
            r.numbers[key] = nil; touched = touched + 1; notifyTouched(user)
        end
    end
    local s = ensure()
    s:touchDefs()
    s:touchState()
    return true, touched
end

function RDVars.definition(name)
    local key = RDVarDefs.normalizeName(name)
    return key and defs()[key] or nil
end

-- Sorted by key so an admin list is stable between calls - pairs() order is not.
function RDVars.definitions()
    local out = {}
    for _, def in pairs(defs()) do out[#out + 1] = def end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ---------------------------------------------------------------------------
-- Flags (flags)
-- ---------------------------------------------------------------------------

function RDVars.grant(subject, name, by)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local key, def = resolve(name, RDVarDefs.FLAG)
    if not key then return nil, def end

    local r = record(user, true)
    -- Re-granting refreshes the clock rather than being a no-op: an admin
    -- re-granting a 4-hour flag means "another four hours", not "nothing".
    r.flags[key] = { at = RDShared.nowMs(), by = by }
    ensure():touchState()
    notifyTouched(user)
    return true
end

-- `why` is free text for the caller's own audit line; this file does not act on
-- it. The kit system passes its kit id here when a claim consumes a flag.
function RDVars.revoke(subject, name, why)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local key, def = resolve(name, RDVarDefs.FLAG)
    if not key then return nil, def end

    local r = record(user, false)
    if not r or r.flags[key] == nil then
        return nil, user .. " does not hold '" .. def.name .. "'"
    end
    r.flags[key] = nil
    ensure():touchState()
    notifyTouched(user)
    return true
end

-- Returns a plain boolean for the common case. The second return explains a
-- false that is a PROGRAMMING error rather than an answer - asking `has` about
-- a counter - so a predicate in a hot path stays cheap while a mistake is still
-- discoverable. It deliberately does not throw: this is called from gameplay
-- predicates, and the engine swallows a throw in an eval predicate SILENTLY
-- (KahluaThread.java:1261-1278).
function RDVars.has(subject, name)
    local user = userKey(subject)
    if not user then return false, "no player" end
    local key, def = resolve(name, RDVarDefs.FLAG)
    if not key then return false, def end
    local r = record(user, false)
    local held = r and r.flags[key]
    if not held then return false end
    -- Checked at READ time, not left to the sweep. The sweep's cadence is a
    -- floor on how stale the STORE can be; a permission answering yes past its
    -- own deadline for even one claim is the failure the deadline exists to
    -- prevent. The sweep still reaps the record.
    local rem = remainingMs(RDVarDefs.expiryMs(def), held.at, RDShared.nowMs())
    if rem and rem <= 0 then return false end
    return true
end

-- Every holder of a flag, sorted. The admin question "who has Anomaly?".
function RDVars.holders(name)
    local key, def = resolve(name, RDVarDefs.FLAG)
    if not key then return nil, def end
    local out = {}
    for user, r in pairs(players()) do
        if r.flags and r.flags[key] ~= nil then out[#out + 1] = user end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Counters (string vars)
--
-- ABSENT IS NOT ZERO. get() returns nil for a player who has never had the
-- counter touched, and 0 for one who has been set to zero. A repeatable quest
-- needs both answers - "never started" and "started, back to nothing" - and
-- collapsing them is the single thing the two-kind split exists to prevent.
-- ---------------------------------------------------------------------------

-- Why this is not a number, phrased for an admin panel to show verbatim.
--
-- The TYPE is named, not just the value, because tostring alone cannot tell the
-- string "5" from the number 5 - both print as `5` - and "a counter takes a
-- number, got 5" is a sentence that reads like a bug in the panel. An admin
-- typing into a text field is exactly the caller who hits this.
--
-- NaN and infinity are separated out for the same reason: their type IS number,
-- so the generic sentence would be self-contradicting. Both are refused, and
-- for different reasons that both end in silence:
--
--   NaN       compares false against every bound afterwards, so every threshold
--             a consumer sets on the counter simply stops firing.
--   infinity  survives in ModData and then DISAPPEARS. RDJson has no
--             representation for it and encodes it as `null` (RDJson.lua:66,
--             fmtNum's non-finite branch), which decodes back to nil - so the
--             counter reads normally until the mirror is replayed after a crash
--             or a restart, and is then absent. A value that is present until
--             the next reboot and gone afterwards is the worst shape a stored
--             number can have.
--
-- The finite test is `v - v == 0`, which is false for both infinities and for
-- NaN. NaN is tested first only so its message is the specific one.
local function badNumber(v)
    if v ~= v then return "a counter cannot be NaN" end
    if type(v) ~= "number" then
        return "a counter takes a number, got " .. type(v) .. " (" .. tostring(v) .. ")"
    end
    if v - v ~= 0 then
        return "a counter must be finite - infinity is stored but cannot be "
            .. "written to the JSON mirror, so it would vanish on the next restart"
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- THE SUBJECT IS IGNORED ON A WORLD COUNTER, and every verb below resolves the
-- definition BEFORE it looks at one. That ordering is the whole point: a kit or
-- a quest writes `{ kind = "counter", name = "Runs", add = 1 }` and never has
-- to know which scope the DM chose. Flipping a counter from player to world is
-- then a decision on the definition alone, and every consumer keeps working.
--
-- The cost is that a world write from a caller who meant a player write is not
-- an error anybody sees. It is the right trade: the alternative is a second set
-- of verbs, which means every consumer branching on scope, which means every
-- consumer able to get the branch wrong.
-- ---------------------------------------------------------------------------

function RDVars.get(subject, name)
    local key, def = resolve(name, RDVarDefs.COUNTER)
    if not key then return nil, def end
    if RDVarDefs.isWorld(def) then return worldValues()[key] end
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local r = record(user, false)
    return r and r.numbers[key] or nil
end

function RDVars.set(subject, name, value)
    local why = badNumber(value)
    if why then return nil, why end
    local key, def = resolve(name, RDVarDefs.COUNTER)
    if not key then return nil, def end
    if RDVarDefs.isWorld(def) then
        worldValues()[key] = value
        ensure():touchState()
        return value
    end
    local user = userKey(subject)
    if not user then return nil, "no player" end
    record(user, true).numbers[key] = value
    ensure():touchState()
    notifyTouched(user)
    return value
end

-- Returns the NEW value, which is what a caller almost always wants next.
-- Absent counts as zero for the purposes of adding - that is what makes
-- add(user, "Loot", 1) work on a player's first sample without a set() first -
-- while get() still reports absent until something touches it.
function RDVars.add(subject, name, delta)
    local why = badNumber(delta)
    if why then return nil, why end
    local key, def = resolve(name, RDVarDefs.COUNTER)
    if not key then return nil, def end
    if RDVarDefs.isWorld(def) then
        local w = worldValues()
        -- Absent counts as zero for adding, exactly as it does per player -
        -- that is what makes the first claim of a kit work without a set()
        -- first - while get() still reports absent until something touches it.
        local now = (w[key] or 0) + delta
        w[key] = now
        ensure():touchState()
        return now
    end
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local r = record(user, true)
    local now = (r.numbers[key] or 0) + delta
    r.numbers[key] = now
    ensure():touchState()
    notifyTouched(user)
    return now
end

-- Back to ABSENT, not to zero. Reset means "as if it had never been touched".
function RDVars.reset(subject, name)
    local key, def = resolve(name, RDVarDefs.COUNTER)
    if not key then return nil, def end
    if RDVarDefs.isWorld(def) then
        local w = worldValues()
        if w[key] == nil then return true end
        w[key] = nil
        ensure():touchState()
        return true
    end
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local r = record(user, false)
    if not r or r.numbers[key] == nil then return true end
    r.numbers[key] = nil
    ensure():touchState()
    notifyTouched(user)
    return true
end

-- The counter counterpart of holders(): every username the counter has been
-- touched for, with its value, sorted. Same admin question from the other side -
-- "who has Anomaly?" and "where is everyone up to on AnomalyLoot?" are one
-- question asked of the two kinds, and answering only the flag half would push
-- the other into the caller, which would mean walking the store from outside it.
--
-- ABSENT PLAYERS ARE ABSENT. A username with no record does not appear with a
-- zero, because zero is a value somebody was set to and absent is not.
function RDVars.valuesOf(name)
    local key, def = resolve(name, RDVarDefs.COUNTER)
    if not key then return nil, def end
    -- A world counter has no per-player rows and this returns none, rather
    -- than one row attributed to a made-up user. A caller that wants the
    -- number asks get(); a caller drawing a list gets an empty one, which is
    -- the truth about who holds a value.
    if RDVarDefs.isWorld(def) then return {} end
    local out = {}
    for user, r in pairs(players()) do
        if r.numbers and r.numbers[key] ~= nil then
            out[#out + 1] = { user = user, value = r.numbers[key] }
        end
    end
    table.sort(out, function(a, b) return a.user < b.user end)
    return out
end

-- ---------------------------------------------------------------------------
-- Reading a whole player - the admin surface's one call
-- ---------------------------------------------------------------------------

-- A COPY, never the live record: an admin panel holding a reference to the
-- store's own table can mutate it by rendering. Definitions are joined in so a
-- caller does not need a second lookup per row.
function RDVars.ofPlayer(subject)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local r = record(user, false)
    local out = { username = user, flags = {}, numbers = {} }
    if not r then return out end
    local d = defs()
    for key, held in pairs(r.flags) do
        local def = d[key]
        out.flags[#out.flags + 1] = {
            key = key, name = def and def.name or key,
            at = held.at, by = held.by,
            expiresMs = def and RDVarDefs.expiryMs(def) or nil,
        }
    end
    for key, n in pairs(r.numbers) do
        local def = d[key]
        out.numbers[#out.numbers + 1] = {
            key = key, name = def and def.name or key, value = n,
        }
    end
    table.sort(out.flags,   function(a, b) return a.key < b.key end)
    table.sort(out.numbers, function(a, b) return a.key < b.key end)
    return out
end

-- The owner's own document, shaped for the wire. THE MIRROR OFFERS, THE SERVER
-- PERMITS: this is everything a client tool may use to decide what to show,
-- and nothing here is ever authority - every verb re-derives server-side.
--
--   flags   [key] = ms REMAINING (positive), or 0 for a flag that never
--           expires. Remaining rather than a deadline because the client's
--           wall clock is not this machine's; it adds the remaining to its own
--           clock on receipt. An already-expired holding is omitted - has()
--           would refuse it here, so the mirror must not offer it there.
--   numbers [key] = value. Absent stays absent; zero is a value.
--
-- Canonical KEYS, not display names: the client normalizes queries through the
-- same RDVarDefs rule, so lookup and storage cannot disagree about case.
-- World counters are in nobody's document, deliberately - they belong to the
-- server, and a tool that needs one is a different (unbuilt) surface.
function RDVars.mirrorOf(subject)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local out = { flags = {}, numbers = {} }
    local r = record(user, false)
    if not r then return out end
    local d, now = defs(), RDShared.nowMs()
    for key, held in pairs(r.flags) do
        local rem = remainingMs(RDVarDefs.expiryMs(d[key]), held.at, now)
        if rem == nil then out.flags[key] = 0
        elseif rem > 0 then out.flags[key] = rem end
    end
    for key, n in pairs(r.numbers) do out.numbers[key] = n end
    return out
end

-- ---------------------------------------------------------------------------
-- Expiry
--
-- THE CLOCK RUNS BACKWARDS SOMETIMES. RDShared.nowMs is getTimestampMs - wall
-- clock, and an NTP correction can step it back. A flag must not expire early
-- when that happens: an early flush costs RDConfigStore one file write, but an
-- early revoke TAKES SOMETHING FROM A PLAYER, so the two files break the tie in
-- opposite directions on purpose.
--
-- That property is STRUCTURAL here, not guarded. A backwards step makes
-- `elapsed` negative, and RDVarDefs refuses any expiry that is not a positive
-- number of minutes, so a negative elapsed can never satisfy `>= ms`. An
-- explicit `elapsed >= 0` clause was written first and then deleted: it could
-- not change the outcome of any input, and a guard that cannot fail is worse
-- than none - it reads as the thing keeping the property true, so the next
-- person to touch this believes the comparison itself is safe to rewrite.
-- The plausible mistake it invites is `math.abs(elapsed) >= ms`; the fixture
-- pins that shape directly rather than pinning the deleted clause.
--
-- Bounded by admin-scale data: online-and-offline players who hold at least one
-- flag, times their flags. Nothing here walks the world.
-- ---------------------------------------------------------------------------

function RDVars.sweep()
    local now = RDShared.nowMs()
    local d, expired = defs(), 0
    for user, r in pairs(players()) do
        if r.flags then
            local hit = false
            for key, held in pairs(r.flags) do
                -- remainingMs carries the backwards-clock property the note
                -- above describes: a negative elapsed grows the remaining.
                local rem = remainingMs(RDVarDefs.expiryMs(d[key]), held.at, now)
                if rem and rem <= 0 then
                    r.flags[key] = nil
                    expired = expired + 1
                    hit = true
                end
            end
            if hit then notifyTouched(user) end
        end
    end
    if expired > 0 then
        ensure():touchState()
        print("[RFTDCore] RDVars: " .. expired .. " flag(s) expired.")
    end
    return expired
end

-- ---------------------------------------------------------------------------
-- Death
-- ---------------------------------------------------------------------------

-- Split from the listener so a fixture can drive it with a username and no
-- engine object. Returns (flagsRevoked, countersReset).
function RDVars.applyDeath(subject)
    local user = userKey(subject)
    if not user then return 0, 0 end
    local r = record(user, false)
    if not r then return 0, 0 end

    local d, revoked, reset = defs(), 0, 0
    for key in pairs(r.flags) do
        local def = d[key]
        if def and def.revokers and def.revokers.death then
            r.flags[key] = nil
            revoked = revoked + 1
        end
    end
    for key in pairs(r.numbers) do
        local def = d[key]
        if def and def.resetOnDeath then
            r.numbers[key] = nil
            reset = reset + 1
        end
    end
    if revoked > 0 or reset > 0 then
        ensure():touchState()
        notifyTouched(user)
    end
    return revoked, reset
end

Events.OnCharacterDeath.Add(function(ch)
    -- Fires for every character in the world, so the cheap type test is first
    -- and allocates nothing. NOT gated on DeathCaptureEnabled - see the header.
    if not instanceof(ch, "IsoPlayer") then return end
    RDVars.applyDeath(ch)
end)

-- The store resolves on the first call anyway; doing it at server start means a
-- held or recovered file is reported while an operator is still watching the
-- boot, rather than hours later when something first reads a var.
if Events.OnServerStarted then
    Events.OnServerStarted.Add(function() ensure() end)
end

-- EveryTenMinutes is compressed GAME time, so at the default day length this is
-- roughly every ten real seconds - a floor on how stale an expiry can be, not a
-- schedule. The body walks only players who hold flags.
Events.EveryTenMinutes.Add(function() RDVars.sweep() end)

return RDVars

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
