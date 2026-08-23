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
-- marker - gone when the kit is claimed, on death, after four hours - and a
-- counter is never revoked, it is incremented and reset. One system would
-- leave the revoker list meaningless for half the entries, and would collapse
-- ABSENT with ZERO, which is the exact distinction a repeatable quest needs:
-- "never started" and "started, back to nothing" are different answers.
--
-- WHY "string" HOLDS A NUMBER. Every genuine string case collapses into
-- something else: "Faction = Anomaly" is the charVar `Anomaly`; "most-killed
-- type" is `Kills_Screamer = 4`. Quest stages want to be ordinal so `stage >= 3`
-- works. Player-authored text is content, not a variable. The kind is named for
-- the admin-facing concept, not the Lua type.
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
-- resetOnDeath HAS NO DEFAULT, DELIBERATELY. A counter that silently survived
-- death, or silently did not, is behaviour nobody chose - discovered months
-- later by a player, in the shape of a quest that cannot be failed. Creation
-- without an explicit answer is refused.

RDVarDefs = RDVarDefs or {}

RDVarDefs.CHAR   = "char"
RDVarDefs.STRING = "string"

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
    local out, count = {}, 0
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
        -- would make `next(revokers) == nil` - the permanence test - lie.
        if not (k == "death" and v == false) then
            out[k] = v
            count = count + 1
        end
    end
    return out, nil, count
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
    if kind ~= RDVarDefs.CHAR and kind ~= RDVarDefs.STRING then
        return nil, "kind must be '" .. RDVarDefs.CHAR .. "' or '"
            .. RDVarDefs.STRING .. "', got " .. tostring(kind)
    end

    local key, display = RDVarDefs.normalizeName(def.name)
    if not key then return nil, display end

    if def.note ~= nil and type(def.note) ~= "string" then
        return nil, "note must be a string"
    end

    local out = { kind = kind, key = key, name = display, note = def.note }

    if kind == RDVarDefs.CHAR then
        -- A marker has no value, so resetOnDeath would be a second spelling of
        -- revokers.death. Two ways to say one thing is how they drift apart.
        if def.resetOnDeath ~= nil then
            return nil, "a char var uses revokers.death, not resetOnDeath"
        end
        local revokers, why = validateRevokers(def.revokers)
        if not revokers then return nil, why end
        out.revokers = revokers
    else
        if def.revokers ~= nil then
            return nil, "a string var has no revokers - it is reset, not revoked"
        end
        if type(def.resetOnDeath) ~= "boolean" then
            return nil, "resetOnDeath is required on a string var and must be "
                .. "true or false - there is deliberately no default"
        end
        out.resetOnDeath = def.resetOnDeath
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Questions consumers ask about a definition
-- ---------------------------------------------------------------------------

-- A char var with no revokers at all: it lasts until an admin removes it.
-- False for a string var, which is never revoked in the first place.
function RDVarDefs.isPermanent(def)
    if type(def) ~= "table" or def.kind ~= RDVarDefs.CHAR then return false end
    return def.revokers == nil or next(def.revokers) == nil
end

function RDVarDefs.isChar(def)   return type(def) == "table" and def.kind == RDVarDefs.CHAR   end
function RDVarDefs.isString(def) return type(def) == "table" and def.kind == RDVarDefs.STRING end

-- Does this definition expire on its own, and when, relative to a grant?
-- Returns nil for a var that does not expire, so a caller cannot accidentally
-- treat "no expiry" as "expires at 0".
function RDVarDefs.expiryMs(def)
    if not RDVarDefs.isChar(def) then return nil end
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
