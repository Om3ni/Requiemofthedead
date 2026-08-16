-- SPDX-License-Identifier: GPL-3.0-or-later
-- NOSirenPolicy.lua - owns Noise Ordinance's siren-attraction policy.

-- Multiplayer clients never create the siren WorldSound. BaseVehicle's
-- updateWorldSounds returns immediately there; the authority and singleplayer
-- process are the only contexts that need this policy.
if isClient() then return end

require "OEShared"

NoiseOrdinanceSirenPolicy = NoiseOrdinanceSirenPolicy or {}

local nativeOption
local priorValue
local wasEnabled = false
local started = false

-- BaseVehicle.java:6953-6962 and VirtualVehicle.java:107-116 both gate their
-- repeating zombie-attraction sound on the native SirenEffectsZombies option.
-- The siren audio path is separate, so changing this value cannot mute it.
-- SandboxOptions.java:546-548 resolves the named option; its inherited
-- BooleanConfigOption.java:79-81 is an in-memory value assignment.
local function sync()
    if not nativeOption then
        nativeOption = getSandboxOptions():getOptionByName("SirenEffectsZombies")
        if not nativeOption then return end
        priorValue = nativeOption:getValue()
    end

    local enabled = OEShared.enabled("NoiseOrdinanceEnable")
    if enabled then
        if not wasEnabled then priorValue = nativeOption:getValue() end
        if nativeOption:getValue() then nativeOption:setValue(false) end
    elseif wasEnabled then
        nativeOption:setValue(priorValue)
    else
        -- Noise Ordinance is dormant. Track deliberate native changes so the
        -- next enable/disable cycle restores the administrator's latest value.
        priorValue = nativeOption:getValue()
    end
    wasEnabled = enabled
end

local function start()
    if started then return end
    started = true
    sync()
    -- There is no sandbox-changed event in LuaEventManager's 42.20.2 event
    -- registry. This cheap comparison keeps the kill switch live without
    -- scanning vehicles or touching their audio state.
    Events.OnTick.Add(sync)
end

Events.OnGameStart.Add(start)
Events.OnServerStarted.Add(start)

return NoiseOrdinanceSirenPolicy

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
