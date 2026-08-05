-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvEMP.lua
-- EMP zombie has no alive behavior tick -- it doesnt do anything while it's alive
-- the actual detonation happens in the zombieKilled command handler in RQServer.lua
-- when the EMP dies it fires svApplyEMPBlast at its position, thats the whole mechanic
-- this file just holds the state table so other modules can reference or clean it up consistently
if not isServer() then return end

RQSvEMP = RQSvEMP or {}
RQSvEMP.state = {}  -- empID -> { activated, castDue } -- currently unused, reserved for future use

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
