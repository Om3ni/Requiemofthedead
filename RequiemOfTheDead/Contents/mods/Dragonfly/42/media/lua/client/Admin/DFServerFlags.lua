-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFServerFlags - which server options take effect without a restart.
--
-- SHIPPED IN CODE, NOT AS EDITABLE DATA, and that is the whole point of the
-- file. Each entry is a decompile read, which makes it hard-won research rather
-- than a preference - and the maintainer's own argument against editable
-- descriptions applies exactly: one mistaken clear-all must not lose it.
-- Version control is the backup.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS NOT DERIVABLE. `/changeoption` parses the value and saves the
-- server ini (ServerOptions.java:335-344). Two options get explicit live
-- re-initialisation in the command itself and no others do:
--
--     Password             -> udpEngine.SetServerPassword   (ChangeOptionCommand.java:35-37)
--     ClientCommandFilter  -> GameServer.initClientCommandFilter (:38-40)
--
-- For everything else the answer is not in the write path at all - it is in the
-- CONSUMER. An option read fresh at each use (`getServerOptions():getBoolean("X")`)
-- is live the instant it changes; one captured into a field at boot is not.
-- That is a separate read per option, against 144 of them.
--
-- ---------------------------------------------------------------------------
-- THREE STATES, NOT TWO, and the third is the honest one.
--
--   LIVE     verified: the consumer re-reads, so the change applies at once.
--   RESTART  verified: the consumer caches, so it does not.
--   absent   NOT YET READ. Not a claim in either direction.
--
-- Marking the unread majority as "needs restart" would be a lie in the safe
-- direction, and would also make the mark meaningless - an asterisk on 140 of
-- 144 rows tells nobody anything. So the legend says what an unmarked row means
-- rather than pretending the table is complete.
--
-- ADDING AN ENTRY IS A DECOMPILE JOB. Find the consumer, read whether it
-- re-reads or caches, cite the line. Same discipline as pcall-safe.json.

if isServer() then return end

DFServerFlags = DFServerFlags or {}

DFServerFlags.LIVE    = "live"
DFServerFlags.RESTART = "restart"

DFServerFlags.byName = {
    -- Re-initialised by the change command itself.
    Password            = { DFServerFlags.LIVE,
        "ChangeOptionCommand.java:35-37 re-hashes and sets the server password" },
    ClientCommandFilter = { DFServerFlags.LIVE,
        "ChangeOptionCommand.java:38-40 calls GameServer.initClientCommandFilter" },

    -- Read fresh at each use on the client, so a value that reaches a client
    -- applies immediately there. NOTE the caveat in the header: changeOption
    -- does not re-broadcast, so an already-connected client keeps the value it
    -- received at connect until it reconnects. "Live" here means the consumer
    -- does not cache it, not that existing sessions see it.
    ChatMessageCharacterLimit = { DFServerFlags.LIVE,
        "ISChat.lua:179 reads getServerOptions() at each use" },
    ChatMessageSlowModeTime   = { DFServerFlags.LIVE,
        "ISChat.lua:526 reads getServerOptions() at each use" },
    TrashDeleteAll            = { DFServerFlags.LIVE,
        "ISInventoryPage.lua:420 reads getServerOptions() at each use" },
    SafetySystem              = { DFServerFlags.LIVE,
        "ISEquippedItem.lua:210, :1257 read getServerOptions() at each use" },
    SafetyToggleTimer         = { DFServerFlags.LIVE,
        "ISEquippedItem.lua:244 reads getServerOptions() at each use" },
    SafehouseAllowRespawn     = { DFServerFlags.LIVE,
        "MultiplayerZoneEditorMode_Safehouse.lua:310 reads at each use" },
    PVPLogToolChat            = { DFServerFlags.LIVE,
        "ISPVPLogToolUI.lua:40 reads at each use" },
    PVPLogToolFile            = { DFServerFlags.LIVE,
        "ISPVPLogToolUI.lua:43 reads at each use" },
}

-- Returns (state, why) or nil when the option has not been read yet.
function DFServerFlags.stateOf(name)
    local e = DFServerFlags.byName[name]
    if not e then return nil end
    return e[1], e[2]
end

-- How many of a registry's options carry a verdict, so the legend can be honest
-- about its own coverage instead of implying the table is complete.
function DFServerFlags.coverage(total)
    local n = 0
    for _ in pairs(DFServerFlags.byName) do n = n + 1 end
    return n, total or 0
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
