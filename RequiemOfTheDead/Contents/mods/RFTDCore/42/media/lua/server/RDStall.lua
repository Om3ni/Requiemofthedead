-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDStall.lua - tick-stall watchdog: how long the server actually froze (server only).
--
-- WHY THIS EXISTS ALONGSIDE RDMeter, because they look like the same thing and
-- are not. RDMeter answers "what did the wire cost". It is structurally blind to
-- the symptom players actually report, which is that the box stopped for a
-- second. A mod can freeze the tick without sending a single byte, and the
-- heaviest key on the wire (2026-08-09: newmusic_device at 344 MB) can be
-- incapable of freezing anything because its largest single message is 1.5 KB.
-- Bytes and stalls are different axes and the wire report cannot rank the second.
--
-- WHAT THIS IS NOT. It does not attribute. It measures the gap between
-- consecutive OnTicks and says how big it was, with enough context to line the
-- gap up against other streams afterwards. Deliberately:
--
--   * The engine already attributes LUA stalls, and better than Lua can.
--     Event.trigger times every callback when DebugOptions checks.SlowLuaEvents
--     is on and warns with `closure.prototype.file` - the actual mod file - past
--     250 ms. Lua cannot see inside another mod's callback, so anything this
--     file guessed would be worse. Run that for Lua attribution; run this for
--     the total, which is the number SlowLuaEvents cannot give you because it
--     never sees engine work or a GC pause.
--   * "The last send before the stall" is not evidence, it is a coincidence with
--     a plausible shape. Attribution belongs in the reader, correlating this
--     stream against `wire` on the envelope's shared `t`, where a human can see
--     how often the two actually co-occur.
--
-- So the three instruments answer three different questions and only overlap by
-- design: GC log = did the JVM stop the world. SlowLuaEvents = which mod file
-- burned the time. This = how long the tick was gone in total. A stall that
-- appears here and in NEITHER of the others is engine work - chunk save, cell
-- scan, cull - which is a diagnosis by elimination no single sensor can make.
--
-- DEFAULT ON, like the rest of the family's logging: the record should already
-- exist when a problem appears. The cost is one subtraction per tick.
--
-- INSTALL TIMING copies RDMeter exactly - first OnTick, not file scope, because
-- SandboxVars is not reliably populated at load and getOnlinePlayers() is a Java
-- NPE (escaping pcall) while GameServer.udpEngine is still null during
-- IsoWorld.init. serverReady gates every engine read below for that reason.

if not isServer() then return end

require "RDShared"   -- nowMs; RDLog pulls it too, but this file calls it directly
require "RDLog"

RDStall = RDStall or {}

-- A delta this large is not a stall, it is the process not running: a suspended
-- VM, a host that slept, a segment resumed after the server was down. Recording
-- it as a stall would put a 40-minute "freeze" in the same bucket as a 300 ms
-- hitch and poison every mean. It is still worth a record - it BOUNDS DOWNTIME,
-- which nothing else in the family emits - so it goes out flagged as a resume
-- rather than being dropped or averaged in.
local RESUME_MS = 30000

local ALERTS_PER_WINDOW = 12  -- storm guard; the summary still carries the true count

local cfg         = nil
local installed   = false
local serverReady = false

local lastMs      = 0
local ticks       = 0
local sumMs       = 0
local maxMs       = 0
local stalls      = 0
local resumes     = 0
local alerts      = 0
local windowStart = 0

if Events.OnServerStarted then
    Events.OnServerStarted.Add(function() serverReady = true end)
end

-- ---------------------------------------------------------------------------
-- Config (sandbox-tunable, read once when the world is up)
-- ---------------------------------------------------------------------------

local function sb(key)
    return SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore[key]
end

local function sbNum(key, default, lo, hi)
    local v = sb(key)
    if type(v) ~= "number" then return default end
    if lo and v < lo then return lo end
    if hi and v > hi then return hi end
    return v
end

local function resolveConfig()
    return {
        enabled = (sb("StallWatchEnabled") ~= false),
        -- 250 ms to match the engine's own SlowLuaEvents threshold. Same number
        -- on both sensors means a stall recorded here and a SLOW callback logged
        -- there are directly comparable instead of needing a fudge factor.
        stallMs   = sbNum("StallWatchMs", 250, 50, 10000),
        summaryMs = sbNum("StallSummarySeconds", 300, 30, 3600) * 1000,
    }
