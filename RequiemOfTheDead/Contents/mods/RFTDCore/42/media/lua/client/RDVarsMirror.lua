-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDVarsMirror - this client's copy of its OWN player variables.
--
-- THE MIRROR OFFERS, THE SERVER PERMITS. That sentence is the whole contract.
-- A client tool reads this to decide what to SHOW - light a door, offer a
-- button, skip a prompt - and never to decide what is allowed: every verb the
-- offer leads to is re-derived server-side (RDVars.has, at the moment of
-- action), because a client that can be asked "do you hold X" can be made to
-- answer yes. Treat a stale or forged mirror as a cosmetic problem by design.
--
-- NO UI, deliberately and permanently. Players do not see their flags; they
-- experience what the flags do. This file is an API for tools, and a surface
-- that listed "your variables" would turn invisible substrate into a menu.
--
-- WHAT ARRIVES: RDVarsPush sends the full document - canonical keys, flags as
-- ms REMAINING (0 = never expires), counters as values - on connect and after
-- any change. Remaining rather than a deadline because this machine's clock is
-- not the server's; the deadline is anchored to OUR clock at receipt, so skew
-- between the two never resurrects or kills a flag. Replace is wholesale: no
-- deltas to merge, nothing to leak from a previous document.
--
-- Absent stays absent: a counter never pushed reads nil, not 0, the same
-- distinction the server keeps (RDVarDefs' header owns the reasoning).
--
-- In singleplayer or before the first push ready() is false and every read
-- answers "hold nothing" - tools should offer nothing, which is correct for a
-- world where no server has said otherwise.

if isServer() then return end

require "RDShared"
require "RDVarDefs"

RDVarsMirror = RDVarsMirror or {}

-- Must agree with RDVarsPush.lua; each names the pair at the top.
local MODULE  = "RFTDCore"
local COMMAND = "VarsMine"

-- flags: [key] = true (never expires) | deadline on OUR clock.
-- numbers: [key] = value. nil until the first document arrives.
local doc = nil

-- Swallow one pushed document. Split from the event listener so the fixture
-- can drive it; returns whether the payload was usable. Field-by-field type
-- checks rather than trust: the payload crossed the wire, and one malformed
-- entry must not poison the rest of the document.
function RDVarsMirror.absorb(args)
    if type(args) ~= "table" then return false end
    local flags, numbers = {}, {}
    local now = RDShared.nowMs()
    if type(args.flags) == "table" then
        for k, rem in pairs(args.flags) do
            if type(k) == "string" and type(rem) == "number" then
                if rem == 0 then
                    flags[k] = true
                elseif rem > 0 then
                    flags[k] = now + rem
                end
            end
        end
    end
    if type(args.numbers) == "table" then
        for k, v in pairs(args.numbers) do
            if type(k) == "string" and type(v) == "number" then
                numbers[k] = v
            end
        end
    end
    doc = { flags = flags, numbers = numbers }
    return true
end

-- Has a document arrived at all? False means "offer nothing", and it is a
-- different false from holding nothing - a tool that wants to show a loading
-- state instead of an empty one asks here.
function RDVarsMirror.ready()
    return doc ~= nil
end

-- Does this client's player hold the flag, as far as the mirror knows?
-- Case-insensitive through the SAME normalize rule the server matches with,
-- so "Anomaly" and "anomaly" cannot disagree here and agree there. A flag
-- past its deadline answers false locally - staleness must never extend a
-- permission the server has already stopped honouring.
function RDVarsMirror.holds(name)
    if not doc then return false end
    local key = RDVarDefs.normalizeName(name)
    if not key then return false end
    local hold = doc.flags[key]
    if hold == nil then return false end
    if hold == true then return true end
    return RDShared.nowMs() < hold
end

-- The counter's value, or nil for never-touched. nil-vs-0 is the house
-- distinction; collapsing it here would make "have you started" unanswerable
-- on the client after the server went to lengths to keep it answerable.
function RDVarsMirror.value(name)
    if not doc then return nil end
    local key = RDVarDefs.normalizeName(name)
    if not key then return nil end
    return doc.numbers[key]
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or command ~= COMMAND then return end
    RDVarsMirror.absorb(args)
end)

return RDVarsMirror

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
