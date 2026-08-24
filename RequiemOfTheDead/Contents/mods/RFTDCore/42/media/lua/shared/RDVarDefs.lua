-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDVarDefs.lua - what a player variable IS, and what makes one invalid.
--
-- Pure: no engine, no state, no I/O. It exists as its own file because
-- definition validity is the half of RDVars that can be exhaustively tested,
-- and because an admin surface (Dragonfly, later) needs to validate a form
-- before submitting it without pulling in the server-only lifecycle.
--
-- ---------------------------------------------------------------------------
-- TWO KINDS, AND WHY NOT ONE
--
--   char    a MARKER. Present or absent, holds nothing. "This character
--           attended the Anomaly event."
--   string  a COUNTER. Holds a number. "Collected 5 of 10 samples."
--
-- Merging them was considered and rejected. Revokers are a lifecycle for a
-- flag - gone when the kit is claimed, on death, after four hours - and a
-- counter is never revoked, it is incremented and reset. One system would
-- leave the revoker list meaningless for half the entries, and would collapse
-- ABSENT with ZERO, which is the exact distinction a repeatable quest needs:
-- "never started" and "started, back to nothing" are different answers.
--
-- WHY THERE IS NO STRING KIND, and why the numeric one is not called one.
--
-- This kind was called "string" until 2026-08-23, after the Conan vocabulary
-- the design borrows from - and it never held a string. It is stored in
-- `numbers`, its verbs are get/set/add/reset, and set() refuses anything that is
-- not a finite number. One word in the subsystem described something other than
-- what it named, which is how a future reader ends up "fixing" the wrong half.
--
-- Every genuine string case collapses into something else, and each collapse
-- BUYS something a string cannot do:
--
--   "Faction = Anomaly"     -> the flag `Anomaly`. Now "is this player in any
--                              faction" is a set test rather than a list of
--                              every string the field might hold.
--   "most-killed type"      -> `Kills_Screamer = 4`. Now they can be ranked.
--   "stage = chamber"       -> `Stage = 3`. Now `stage >= 3` works at all.
--   "kit they claimed"      -> the kit id already lives in a flag's revoker.
--
-- The one real string case is PLAYER-AUTHORED TEXT - a base name, an epitaph, a
-- submitted answer - and it is out of scope on purpose rather than by omission.
-- It is the only value that could originate from a player rather than an admin,
-- so it needs length bounds, control-character handling and moderation that no
-- other var needs; folding it in here would hand every consumer of vars the
-- problem of "this might be arbitrary player text".
--
-- If that case ever arrives it gets a THIRD kind of its own, not a widened
-- second one - different validation, a value that cannot be counted, sorted or
-- summarised, and different exposure rules. Which is the other reason for the
-- rename: "string" was squatting on the only good name that kind would want.
--
-- ---------------------------------------------------------------------------
-- NAMES ARE MATCHED CASE-INSENSITIVELY, DISPLAYED AS AUTHORED.
--
-- A var name is typed twice by different people at different times: once by the
-- admin defining it, once by whoever writes the kit requirement that reads it.
-- Making "Anomaly" and "anomaly" different vars guarantees a support question
-- nobody can see the answer to, so the canonical KEY is lower-case and the
-- authored spelling is kept for display. The alphabet is restricted for the
-- same reason it is in RDIdentity: these names reach JSON keys and admin
-- commands, and a name carrying a space, a quote or a line break is a parsing
-- problem waiting for a season boundary.
--
-- ---------------------------------------------------------------------------
-- A COUNTER HAS A SCOPE. Added 2026-08-23, when the first real consumer went
-- looking for "how many times has this quest been completed at all" and found
-- that every verb in RDVars takes a subject.
--
--   player   one value per player. "Alice has 5 of 10 samples."
--   world    ONE value, held by the server. "This quest has been finished 43
--            times." Nobody holds it; it has no holders list.
--
-- Summing the player half was the alternative and it is wrong twice: it costs
-- a walk of every record to answer one question, and it silently loses every
-- player who has been wiped or never came back - so the number shrinks over a
-- season for reasons nobody can see.
--
-- SCOPE DEFAULTS TO PLAYER, and that is not the same call as resetOnDeath
-- below. resetOnDeath had two plausible answers and no status quo, so picking
-- one silently would be behaviour nobody chose. Scope has a status quo: every
-- counter that exists is per-player, an absent scope has always meant exactly
-- that, and a required dial here would ask a question whose answer the panel
-- already knows.
--
-- A FLAG HAS NO SCOPE. Its entire vocabulary is about a holder - granted to
-- whom, revoked on whose death, expiring from whose grant - so a world flag is
-- not a flag with a different scope, it is a boolean nobody has designed. If
-- that is ever wanted it is a world counter used as 0/1, or a third kind with
-- its own rules. Refused here rather than ignored, because a scope silently
-- dropped from a definition is a var that behaves nothing like it reads.
--
-- ---------------------------------------------------------------------------
-- resetOnDeath HAS NO DEFAULT, DELIBERATELY. A counter that silently survived
-- death, or silently did not, is behaviour nobody chose - discovered months
-- later by a player, in the shape of a quest that cannot be failed. Creation
-- without an explicit answer is refused.

