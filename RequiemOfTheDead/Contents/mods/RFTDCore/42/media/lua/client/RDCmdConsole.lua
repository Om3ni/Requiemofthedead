-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDCmdConsole.lua - lands the server's client-command feed in Dragonfly's
-- Console tab (client only).
--
-- Receiving half of RDCmdRelay. The server sends one batched "cmdRelay" per flush
-- window to staff clients only; this unpacks it into DFLog, which is what
-- DFConsoleTab renders. Nothing else to wire - the tab subscribes to DFLog
-- already, so entries appear live with no tab-side change.
--
-- Source is tagged "ClientCmd" so the tab's existing source filter can isolate
-- the feed from ordinary mod chatter. Level carries the ONE judgement worth making
-- client-side: a command from an account with no staff capability is "warn", from
-- staff it is "audit". That is the authority-relative distinction the Guardian
-- spec insists on - the offence is never the command name, it is who fired it -
-- and it means an unauthorised probe arrives already coloured differently from the
-- admin traffic around it. Classification beyond that belongs to whatever reads
-- the forensic ring, not to a UI.
--
-- DFLog.push collapses consecutive identical (source, text) entries into one line
-- with a count, which is exactly right for this: a client spamming one command
-- becomes "xN" rather than 40 identical rows, and the buffer keeps its useful
-- depth. That is also why the text is built WITHOUT the estimate or a timestamp
-- inline - varying either would defeat the collapse and flood the tab.
--
-- No args are relayed and none are expected; see RDCmdRelay's flush comment.

if isServer() then return end

require "RDShared"

RDCmdConsole = RDCmdConsole or {}

local function line(row)
    local s = tostring(row.u or "?") .. "  " .. tostring(row.c or "?")
    if row.a and row.a ~= "" then s = s .. "  [" .. tostring(row.a) .. "]" end
    return s
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= RDShared.MODULE or command ~= "cmdRelay" then return end
    if not DFLog or not args then return end

    pcall(function()
        for _, row in ipairs(args.rows or {}) do
            DFLog.push{
                source = "ClientCmd",
                level  = (row.s == 1) and "audit" or "warn",
                text   = line(row),
            }
        end

        -- Never let a truncated feed look like a quiet server. The server counts
        -- what it refused to buffer; say so in the same stream rather than in a
        -- console print nobody is reading.
        local d = tonumber(args.dropped) or 0
        if d > 0 then
            DFLog.push{
                source = "ClientCmd",
                level  = "error",
                text   = string.format("(%d command(s) dropped this window - relay cap reached)", d),
            }
        end
    end)
end)

return RDCmdConsole

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
