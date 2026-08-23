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

local store

-- One store, two documents. defs are cold and precious - what a var IS, the
-- half an admin wants back after a wipe. state is hot and deliberately NOT
-- restored across one: handing back charVars players already spent their kit
-- claims on is the exploit the save-scoping exists to prevent.
local function ensure()
    if not store then
        store = RDConfigStore.new{
            modKey    = "RFTDVars",
            defsFile  = RDShared.DIR .. "vars-defs"  .. RDShared.EXT_DOC,
            stateFile = RDShared.DIR .. "vars-state" .. RDShared.EXT_DOC,
            flushMs   = 30000,
            label     = "RFTDCore",
        }
    end
    store:boot()   -- idempotent
    return store
end

-- Exposed for the admin surface and for fixtures. Nothing else should reach
-- past the API below into the raw tables.
function RDVars.store() return ensure() end

local function defs()  return ensure():defs()  end
local function state() return ensure():state() end

-- A player's record, created on demand. `chars` are markers with provenance;
-- `numbers` are counters. Kept as two tables rather than one tagged map so
-- "absent" and "zero" can never be confused - see RDVarDefs' header.
local function record(username, create)
    local s = state()
    local r = s[username]
    if not r and create then
        r = { chars = {}, numbers = {} }
        s[username] = r
    end
    if r then
        r.chars   = r.chars   or {}
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
            .. " var - " .. (wantKind == RDVarDefs.CHAR
                and "grant/revoke/has are for markers"
                or  "get/set/add/reset are for counters")
    end
    return key, def
end

local function userKey(subject)
    if type(subject) == "string" then return subject end
    if type(subject) == "table" or type(subject) == "userdata" then
        if subject.getUsername then
            local n = subject:getUsername()
            if n then return tostring(n) end
        end
    end
    return nil
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

    def.createdMs = existing and existing.createdMs or RDShared.nowMs()
    def.by        = existing and existing.by        or by
    d[def.key]    = def
    ensure():touchDefs()
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
    for _, r in pairs(state()) do
        if r.chars and r.chars[key] ~= nil then r.chars[key] = nil; touched = touched + 1
        elseif r.numbers and r.numbers[key] ~= nil then r.numbers[key] = nil; touched = touched + 1 end
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
-- Markers (char vars)
-- ---------------------------------------------------------------------------

function RDVars.grant(subject, name, by)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local key, def = resolve(name, RDVarDefs.CHAR)
    if not key then return nil, def end

    local r = record(user, true)
    -- Re-granting refreshes the clock rather than being a no-op: an admin
    -- re-granting a 4-hour marker means "another four hours", not "nothing".
    r.chars[key] = { at = RDShared.nowMs(), by = by }
    ensure():touchState()
    return true
end

-- `why` is free text for the caller's own audit line; this file does not act on
-- it. The kit system passes its kit id here when a claim consumes a marker.
function RDVars.revoke(subject, name, why)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local key, def = resolve(name, RDVarDefs.CHAR)
    if not key then return nil, def end

    local r = record(user, false)
    if not r or r.chars[key] == nil then
        return nil, user .. " does not hold '" .. def.name .. "'"
    end
    r.chars[key] = nil
    ensure():touchState()
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
    local key, def = resolve(name, RDVarDefs.CHAR)
    if not key then return false, def end
    local r = record(user, false)
    return (r and r.chars[key] ~= nil) or false
end

-- Every holder of a marker, sorted. The admin question "who has Anomaly?".
function RDVars.holders(name)
    local key, def = resolve(name, RDVarDefs.CHAR)
    if not key then return nil, def end
    local out = {}
    for user, r in pairs(state()) do
        if r.chars and r.chars[key] ~= nil then out[#out + 1] = user end
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

function RDVars.get(subject, name)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local key, def = resolve(name, RDVarDefs.STRING)
    if not key then return nil, def end
    local r = record(user, false)
    return r and r.numbers[key] or nil
end

function RDVars.set(subject, name, value)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    if type(value) ~= "number" or value ~= value then
        return nil, "a counter takes a number, got " .. tostring(value)
    end
    local key, def = resolve(name, RDVarDefs.STRING)
    if not key then return nil, def end
    record(user, true).numbers[key] = value
    ensure():touchState()
    return value
end

-- Returns the NEW value, which is what a caller almost always wants next.
-- Absent counts as zero for the purposes of adding - that is what makes
-- add(user, "Loot", 1) work on a player's first sample without a set() first -
-- while get() still reports absent until something touches it.
function RDVars.add(subject, name, delta)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    if type(delta) ~= "number" or delta ~= delta then
        return nil, "a counter takes a number, got " .. tostring(delta)
    end
    local key, def = resolve(name, RDVarDefs.STRING)
    if not key then return nil, def end
    local r = record(user, true)
    local now = (r.numbers[key] or 0) + delta
    r.numbers[key] = now
    ensure():touchState()
    return now
end

-- Back to ABSENT, not to zero. Reset means "as if it had never been touched".
function RDVars.reset(subject, name)
    local user = userKey(subject)
    if not user then return nil, "no player" end
    local key, def = resolve(name, RDVarDefs.STRING)
    if not key then return nil, def end
    local r = record(user, false)
    if not r or r.numbers[key] == nil then return true end
    r.numbers[key] = nil
    ensure():touchState()
    return true
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
    local out = { username = user, chars = {}, numbers = {} }
    if not r then return out end
    local d = defs()
    for key, held in pairs(r.chars) do
        local def = d[key]
        out.chars[#out.chars + 1] = {
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
    table.sort(out.chars,   function(a, b) return a.key < b.key end)
    table.sort(out.numbers, function(a, b) return a.key < b.key end)
    return out
end

-- ---------------------------------------------------------------------------
-- Expiry
--
-- THE CLOCK RUNS BACKWARDS SOMETIMES. RDShared.nowMs is getTimestampMs - wall
-- clock, and an NTP correction can step it back. A marker must not expire early
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
-- marker, times their markers. Nothing here walks the world.
-- ---------------------------------------------------------------------------

function RDVars.sweep()
    local now = RDShared.nowMs()
    local d, expired = defs(), 0
    for _, r in pairs(state()) do
        if r.chars then
            for key, held in pairs(r.chars) do
                local ms = RDVarDefs.expiryMs(d[key])
                if ms and held.at then
                    -- Signed, deliberately. See the note above: a backwards
                    -- clock yields a negative elapsed, which cannot reach a
                    -- positive ms, and that is what keeps a live grant safe.
                    if now - held.at >= ms then
                        r.chars[key] = nil
                        expired = expired + 1
                    end
                end
            end
        end
    end
    if expired > 0 then
        ensure():touchState()
        print("[RFTDCore] RDVars: " .. expired .. " marker(s) expired.")
    end
    return expired
end

-- ---------------------------------------------------------------------------
-- Death
-- ---------------------------------------------------------------------------

-- Split from the listener so a fixture can drive it with a username and no
-- engine object. Returns (markersRevoked, countersReset).
function RDVars.applyDeath(subject)
    local user = userKey(subject)
    if not user then return 0, 0 end
    local r = record(user, false)
    if not r then return 0, 0 end

    local d, revoked, reset = defs(), 0, 0
    for key in pairs(r.chars) do
        local def = d[key]
        if def and def.revokers and def.revokers.death then
            r.chars[key] = nil
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
    if revoked > 0 or reset > 0 then ensure():touchState() end
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
-- schedule. The body walks only players who hold markers.
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
