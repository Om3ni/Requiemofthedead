-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMMoon.lua - the moon phase, read once and watched (shared).
--
-- WHY THE MOON COSTS NOTHING ON THE WIRE. The engine derives the phase from
-- the in-game CALENDAR DATE - ClimateMoon.getMoonPhase is an epact/almanac
-- formula over (year, month, day), ~29.5-day cycle, recomputed every game
-- minute server-side (ClimateManager.java:804, ungated) and identically on
-- every client, whose clocks the server syncs. Two machines asking at the
-- same moment get the same answer, so phase-conditional resolution follows
-- §6.1 rule 1: derived, never transmitted. Each side runs its own watcher and
-- refreshes its own resolved store; the worst divergence is one watcher
-- period, and it heals itself.
--
-- THE ENGINE SURFACE, verified in the 42.20.2 decompile rather than assumed:
-- getClimateMoon() is an ungated global (LuaManager:9053) returning the
-- ClimateMoon singleton; getCurrentMoonPhase() is an int 0..7. Every field on
-- the class is a private instance field - Kahlua sees METHODS ONLY, so no
-- .currentPhase shortcuts. getMoonFloat() is symmetric about full (0.75 means
-- both gibbous phases) and can never identify a phase; getPhaseName() is
-- hardcoded English and never enters the store. OnDusk/OnDawn are registered
-- but DEAD in 42.20 (their only trigger site is commented out in vanilla's
-- season.lua), so the watcher rides EveryTenMinutes with a cached diff -
-- the phase only moves at a date change, so even that is generous.
--
-- WHY A PROVIDER HOOK AND NOT A DIRECT CALL. Two resolvers gate on the phase
-- (LMCore.flattenChain and LMEdit:effective), the engine-free test suite has
-- no getClimateMoon at all, and "what phase is it" must have exactly one
-- answer per machine. So the answer lives behind one function - real engine
-- read by default, test override via setProvider - and everything else asks
-- Limes.moonPhase(). nil means "unknowable", and resolution treats a phased
-- profile as INACTIVE then: deterministic, identical on both sides (they
-- call the same API and fail the same way), and the honest reading of
-- "off-phase contributes nothing" when there is no phase to be on.

require "LMCore"

LMMoon = LMMoon or {}

-- Canonical store vocabulary. Engine ints are the identity; these names are
-- what the .ini and the phases field carry. Fixed English on purpose - it is
-- STORAGE, not display; UI labels get translation keys of their own.
LMMoon.PHASES = {
    [0] = "new",
    [1] = "waxing_crescent",
    [2] = "first_quarter",
    [3] = "waxing_gibbous",
    [4] = "full",
    [5] = "waning_gibbous",
    [6] = "last_quarter",
    [7] = "waning_crescent",
}

