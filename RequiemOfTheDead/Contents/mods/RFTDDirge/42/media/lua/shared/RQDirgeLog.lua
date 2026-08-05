-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQDirgeLog.lua - per-type diagnostic tracing for Dirge (RFTDCore-backed).
--
-- Usage (unchanged; 73 call sites depend on this exact signature):
--   RQDirgeLog.write("Glutton", "[INFO] something happened")
--
-- HISTORY, so nobody resurrects the old plumbing: the 1.0.x version wrote
-- per-type files via luajava java.io.FileWriter with an io.open fallback.
-- Both paths are dead in B42 - the server sandbox silently blocks them (and
-- that Lua<->Java surface is exactly what the March 2026 security patches
-- hardened) - so every enabled call site was writing NOTHING. Server-side
-- lines now land in Core's rotating "dirge" forensic ring, which actually
-- writes, rotates, and shares the family's format. Client-side stays
-- print-only (RDLog is server-only; the console has always been the client
-- diagnostic surface).
--
-- Master kill-switch semantics preserved: ENABLED=false makes write() a
-- no-op at the source, so the call sites never need gating or stripping.

RQDirgeLog = RQDirgeLog or {}

RQDirgeLog.ENABLED = false

local _side = isServer() and "SV" or "CL"

function RQDirgeLog.write(zType, msg)
    if not RQDirgeLog.ENABLED then return end
    local ts   = tostring(getTimestampMs and getTimestampMs() or 0)
    local line = "[" .. ts .. "][" .. _side .. "] " .. tostring(msg)
    print("[Dirge:" .. tostring(zType) .. "] " .. line)
    if isServer() then
        RDLog.legacyLine("dirge", "[" .. tostring(zType) .. "]" .. line)
    end
end

-- Flushing is owned by RDLog's cadence now; kept as a no-op because call
-- sites exist.
function RQDirgeLog.flush() end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