end

function RDStall.enabled()
    return (cfg ~= nil) and cfg.enabled
end

-- ---------------------------------------------------------------------------
-- Context
--
-- Only read on an alert or a summary, never per tick: these are engine calls and
-- this file's whole claim is that it costs one subtraction in the common case.
-- Each is independently pcall'd and defaults to -1, because "we could not count"
-- and "there were none" are different facts and a reader must be able to tell
-- them apart. -1 also survives the JSON round trip where nil would vanish.
-- ---------------------------------------------------------------------------

local function playerCount()
    if not serverReady then return -1 end
    local n = -1
    pcall(function()
        local players = getOnlinePlayers()
        if players then n = players:size() end
    end)
    return n
end

local function zombieCount()
    if not serverReady then return -1 end
    local n = -1
    -- Same idiom as RPCore.lua:268 - one server-wide IsoCell, so getCell() with
    -- no player argument is the server's whole zombie list.
    pcall(function()
        local zlist = getCell():getZombieList()
        if zlist then n = zlist:size() end
    end)
    return n
end

-- ---------------------------------------------------------------------------
-- Emit
-- ---------------------------------------------------------------------------

-- The window summary is what makes a single stall interpretable. "900 ms" means
-- nothing without knowing that this server's normal tick is 16 ms, and it means
-- something very different if the normal tick is 400 ms. It also carries the
-- true stall count, so capping alerts above never hides how bad a window was.
local function emitSummary(now)
    local elapsed = now - windowStart
    if elapsed <= 0 or ticks <= 0 then return end

    RDLog.forensic("perf", "RD.TICK_SUMMARY", nil, {
        windowSec = math.floor(elapsed / 1000),
        ticks     = ticks,
        meanMs    = math.floor((sumMs / ticks) * 10 + 0.5) / 10,
        maxMs     = maxMs,
        stalls    = stalls,
        resumes   = resumes,
        dropped   = (stalls > alerts) and (stalls - alerts) or 0,
        thresholdMs = cfg.stallMs,
        players   = playerCount(),
        zombies   = zombieCount(),
    }, "RFTDCore")

    ticks, sumMs, maxMs, stalls, resumes, alerts = 0, 0, 0, 0, 0, 0
    windowStart = now
end

local function emitStall(ms, isResume)
    RDLog.forensic("perf", isResume and "RD.RESUME" or "RD.STALL", nil, {
        ms      = ms,
        players = playerCount(),
        zombies = zombieCount(),
    }, "RFTDCore")
end

-- ---------------------------------------------------------------------------
-- The tick
-- ---------------------------------------------------------------------------

Events.OnTick.Add(function()
    if not installed then
        installed = true
        cfg = resolveConfig()
        if not cfg.enabled then return end
        lastMs      = RDShared.nowMs()
        windowStart = lastMs
        return
    end
    if not (cfg and cfg.enabled) then return end

    local now = RDShared.nowMs()
    if now <= 0 then return end

    -- First armed tick, or a clock that went backwards (NTP step, host resume).
    -- Re-baseline rather than record a negative or absurd delta as data.
    if lastMs <= 0 or now < lastMs then
        lastMs = now
        return
    end

    local delta = now - lastMs
    lastMs = now

    ticks  = ticks + 1
    sumMs  = sumMs + delta
    if delta > maxMs then maxMs = delta end

    if delta >= RESUME_MS then
        resumes = resumes + 1
        -- Resumes bypass the alert cap: they are rare by construction and each
        -- one is a downtime boundary, which is exactly the record the coverage
        -- gaps in every wire report have never been able to explain.
        emitStall(delta, true)
        -- The window spanned an outage, so its mean is meaningless. Close it out
        -- and start clean rather than reporting an average across a dead server.
        ticks, sumMs, maxMs, stalls, alerts = 0, 0, 0, 0, 0
        windowStart = now
    elseif delta >= cfg.stallMs then
        stalls = stalls + 1
        if alerts < ALERTS_PER_WINDOW then
            alerts = alerts + 1
            emitStall(delta, false)
        end
    end

    if now - windowStart >= cfg.summaryMs then
        emitSummary(now)
    end
end)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
