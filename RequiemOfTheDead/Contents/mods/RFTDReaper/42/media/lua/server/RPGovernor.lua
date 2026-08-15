-- SPDX-License-Identifier: GPL-3.0-or-later
-- RPGovernor - LZI (LuaZombieInjection), the experimental population governor.
--
-- EFI on a carbureted engine: the native popman's fuel map (the Start->Peak
-- population ramp) is fixed at world start, but PopulationPeakMultiplier is
-- read at QUERY time by the native curve functions, so trimming it live
-- rescales desired counts and respawn targets for the whole map. This file
-- watches real tick health and trims the peak when the server is drowning,
-- restoring it when the server breathes again.
--
-- WHAT THIS IS NOT: a rescue. Lowering the peak removes no zombies; it only
-- stops the ramp from adding more and shrinks what respawn refills toward.
-- Population then falls by attrition. Reaper's cull is the fast path; this
-- is the mixture screw.
--
-- THE PUSH NEEDS THE BRIDGE. Sandbox writes from Lua reach the Java options
-- only; the native sees them at world init or /reloadoptions. The sidecar
-- class in tools/lzi/ patches setZombiesMaxPerChunk (the tail of the global
-- setMinMaxZombiesPerChunk) to call onConfigReloaded(), making that global
-- the injector port. Without the bridge installed this governor still runs
-- and still writes the sandbox value, but the native only notices at the
-- next restart - degraded, not broken. The proof-of-bridge is the console
-- line "[LZI] popman config pushed to native" after every step.

if not isServer() then return end

require "RDShared"

local MODULE = "RFTDReaper"

-- -------------------------------------------------------------------------
-- Config (re-read each window; sandbox edits land without restart)
-- -------------------------------------------------------------------------

local function cfg()
    local s = SandboxVars.RFTDReaper or {}
    return {
        -- Default OFF: this is an experimental feature with an out-of-mod
        -- install step (the bridge class). Arm it deliberately.
        enabled    = s.LZIEnabled == true,
        -- Effective-Hz thresholds. The dedi's design target is 10 ticks/sec
        -- (UpdateLimit(100ms)); loaded servers sag toward 2. Low water is
        -- deliberately far below target so ordinary bustle never trips it.
        lowWater   = s.LZILowWaterHz or 5,
        highWater  = s.LZIHighWaterHz or 9,
        -- Seconds the signal must hold before a step fires. Down is minutes
        -- (overloads worth reacting to are sustained); up is much longer
        -- (population recovery is slow, so re-adding fuel should be timid).
        holdDown   = s.LZIHoldDownSec or 120,
        holdUp     = s.LZIHoldUpSec or 900,
        -- Peak trim per step, and the floor the governor will never trim
        -- below. Ceiling is not configured: it is captured from the live
        -- sandbox the first time the governor arms (see ModData below).
        step       = s.LZIStep or 0.25,
        floor      = s.LZIFloor or 1.0,
        -- Minimum seconds between steps in either direction. The lever acts
        -- over hours, so stepping faster than this just slams the floor.
        cooldown   = s.LZICooldownSec or 600,
    }
end

-- -------------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------------

local function clockMs()
    if getTimestampMs then return getTimestampMs() end
    return 0
end

-- Ceiling and governed flag survive restarts in world ModData because the
-- governed peak itself survives: the sandbox bin is saved with the world,
-- so after a restart SandboxVars already holds the trimmed value and the
-- original configured peak would otherwise be lost.
local store = nil
local function getStore()
    if store then return store end
    store = ModData.getOrCreate("RFTDLZI")
    return store
end

local windowStartMs  = nil   -- wall-clock start of the current sensor window
local windowTicks    = 0     -- ticks counted in the window
local lastTickMs     = nil   -- for freeze detection
local lowHoldSec     = 0     -- seconds the low-water signal has held
local highHoldSec    = 0     -- seconds the high-water signal has held
local lastStepMs     = 0     -- cooldown anchor
local announced      = false -- one-time arm log
local restoredOnBoot = false -- one-time disable-restore check

local WINDOW_SEC = 10
-- A gap this long between consecutive ticks is a process freeze (console
-- QuickEdit, Defender, page trimming), not zombie load. The window that
-- contains it is a lie; discard it rather than read it as low Hz.
local FREEZE_GAP_MS = 3000

-- -------------------------------------------------------------------------
-- Actuator
-- -------------------------------------------------------------------------

local function audit(text)
    print("[LZI] " .. text)
    sendServerCommand("RFTDDragonfly", "LogBroadcast", {
        source = "Mod:RFTDReaper",
        level  = "audit",
        text   = "LZI: " .. text,
    })