-- token -> set of ints. Group aliases cover the common intents ("the moon is
-- growing") without eight-token lists; bare digits are accepted because an
-- admin who has read the engine's 0..7 should not be punished for using it.
local TOKENS = {}
for i = 0, 7 do
    TOKENS[LMMoon.PHASES[i]] = { [i] = true }
    TOKENS[tostring(i)]      = { [i] = true }
end
TOKENS["waxing"] = { [1] = true, [2] = true, [3] = true }
TOKENS["waning"] = { [5] = true, [6] = true, [7] = true }

function LMMoon.phaseName(phase)
    return phase ~= nil and LMMoon.PHASES[phase] or nil
end

-- "full, waning_gibbous" -> { [4]=true, [5]=true }. Returns nil for nil/"",
-- which callers read as "no condition - always active". Unknown tokens are
-- skipped (validate warns; resolution must not die on admin-typed data), so a
-- value whose EVERY token is junk yields an EMPTY set - never active. "" means
-- always; garbage does not.
function LMMoon.parsePhases(str)
    if str == nil or str == "" then return nil end
    local set = {}
    for token in tostring(str):gmatch("[^,]+") do
        token = token:match("^%s*(.-)%s*$"):lower()
        local ints = TOKENS[token]
        if ints then
            for i in pairs(ints) do set[i] = true end
        end
    end
    return set
end

-- Are any of the tokens in `str` unknown? The validate-side companion to the
-- forgiving parser above: resolution skips junk silently, this names it.
function LMMoon.unknownTokens(str)
    local bad = {}
    if str == nil or str == "" then return bad end
    for token in tostring(str):gmatch("[^,]+") do
        token = token:match("^%s*(.-)%s*$"):lower()
        if token ~= "" and not TOKENS[token] then bad[#bad + 1] = token end
    end
    return bad
end

-- ---------------------------------------------------------------------------
-- The provider
-- ---------------------------------------------------------------------------

local provider = nil       -- test/override hook; wins when set
local warnedNoClock = false
local warnedProviderFault = false

-- Tests (and anything else that needs a deterministic sky) inject here.
-- fn() -> int 0..7 or nil. Pass nil to restore the engine read.
function LMMoon.setProvider(fn)
    provider = fn
    warnedProviderFault = false
end

-- The one answer to "what phase is it" on this machine. 0..7, or nil when the
-- engine cannot say (headless test, boot too early, API gone). Sanitized:
-- anything outside 0..7 is treated as unknowable rather than passed through
-- to become a phase no profile can name.
function Limes.moonPhase()
    if provider then
        -- pcall: `provider` is injected from outside this file (tests, an
        -- admin console) and its body is not ours to verify. It may run on
        -- every watcher poll, so report its first failure without flooding.
        local ok, p = pcall(provider)
        if not ok then
            if not warnedProviderFault then
                warnedProviderFault = true
                print("[Limes] moon provider failed; phase-conditional profiles are"
                    .. " INACTIVE until it recovers: " .. tostring(p))
            end
            return nil
        end
        p = tonumber(p)
        if p and p >= 0 and p <= 7 then return math.floor(p) end
        if p ~= nil and not warnedProviderFault then
            warnedProviderFault = true
            print("[Limes] moon provider returned an invalid phase; phase-conditional"
                .. " profiles are INACTIVE until it recovers: " .. tostring(p))
        end
        return nil
    end
    -- No guard, and both halves of the old reason were wrong. getClimateMoon
    -- can never return nil: it hands back a static-final singleton built at
    -- class load (ClimateMoon.java:18-22, exposed at LuaManager.java:9053-9056)
    -- with no ClimateManager dependency. getCurrentMoonPhase is a bare
    -- primitive read (:48-50) - before the climate system's first tick it
    -- returns 0, which is "New", a VALID phase. We inherit that ambiguity from
    -- the engine: a pre-tick read is indistinguishable from a real new moon,
    -- and profiles gated on "new" open a minute early at worst.
    local phase = tonumber(getClimateMoon():getCurrentMoonPhase())
    if phase and phase >= 0 and phase <= 7 then return math.floor(phase) end
    if not warnedNoClock then
        warnedNoClock = true
        print("[Limes] moon phase unavailable - phase-conditional profiles are"
            .. " INACTIVE until it is (getClimateMoon missing or not ready)")
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The watcher - each machine refreshes its own resolution when its own sky
-- changes. No wire, no coordination; see the header for why that is safe.
--
-- EveryTenMinutes is GAME time (DayLength-compressed - at a 1-hour day about
-- every 2.5 real seconds), which sounds absurdly frequent for a value that
-- moves every ~3.7 game days until you price it: one integer compare against
-- an upvalue. The refresh itself only runs on an actual change, and diffs to
-- nothing when no zone resolves differently.
-- ---------------------------------------------------------------------------

local lastPhase = nil

local function watch()
    local phase = Limes.moonPhase()
    if phase == lastPhase then return end
    local from = lastPhase
    lastPhase = phase
    -- Refresh on EVERY observed change, including the first (nil -> real). If
    -- the store was applied after the clock was ready, that first refresh
    -- diffs to nothing and costs a walk; if it was applied BEFORE (phased
    -- profiles resolved inactive because the phase was unknowable), this is
    -- the moment they switch on. The content diff makes the cheap case free
    -- and the necessary case correct, so there is no seed special-case to
    -- get wrong.
    print("[Limes] moon phase " .. (LMMoon.phaseName(from) or "unknown")
        .. " -> " .. (LMMoon.phaseName(phase) or "unknown") .. " - re-resolving zones")
    Limes.refresh()
end

-- Exposed so tests (and a curious admin at the debug console) can drive the
-- watcher without waiting for game time.
function LMMoon.poll() watch() end

if Events and Events.EveryTenMinutes then
    -- No guard here: it never protected the fan-out it claimed to. watch() calls
    -- Limes.refresh(), and a listener that throws aborts the remaining listeners
    -- either way - a guard at THIS boundary cannot resume a loop further in. The
    -- event itself is already safe (Event.trigger, Event.java:53-63). If the
    -- fan-out needs to survive one bad listener, the guard belongs inside
    -- Limes.refresh's loop, where it would buy per-listener granularity.
    Events.EveryTenMinutes.Add(function() watch() end)
end

return LMMoon

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
