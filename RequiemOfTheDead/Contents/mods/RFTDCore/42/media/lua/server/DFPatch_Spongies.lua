-- SPDX-License-Identifier: GPL-3.0-or-later
-- DFPatch_Spongies.lua - Dragonfly removable third-party patch
--
-- Fixes a join-time crash in "Spongies Character Customisation".
-- FaceManager_Server.CheckData(player, data) reads data.GrowTimer.stubbleHead
-- (FaceManager_Server.lua:350). For players whose saved SPNCharCustom data has
-- no GrowTimer table (older/partial data that still passes the version check),
-- that throws "attempted index: stubbleHead of non-table: null" during the
-- OnPlayerJoin -> OnClientCommand path.
--
-- FaceManager_Server is a file-local module table returned via `return`, so it
-- is not a global. We reach the SAME cached instance through require() (the path
-- every Spongies file uses) and wrap CheckData to guarantee data.GrowTimer is a
-- table before delegating to the original. The default mirrors the canonical
-- shape Spongies itself writes (FaceManager_Server.lua:197-201).
--
-- REMOVABLE: delete this file to drop the patch. Spongies keeps working with its
-- original behaviour; nothing else in Dragonfly depends on this.

if not isServer() then return end

local applied = false

local function apply()
    if applied then return end

    local ok, FM = pcall(require, "CharacterCustomisation/FaceManager_Server")
    if not ok or type(FM) ~= "table" or type(FM.CheckData) ~= "function" then
        return -- Spongies not present
    end
    applied = true

    local orig = FM.CheckData
    FM.CheckData = function(player, data)
        if data and type(data.GrowTimer) ~= "table" then
            local sv = SandboxVars and SandboxVars.SPNCharCustom
            data.GrowTimer = {
                stubbleHead  = (sv and sv.StubbleHeadGrowth  or 0) * 24,
                stubbleBeard = (sv and sv.StubbleBeardGrowth or 0) * 24,
                bodyHair     = (sv and sv.BodyHairGrowth     or 0) * 24,
            }
        end
        return orig(player, data)
    end

    print("[Dragonfly] DFPatch_Spongies applied (CheckData GrowTimer guard)")
end

Events.OnServerStarted.Add(apply)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