end

local function currentPeak()
    local zc = SandboxVars.ZombieConfig or {}
    return zc.PopulationPeakMultiplier or 1.5
end

local function applyPeak(v, why)
    v = math.max(0.0, math.min(4.0, v))   -- engine option range
    -- Guard is load-bearing: SandboxOptions.set throws IllegalArgumentException
    -- on an unknown option name, so an option renamed by a patch must degrade
    -- to "governor does nothing" rather than kill the tick that called it.
    local ok, err = pcall(function()
        getSandboxOptions():set("ZombieConfig.PopulationPeakMultiplier", v)
        -- Keep the Lua-side mirror honest so currentPeak() and other readers
        -- of SandboxVars agree with the Java option we just set.
        if SandboxVars.ZombieConfig then
            SandboxVars.ZombieConfig.PopulationPeakMultiplier = v
        end
        -- The LZI port. 0/255 are the engine defaults for min/max per chunk
        -- (ZombiePopulationManager fields); the call exists to fire the
        -- patched Max setter, which pushes all zombie config to the native.
        setMinMaxZombiesPerChunk(0, 255)
    end)
    if ok then
        audit(string.format("peak -> %.2f (%s)", v, why))
    else
        audit("apply failed: " .. tostring(err))
    end
    return ok
end

-- -------------------------------------------------------------------------
-- Controller
-- -------------------------------------------------------------------------

local function onWindow(hz, c)
    -- Arm bookkeeping: capture the pristine ceiling once, forever.
    local md = getStore()
    if md.ceiling == nil then
        md.ceiling = currentPeak()
        audit(string.format("armed; ceiling captured at %.2f", md.ceiling))
    end

    if hz < c.lowWater then
        lowHoldSec  = lowHoldSec + WINDOW_SEC
        highHoldSec = 0
    elseif hz > c.highWater then
        highHoldSec = highHoldSec + WINDOW_SEC
        lowHoldSec  = 0
    else
        lowHoldSec  = 0
        highHoldSec = 0
    end

    local now = clockMs()
    if now - lastStepMs < c.cooldown * 1000 then return end

    local peak = currentPeak()
    if lowHoldSec >= c.holdDown and peak > c.floor then
        local target = math.max(c.floor, peak - c.step)
        if applyPeak(target, string.format("tick %.1f Hz for %ds", hz, lowHoldSec)) then
            md.governed = true
            lastStepMs = now
            lowHoldSec = 0
        end
    elseif highHoldSec >= c.holdUp and md.governed and peak < (md.ceiling or peak) then
        local target = math.min(md.ceiling, peak + c.step)
        if applyPeak(target, string.format("recovered, %.1f Hz for %ds", hz, highHoldSec)) then
            if target >= md.ceiling then md.governed = false end
            lastStepMs = now
            highHoldSec = 0
        end
    end
end

-- -------------------------------------------------------------------------
-- Sensor - effective tick rate on the wall clock
-- -------------------------------------------------------------------------

local function onTick()
    local c = cfg()

    -- Disable path: if the governor trimmed the peak and was then turned
    -- off, put the world back the way its operator configured it. Runs once.
    if not c.enabled then
        if not restoredOnBoot then
            restoredOnBoot = true
            local md = getStore()
            if md.governed and md.ceiling then
                applyPeak(md.ceiling, "governor disabled, restoring ceiling")
                md.governed = false
            end
        end
        return
    end
    restoredOnBoot = false

    if not announced then
        announced = true
        audit(string.format(
            "governor live: low<%.1fHz/%ds down, high>%.1fHz/%ds up, step %.2f, floor %.2f. Bridge check: watch for '[LZI] popman config pushed' on first step.",
            c.lowWater, c.holdDown, c.highWater, c.holdUp, c.step, c.floor))
    end

    local now = clockMs()
    if windowStartMs == nil then
        windowStartMs = now
        windowTicks = 0
        lastTickMs = now
        return
    end

    -- Freeze detection: a huge inter-tick gap means the PROCESS stalled, not
    -- the simulation. Restart the window so the gap never reads as load.
    if now - lastTickMs > FREEZE_GAP_MS then
        windowStartMs = now
        windowTicks = 0
        lastTickMs = now
        return
    end
    lastTickMs = now

    windowTicks = windowTicks + 1
    local elapsed = now - windowStartMs
    if elapsed >= WINDOW_SEC * 1000 then
        local hz = windowTicks / (elapsed / 1000)
        onWindow(hz, c)
        windowStartMs = now
        windowTicks = 0
    end
end

Events.OnTick.Add(onTick)
