-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFTripwire - receiving half of RDTripwire, and the deck badge's alert latch
-- (client only).
--
-- The server broadcasts a tripwire to staff clients; this lands it in DFLog so
-- the console renders it with the same weight as a stack trace, and latches an
-- alert so the deck badge in the sidebar says so even when the deck is shut.
--
-- ONLY "impossible" LATCHES THE BADGE. RDTripwire's header sets out the two
-- tiers: server-observed impossibilities are evidence, client-reported ones are
-- telemetry from a cooperating client. A badge that flashes for both would train
-- staff to dismiss it, which is the only failure mode an alert really has. So
-- the "reported" tier goes to the console and nowhere else.
--
-- THE LATCH IS STICKY BY DESIGN. It is not a timed flash: an impossibility that
-- happened while nobody was at the keyboard is exactly the one worth surfacing,
-- so the badge keeps cycling until the deck is actually opened. Acknowledgement
-- is opening the deck - not clicking the badge, not a dismiss button - because
-- the point is that somebody LOOKED.

if isServer() then return end

require "RDShared"

DFTripwire = DFTripwire or {
    pending  = false,   -- an unacknowledged "impossible" is outstanding
    count    = 0,       -- how many, since the last acknowledgement
    lastCode = nil,
}

-- ---------------------------------------------------------------------------
-- Latch
-- ---------------------------------------------------------------------------

function DFTripwire.alertActive()
    return DFTripwire.pending == true
end

function DFTripwire.pendingCount()
    return DFTripwire.count or 0
end

-- Called when the deck is observed open. Idempotent - it runs from a prerender,
-- so it is called every frame the deck is visible and must cost nothing on the
-- already-acknowledged path.
function DFTripwire.acknowledge()
    if not DFTripwire.pending then return end
    DFTripwire.pending = false
    DFTripwire.count   = 0
end

-- ---------------------------------------------------------------------------
-- Intake
-- ---------------------------------------------------------------------------

local function line(row)
    local s = tostring(row.u or "?")
    if row.a and row.a ~= "" then s = s .. " [" .. tostring(row.a) .. "]" end
    return s .. "  " .. tostring(row.t or "?")
end

-- The detail pane gets the case laid out rather than the one-line summary
-- repeated. What an operator needs to decide anything is: who, at what access
-- level, did what, and how much the claim is worth.
local function detail(row)
    local impossible = (row.sev == "impossible")
    local parts = {
        (impossible and "SERVER-OBSERVED IMPOSSIBILITY" or "CLIENT-REPORTED TRIPWIRE"),
        "",
        "Code:    " .. tostring(row.code or "?"),
        "Player:  " .. tostring(row.u or "?"),
        "Access:  " .. ((row.a ~= "" and row.a) and tostring(row.a) or "(none)"),
        "",
        tostring(row.t or ""),
        "",
    }
    if impossible then
        parts[#parts + 1] =
            "Observed server-side from the connection's own access level. The client\n" ..
            "cannot suppress or forge this record. The command was NOT blocked - by the\n" ..
            "time Lua is told, the server has already accepted it."
    else
        parts[#parts + 1] =
            "Reported by the client's own instrumentation. This closes a real blind\n" ..
            "spot (42.20 moved faction acts onto a packet channel with no server-side\n" ..
            "Lua hook at all), but a client that does not want to report simply does\n" ..
            "not. Treat as telemetry, not as evidence."
    end
    parts[#parts + 1] = ""
    parts[#parts + 1] = "Full record is in the permanent archive: forensic/tripwire/"
    return table.concat(parts, "\n")
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= RDShared.MODULE or command ~= "tripwire" then return end
    if not DFLog or type(args) ~= "table" then return end

    -- The server emits one scalar record (RDTripwire.raise:180-185). Validate
    -- the envelope before field reads; tostring below deliberately represents
    -- a malformed scalar without widening this listener's error boundary.
    local impossible = (args.sev == "impossible")

    DFLog.push{
        source = "Tripwire",
        level  = impossible and "tripwire" or "warn",
        text   = line(args),
        detail = detail(args),
            -- Keyed on player+code so one account rattling the same door becomes
            -- a count rather than a wall, while a second account tripping the
            -- SAME wire stays a separate row - which is the distinction that
            -- matters when deciding whether it is one person or a pattern.
        key    = "trip:" .. tostring(args.u or "?") .. ":" .. tostring(args.code or "?"),
    }

    if impossible then
        DFTripwire.pending  = true
        DFTripwire.count    = (DFTripwire.count or 0) + 1
        DFTripwire.lastCode = tostring(args.code or "?")
    end
end)

return DFTripwire

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