RDVarDefs = RDVarDefs or {}

RDVarDefs.FLAG   = "flag"
RDVarDefs.COUNTER = "counter"

RDVarDefs.SCOPE_PLAYER = "player"
RDVarDefs.SCOPE_WORLD  = "world"

RDVarDefs.NAME_MAX = 32

-- Revoker keys and their types. The set is CLOSED: an unknown key is refused
-- rather than ignored, because ignoring it means an admin who types `expiry`
-- instead of `expires` gets a permanent var and no indication of why.
--
-- Only two of these can be evaluated by anything in Core:
--   expires  Core has a clock.
--   death    Core has the event.
-- `kit` is an OPAQUE STRING Core never interprets. It is stored, listed and
-- handed back verbatim; the kit system reads it and calls revoke() when that
-- kit is claimed. That asymmetry is the boundary in CLAUDE.md sect. 12 - Core
-- does not learn what a kit is - and it is why the value is not validated
-- against anything: Core has no registry to validate against, and inventing
-- one would be exactly the dependency the boundary forbids.
RDVarDefs.REVOKERS = {
    kit     = "string",
    expires = "number",
    death   = "boolean",
}

local ALLOWED_FIELDS = {
    kind = true, name = true, revokers = true, resetOnDeath = true,
    scope = true,
    note = true,          -- free-text admin commentary; never interpreted
}

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

-- Returns (key, display) or (nil, reason). The key is what everything stores
-- and matches on; the display string is the caller's own spelling, trimmed.
function RDVarDefs.normalizeName(raw)
    if type(raw) ~= "string" then
        return nil, "a var name must be a string"
    end
    local display = raw:match("^%s*(.-)%s*$")
    if display == "" then
        return nil, "a var name cannot be empty"
    end
    if #display > RDVarDefs.NAME_MAX then
        return nil, "'" .. display .. "' is longer than "
            .. RDVarDefs.NAME_MAX .. " characters"
    end
    -- Leading letter: a name starting with a digit reads as an array index in
    -- half the places these keys land, and "-x" reads as a flag in a command.
    if not display:match("^%a[%w_%-]*$") then
        return nil, "'" .. display .. "' must start with a letter and use only "
            .. "letters, digits, underscore and hyphen"
    end
    return display:lower(), display
end

-- ---------------------------------------------------------------------------
-- Validation
--
-- Returns (normalized def) or (nil, reason). Reasons are written to be shown to
-- an admin verbatim, so they name the field and the value.
--
-- The returned table is a NEW one - never the caller's - so a form object that
-- is still being edited cannot mutate a stored definition behind the store's
-- back. It carries `key` alongside `name`, so consumers never re-derive it.
-- ---------------------------------------------------------------------------

local function validateRevokers(revokers)
    if revokers == nil then return {} end
    if type(revokers) ~= "table" then
        return nil, "revokers must be a table"
    end
    local out = {}
    for k, v in pairs(revokers) do
        local want = RDVarDefs.REVOKERS[k]
        if not want then
            return nil, "'" .. tostring(k) .. "' is not a revoker - the set is "
                .. "kit, expires, death"
        end
        if type(v) ~= want then
            return nil, "revoker '" .. k .. "' must be a " .. want
                .. ", got " .. type(v)
        end
        if k == "expires" and (v ~= v or v <= 0) then
            -- v ~= v catches NaN, which compares false against every bound and
            -- would otherwise install a var that can never expire while
            -- claiming it does.
            return nil, "revoker 'expires' must be a positive number of minutes"
        end
        if k == "kit" and v == "" then
            return nil, "revoker 'kit' cannot be empty"
        end
        -- death = false is not a revoker, it is the absence of one. Storing it
        -- would leave a key behind, and isPermanent below answers by looking for
        -- ANY key - so the var would read as revocable while nothing revokes it.
        if not (k == "death" and v == false) then
            out[k] = v
        end
    end
    return out
end

