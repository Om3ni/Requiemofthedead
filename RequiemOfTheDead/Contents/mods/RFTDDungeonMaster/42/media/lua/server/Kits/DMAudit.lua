-- SPDX-License-Identifier: GPL-3.0-or-later
-- DMAudit.lua - the kit record (server only, REMOVABLE).
--
-- WHY KITS NEED A RECORD OF THEIR OWN. The claim ledger DMKits keeps is
-- save-scoped ModData capped at 250 rows: it is what the admin panel reads and
-- what the cooldown is derived from, and it is the wrong thing to answer "she
-- says she claimed the event kit and got nothing" with a month later. A wipe
-- destroys it, and row 251 pushes row 1 out. So the claim also goes to disk,
-- where nothing this mod does can take it back.
--
-- ---------------------------------------------------------------------------
-- THREE SINKS, THREE LIFECYCLES. They are not redundant copies; each one
-- answers a question the others cannot.
--
--   FORENSIC   Core's "kits" archive stream, RFTD/forensic/kits/<UTC-date>/.
--              EVERY action, refusals included. Core rolls it: one segment
--              window per period (4h), and line/byte thresholds start another
--              immutable part inside that window. This is the only sink that
--              rotates, and the only one an unbounded producer may write to.
--
--   CHRONICLE  Core's permanent per-player season record,
--              RFTD/season/<S>/chronicle/p/<Name.SteamID>/events.jsonl.log,
--              beside that player's spawns, deaths and vehicle claims. Never
--              rotated, so what may enter it is a CLOSED enum RDEvents
--              enforces - see chronicleEvent() for the four. Joining a kit
--              claim to the rest of a player's season is the whole point of
--              putting it here rather than only in the folder below.
--
--   Kits/      This mod's own tree, and the one that survives not knowing the
--              season layout:
--                Kits/<Name.SteamID>/events.jsonl.log   append-only
--                Kits/<Name.SteamID>/latest.json.txt    the last DELIVERY
--                Kits/_all.log                          slim pipe timeline
--              Same shape Memoir's audit established, and the same reason: a
--              per-player folder you can open, plus one human-readable file
--              you can read top to bottom.
--
-- NONE OF THE THREE IS DERIVED FROM ANOTHER. A rotation loses forensic
-- refusals and neither permanent sink notices; deleting this file (see below)
-- stops all three and the game is unaffected.
--
-- ---------------------------------------------------------------------------
-- WHY Kits/ NEVER ROLLS, unlike the forensic stream it sits beside.
--
-- Rotation exists to stop one file growing without bound. Nothing here can:
-- only the closed action list reaches this tree, a claim is rate-limited by
-- its own cooldown, and refusals - the one action a player can produce on
-- demand by clicking - are deliberately kept out. A per-player file therefore
-- grows by roughly one line per kit per cooldown period.
--
-- That matters because rolling is expensive in this engine. PZ Lua has no
-- delete and no rename (RDLog's rotation note), so "roll" means closing a path
-- forever and opening a new one, and every reader then has to know how to walk
-- a set of dated parts. Paying that to bound a file that cannot grow would be
-- buying a lifecycle nobody needs. If refusals ever do get recorded here, this
-- reasoning is what stops being true.
--
-- ---------------------------------------------------------------------------
-- REMOVABLE, the same contract Memoir's audit states. Delete server/Kits/ and
-- kit auditing is off with no other edit - DMKits_Server routes every call
-- through one `if DMAudit then` shim. What that costs is stated plainly because
-- it is more than Memoir's: this file owns the FORENSIC write too, so deleting
-- it turns off the archive as well, not just the durable ledger. That is the
-- honest meaning of "auditing is off"; a half-removable auditor that quietly
-- kept writing somewhere would be worse than either answer.
--
-- ---------------------------------------------------------------------------
-- THE SUBJECT IS WHO THE RECORD IS ABOUT, NOT WHO CAUSED IT, and the actor
-- goes in `by`. An admin handing a kit to a player and an admin clearing
-- someone's claim are both records about the OTHER person.
--
-- Getting it wrong is silent - the write succeeds, into the wrong folder - and
-- it costs two more things Reclaimation learned the hard way (RCAudit's
-- header, live 2026-08): RDLog's envelope derives the life id from the subject
-- and only an OBJECT carries one, so a string drops "l" out of the record; and
-- RDIdentity.dirFor with a string can only reuse an existing claim or mint a
-- SteamID-less directory, which then sticks for the rest of the season.
--
-- So callers pass the PLAYER OBJECT whenever they hold one for the subject.
-- There is no resolve-the-subject helper here on purpose: every call site
-- already knows which of its two people the record is about, and a helper that
-- guessed from the payload would be a second copy of RCAudit's.
--
-- ---------------------------------------------------------------------------
-- File names: ".jsonl.log" / ".json.txt" are FORCED by the 42.20 write
-- allowlist, not chosen. getFileWriter returns nil - silently - for any
-- extension outside it. The rule and its traps live in RDShared (EXT_STREAM /
-- EXT_DOC), which is the single place to change if TIS moves the set again.
-- Nested directories are engine-guaranteed: getFileWriter runs File.mkdirs()
-- on the parent chain and returns nil on refusal (LuaManager.java:5523-5555).

if not isServer() then return end

-- Explicit: EXT_STREAM/EXT_DOC and RDEvents are read at FILE SCOPE below, and
-- the client walks every mod's lua tiers alphabetically, so "DMAudit.lua" runs
-- long before Core's "RDShared.lua". Cross-mod require works and the walk skips
-- files it has already run. Safe under the isServer() guard above, which has
-- already returned on the client.
require "RDShared"
require "RDFile"
require "RDEvents"
require "RDJson"
require "RDLog"
require "RDIdentity"

DMAudit = DMAudit or {}

DMAudit.SCHEMA_V = 1

local MODULE = "RFTDDungeonMaster"
local STREAM = "kits"        -- Core's forensic stream name; unchanged
local DIR    = "Kits/"       -- this mod's own tree, under <cacheDir>/Lua/

local F_EVENTS = "events" .. RDShared.EXT_STREAM   -- append-only
local F_LATEST = "latest" .. RDShared.EXT_DOC      -- rewritten in place
local F_ALL    = "_all.log"                        -- slim, already an allowed ext

-- The chronicle enum. Registered HERE rather than in a shared file because
-- these events have exactly one writer and it is this one - and because
-- deleting this folder should take the schema entry with it. RDSeasonServer
-- emits the registry as RFTD/schema.json at boot, so an auditor that is not
-- installed declares no events it cannot write.
--
-- KIT_REOPENED is world-scope and the rest are per-player, which is not a
-- style choice: re-opening clears every claim on a kit at once, so there is no
-- one player it is about.
RDEvents.registerNamespace("DM", MODULE, {
    KIT_CLAIMED  = { scope = "p", req = { "kit" } },
    KIT_GRANTED  = { scope = "p", req = { "kit", "by" } },
    KIT_CLEARED  = { scope = "p", req = { "kit", "by" } },
    KIT_REOPENED = { scope = "w", req = { "kit", "by", "cleared" } },
})

-- ---------------------------------------------------------------------------
-- Which actions reach the permanent sinks
-- ---------------------------------------------------------------------------

-- Everything else - KIT_CLAIM_REFUSED, KIT_DEFINE_REFUSED, KIT_GRANT_FAILED,
-- KIT_DEFINED, KIT_DELETED - reaches the forensic archive and stops there.
-- That is the BOUND on both permanent sinks, and it is deliberate:
-- KIT_CLAIM_REFUSED fires every time a player clicks a kit they cannot have,
-- which is a rate nobody but the player controls.
function DMAudit.chronicleEvent(action, kv)
    if action == "KIT_CLAIMED" then
        -- A self-claim and a staff grant are different permanent facts. The
        -- forensic action cannot tell them apart and renaming it would be an
        -- event-name change (CLAUDE.md sect. 13); `by` already distinguishes
        -- them, and it is set only when an admin was responsible.
        return kv.by and "DM.KIT_GRANTED" or "DM.KIT_CLAIMED"
    elseif action == "KIT_CLAIM_CLEARED" then
        return "DM.KIT_CLEARED"
    elseif action == "KIT_REOPENED" then
        return "DM.KIT_REOPENED"
    end
    return nil
end

-- A record goes in a player's own folder only when it is ABOUT one player.
-- KIT_REOPENED is not: filing it under the admin who pressed the button would
-- put it in the folder of the one person it does not concern.
local PER_PLAYER = {
    KIT_CLAIMED       = true,
    KIT_CLAIM_CLEARED = true,
}

-- latest.json is THE RECOVERY POINT: what this player last actually received.
-- Only a delivery writes it. A cleared claim overwriting it would replace the
-- record of what they got with the record of an admin letting them try again,
-- which is precisely the question the file exists to answer. (Memoir's audit
-- learned this the other way round, with restores overwriting writes.)
local RECOVERY = {
    KIT_CLAIMED = true,
}

-- ---------------------------------------------------------------------------
-- Sinks
-- ---------------------------------------------------------------------------

local writeFailCount = 0
local writeFailSaid  = {}

-- One line per path per session, not one per failure. A disk that refuses a
-- write refuses the next one too, and a per-write warning turns a full disk
-- into a console flood that hides everything else. The count stays exact.
local function refused(path)
    writeFailCount = writeFailCount + 1
    if writeFailSaid[path] then return end
    writeFailSaid[path] = true
    print("[RFTDDungeonMaster] DMAudit: cannot write '" .. DIR .. path
        .. "' - kit records are being lost. Session count: DMAudit.writeFailures()")
end

function DMAudit.writeFailures() return writeFailCount end

-- Mechanism in RDFile (2026-08-25); its header carries the engine facts the
-- block here used to re-derive. The per-path refusal accounting stays - it
-- is this ledger's own observability, same split as MMAudit's.
local function put(path, append, line)
    local ok
    if append then
        ok = RDFile.appendLine(DIR .. path, line)
    else
        ok = RDFile.rewrite(DIR .. path, line .. "\n")
    end
    if not ok then
        refused(path)
        return false
    end
    return true
end

-- The slim timeline: <epochSec>|<gameDay>|<ACTION>|user=<name>|k=v...
--
-- EVERY field goes through textSafe with "|" as an extra delimiter, including
-- the ones derived here. Kit ids and item summaries arrive from an authored
-- catalogue and a grant report, and a newline in any of them would forge a
-- complete extra line attributed to whoever it names. Deciding per-field which
-- are untrusted is a decision that has to be re-made on every future call
-- site; doing all of them cannot rot.
function DMAudit.pipeLine(now, day, action, user, kv)
    local safe  = RDShared.textSafe
    local parts = {
        string.format("%d", now or 0),
        day and string.format("%.2f", day) or "?",
        safe(action, "|"),
        "user=" .. safe(user, "|"),
    }
    local keys = {}
    for k in pairs(kv or {}) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = safe(k, "|") .. "=" .. safe(kv[k], "|")
    end
    return table.concat(parts, "|")
end

-- ---------------------------------------------------------------------------
-- The one door
-- ---------------------------------------------------------------------------

-- log(action, subject, kv)
--   action  : the forensic action name, e.g. "KIT_CLAIMED". Free-form on the
--             forensic side; chronicleEvent() decides whether it is also a
--             permanent event.
--   subject : WHO THE RECORD IS ABOUT - the claimant, not the admin. Pass the
--             IsoPlayer whenever one exists; a username string otherwise. See
--             the header for what a string costs.
--   kv      : plain table. `by` names the responsible admin when there is one,
--             and is what separates a grant from a self-claim.
function DMAudit.log(action, subject, kv)
    kv = kv or {}
    local user = RDShared.username(subject)

    -- Forensic first, and unconditionally. It is the sink that must hold the
    -- actions the other two refuse, so an early return anywhere below can
    -- never cost it a record.
    RDLog.forensic(STREAM, "DM." .. tostring(action), subject, kv, MODULE)

    local evt = DMAudit.chronicleEvent(action, kv)
    if not evt then return end

    RDLog.chronicle(evt, subject, kv)

    local now = RDShared.nowSec()
    local day = RDShared.gameDay()

    -- The JSON record: envelope first, payload merged over it. A caller reusing
    -- an envelope key is a caller bug and the envelope does not defend against
    -- it - there are five names and they are documented right here.
    local rec = { v = DMAudit.SCHEMA_V, t = now, day = day,
                  action = tostring(action), user = user }
    for k, v in pairs(kv) do rec[k] = v end
    local line = RDJson.encode(rec)

    -- Per-player files need a directory, and a directory needs a name we can
    -- stand behind for a whole season. RDIdentity mints and remembers one.
    if user and PER_PLAYER[action] then
        local dir = RDIdentity.dirFor(subject)
        put(dir .. "/" .. F_EVENTS, true, line)
        if RECOVERY[action] then
            put(dir .. "/" .. F_LATEST, false, line)
        end
    end

    put(F_ALL, true, DMAudit.pipeLine(now, day, action, user or "-", kv))
end

return DMAudit

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
