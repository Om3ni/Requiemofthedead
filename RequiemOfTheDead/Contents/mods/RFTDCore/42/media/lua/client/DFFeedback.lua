-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFFeedback - HaloText wrappers for action feedback.
--
-- Result events from the server route through here so admins see whether an
-- action landed. addBadText for failures, addGoodText for successes. The
-- ChunkAdminControl reference mod was silent on both, which made debugging
-- impossible; this is the fix for that.

if isServer() then return end

DFFeedback = DFFeedback or {}

local function localPlayer()
    return getPlayer()
end

function DFFeedback.good(text)
    local p = localPlayer()
    if p and HaloTextHelper then
        HaloTextHelper.addGoodText(p, tostring(text or ""))
    end
end

function DFFeedback.bad(text)
    local p = localPlayer()
    if p and HaloTextHelper then
        HaloTextHelper.addBadText(p, tostring(text or ""))
    end
end

-- Server replies via sendServerCommand(module, "Result", {ok, action, reason}).
-- Consume it here so every command has visible feedback by default.
local function onServerCommand(module, command, args)
    if module ~= "RFTDDragonfly" or command ~= "Result" then return end   -- literal: DFCore is Dragonfly-only; result events only flow when the panel mod is present
    args = args or {}
    if args.ok then
        if args.message then DFFeedback.good(args.message) end
    else
        DFFeedback.bad(args.reason or ("Action failed: " .. tostring(args.action or "?")))
    end
end

Events.OnServerCommand.Add(onServerCommand)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