function RDVarDefs.validate(def)
    if type(def) ~= "table" then
        return nil, "a var definition must be a table"
    end

    for k in pairs(def) do
        if not ALLOWED_FIELDS[k] then
            return nil, "'" .. tostring(k) .. "' is not a field of a var definition"
        end
    end

    local kind = def.kind
    if kind ~= RDVarDefs.FLAG and kind ~= RDVarDefs.COUNTER then
        return nil, "kind must be '" .. RDVarDefs.FLAG .. "' or '"
            .. RDVarDefs.COUNTER .. "', got " .. tostring(kind)
    end

    local key, display = RDVarDefs.normalizeName(def.name)
    if not key then return nil, display end

    if def.note ~= nil and type(def.note) ~= "string" then
        return nil, "note must be a string"
    end

    local out = { kind = kind, key = key, name = display, note = def.note }

    if kind == RDVarDefs.FLAG then
        -- A flag has no value, so resetOnDeath would be a second spelling of
        -- revokers.death. Two ways to say one thing is how they drift apart.
        if def.resetOnDeath ~= nil then
            return nil, "a flag uses revokers.death, not resetOnDeath"
        end
        -- See the header: a world flag is not a flag. Refused rather than
        -- ignored - a dropped scope leaves a var that behaves nothing like the
        -- definition an admin is looking at.
        if def.scope ~= nil and def.scope ~= RDVarDefs.SCOPE_PLAYER then
            return nil, "a flag has no scope - it is granted to a player, "
                .. "revoked on that player's death, and expires from that "
                .. "player's grant. Use a world counter if you want one number "
                .. "the whole server shares."
        end
        local revokers, why = validateRevokers(def.revokers)
        if not revokers then return nil, why end
        out.revokers = revokers
    else
        if def.revokers ~= nil then
            return nil, "a string var has no revokers - it is reset, not revoked"
        end

        local scope = def.scope
        if scope == nil then scope = RDVarDefs.SCOPE_PLAYER end
        if scope ~= RDVarDefs.SCOPE_PLAYER and scope ~= RDVarDefs.SCOPE_WORLD then
            return nil, "scope must be '" .. RDVarDefs.SCOPE_PLAYER .. "' or '"
                .. RDVarDefs.SCOPE_WORLD .. "', got " .. tostring(scope)
        end
        out.scope = scope

        if scope == RDVarDefs.SCOPE_WORLD then
            -- Whose death? A world counter has no holder to die. Refused
            -- rather than accepted-and-ignored: `resetOnDeath = true` stored
            -- on a world counter is a promise the store cannot keep, and it
            -- would read on the panel as a lifecycle that never fires.
            if def.resetOnDeath ~= nil then
                return nil, "a world counter has no resetOnDeath - it belongs "
                    .. "to the server, not to a player, so there is no death "
                    .. "for it to reset on"
            end
        else
            if type(def.resetOnDeath) ~= "boolean" then
                return nil, "resetOnDeath is required on a string var and must be "
                    .. "true or false - there is deliberately no default"
            end
            out.resetOnDeath = def.resetOnDeath
        end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Questions consumers ask about a definition
-- ---------------------------------------------------------------------------

-- A flag with no revokers at all: it lasts until an admin removes it.
-- False for a string var, which is never revoked in the first place.
--
-- pairs(), NOT next(). B42's Kahlua registers no global `next` - BaseLib exposes
-- print/tostring/type/pairs/ipairs and the bytecode loader, and nothing more -
-- so `next(t) == nil` throws "Object tried to call nil" on a live server. It
-- passes every fixture, because tools\Gates\run-tests runs REAL Lua 5.1 where
-- the global exists (CLAUDE.md sect. 3, and RDSelect.lua:76-79 says the same
-- thing at length). This function was written with next() and shipped green.
function RDVarDefs.isPermanent(def)
    if type(def) ~= "table" or def.kind ~= RDVarDefs.FLAG then return false end
    if def.revokers == nil then return true end
    for _ in pairs(def.revokers) do return false end
    return true
end

function RDVarDefs.isFlag(def)   return type(def) == "table" and def.kind == RDVarDefs.FLAG   end
function RDVarDefs.isString(def) return type(def) == "table" and def.kind == RDVarDefs.COUNTER end

-- Is this the one-value-for-the-whole-server kind? Answers only for counters,
-- so a caller cannot reach it through a flag whose stored scope came from an
-- older document or a hand-edited file.
function RDVarDefs.isWorld(def)
    return type(def) == "table" and def.kind == RDVarDefs.COUNTER
       and def.scope == RDVarDefs.SCOPE_WORLD
end

-- Does this definition expire on its own, and when, relative to a grant?
-- Returns nil for a var that does not expire, so a caller cannot accidentally
-- treat "no expiry" as "expires at 0".
function RDVarDefs.expiryMs(def)
    if not RDVarDefs.isFlag(def) then return nil end
    local mins = def.revokers and def.revokers.expires
    if type(mins) ~= "number" then return nil end
    return mins * 60000
end

return RDVarDefs

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
