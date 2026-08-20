-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCAudit - durable append-only ledger (server only).
--
-- getFileWriter is the ONLY working B42 server-side file I/O (raw io.open is
-- silently blocked). Every authoritative claim mutation writes one
-- bracket-stamped key=value line here, so cheating / disputes are resolved by
-- the ledger rather than by fragile server-veto.

if not isServer() then return end

RCAudit = RCAudit or {}

local FILE = "RFTDReclamation_Dismantle.txt"

-- os.date with a fixed all-numeric format is plain Calendar reads in Kahlua
-- (OsLib.java:110/149) and cannot throw.
local function stamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- DUAL-WRITE (RFTDCore adoption, transition state): every event still writes
-- the legacy line below - byte-identical format, same file - AND lands in
-- Core's forensic archive ("rc" stream, structured). Claim-lifecycle events
-- additionally become chronicle records in the owner's permanent per-player
-- record. The legacy line retires as a separate, verifiable step once a real
-- season has proven the new path; until then old and new are directly
-- comparable.
local CHRONICLE = {
    CLAIM   = "RC.VEHICLE_CLAIM",
    UNCLAIM = "RC.VEHICLE_RELEASE",
    EXPIRE  = "RC.VEHICLE_EXPIRE",
}

-- The chronicle subject is the CLAIM HOLDER, not necessarily the actor:
-- EXPIRE has no player object (kv.user carries the owner) and a staff release
-- carries kv.owner. The actor stays visible in the payload either way.
--
-- PREFER THE PLAYER OBJECT WHEN IT IS THE HOLDER. Returning the username STRING
-- when the holder is standing right there costs two things, both silent:
--
--   1. RDLog.envelope derives the life id from the subject, and lifeIdOf() only
--      reads modData off an object - a string yields nil, the "l" key drops out
--      of the record entirely, and a release can no longer be joined to the life
--      that made the claim. Observed live: RC.VEHICLE_CLAIM carried a lifeId and
--      its matching RC.VEHICLE_RELEASE did not.
--   2. RDIdentity.dirFor with a string subject "can only reuse an existing claim
--      or mint a SteamID-less fallback" (its own header). Ordering decides which:
--      if a release or an EXPIRE is the FIRST write for a username in a season,
--      it mints bare "Name" instead of "Name.<SteamID>", and every later write
--      finds that entry in the ledger and keeps using it. The collision-proofing
--      is then gone for that player for the whole season, silently.
--
-- So resolve the holder first, then hand back the object if it IS the holder.
-- A staff member releasing someone else's claim still files under the owner, and
-- EXPIRE still has no object to offer - those keep the string, by design.
local function usernameOf(player)
    if not (player and player.getUsername) then return nil end
    local name = player:getUsername()
    if name ~= nil then return tostring(name) end
    return nil
end

function RCAudit.chronicleSubject(player, kv)
    local holder = nil
    if type(kv) == "table" then
        if kv.owner ~= nil and kv.owner ~= "-" then
            holder = tostring(kv.owner)
        elseif kv.user ~= nil and kv.user ~= "-" then
            holder = tostring(kv.user)
        end
    end
    if holder == nil then return player end
    if usernameOf(player) == holder then return player end
    return holder
end

local function coreWrite(action, player, kv)
    local data = (type(kv) == "table") and kv or { note = tostring(kv or "") }
    RDLog.forensic("rc", "RC." .. tostring(action), player or data.user or data.owner, data, "RFTDReclamation")
    local evt = CHRONICLE[action]
    if evt then
        RDLog.chronicle(evt, RCAudit.chronicleSubject(player, kv), data)
    end
end

-- log(action, player|nil, kv|nil)
--   action : short verb, e.g. "CLAIM", "UNCLAIM", "CLAIM-DENY", "EXPIRE"
--   player : the actor (nil for system events like expiry)
--   kv     : table of extra fields (sorted for stable output) or a string
function RCAudit.log(action, player, kv)
    -- No guard. RDLog is CORE - a hard dependency of every mod in the suite,
    -- never a "foreign module" - and its write path was read end to end:
    -- envelope() is RDJson.encode, which is total for any payload (cycles,
    -- depth and node count are all bounded and every non-table type falls
    -- through to escape(), RDJson.lua:103-139), and both the forensic and
    -- chronicle writes land in appendLine, which Core itself calls BARE
    -- (RDLog.lua:192-198) on the same reading applied below. RDLog.forensic
    -- owns the one real boundary in there, around RDTally (:459), which is not
    -- ours to duplicate from out here.
    coreWrite(action, player, kv)

    -- No guard. getFileWriter returns nil for a refused extension or a failed
    -- open and does not throw (LuaManager.java:5523-5555); the nil check IS the
    -- error path.
    local writer = getFileWriter(FILE, true, true) -- createIfNull, append (never truncate)
    if not writer then return end

    -- EVERY field goes through RCShared.ledgerSafe, including the ones we
    -- derive ourselves. Most values here arrive from the wire (hDismantledReport
    -- passes args.vehicle, args.owner, args.claimId and friends through
    -- verbatim), and a newline in any of them would forge a complete extra
    -- ledger line attributed to whoever the attacker names. Sanitising only the
    -- "untrusted" ones would mean re-deciding which those are on every future
    -- call site; sanitising all of them cannot rot.
    local safe = RCShared.ledgerSafe
    local user = (player and player.getUsername and player:getUsername()) or "-"
    local parts = { string.format("[%s] action=%s user=%s",
        stamp(), safe(action), safe(user)) }

    if type(kv) == "table" then
        local keys = {}
        for k in pairs(kv) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = string.format("%s=%s", safe(k), safe(kv[k]))
        end
    elseif kv ~= nil then
        parts[#parts + 1] = safe(kv)
    end

    -- No guard, and the removed comment was the exact claim the decompile
    -- disproves: LuaFileWriter.write/close declare throws IOException but
    -- delegate to PrintWriter, which RECORDS an I/O error in an internal flag
    -- instead of raising it (LuaManager.java:9850-9868). A full disk here has
    -- never reached this caller, so the guard protected against nothing while
    -- hiding the value. Every part is a string.format result, so the concat is
    -- total too.
    writer:write(table.concat(parts, " ") .. "\n")
    writer:close()
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
