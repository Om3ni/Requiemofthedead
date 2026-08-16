-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDMeter.lua - network traffic telemetry: what the wire actually cost (server only).
--
-- Absorbed from OmenSpyNetwork (OSNMeter + OSNHooks_Server + OSNServer). OSN
-- stays published and standalone; this is Guardian's absorption pattern again.
--
-- WHY THIS EXISTS ALONGSIDE GUARDIAN, because they look like the same thing and
-- are not. RDGuardian is a RECEIVE-side sensor: it records that a client command
-- arrived, and its args, and answers "who sent what". It is structurally blind
-- to two directions that cost the server far more:
--
--   S2C    sendServerCommand - everything the server pushes out. No Lua event
--          fires for an outbound send, so the only way to see it is to wrap the
--          global.
--   MDATA  ModData.transmit - the global blob is fanned to EVERY connection with
--          no cap, so one N-byte transmit is N x clients on the wire. This is
--          the path that would have caught the ~74MB Deadband audit blob, and
--          nothing else in Core can see it at all.
--
-- So: Guardian gives content, RDMeter gives cost, and the C2S half of the cost
-- is folded INTO Guardian's existing record rather than duplicated here. OSN
-- registered a second OnClientCommand listener purely to size inbound traffic;
-- one listener on the hottest event in the game is enough, and it makes every
-- RD.CMD record carry its own weight. See RDGuardian's `est` field.
--
-- DEFAULT ON since 2026-08-13 (owner: all of the family's logging defaults
-- on - the record should already exist when a problem appears, and the wire3
-- findings only happened because a probe was running). When DISABLED the
-- wraps are NOT installed, not resident-and-no-oped: these wraps reassign
-- globals that every mod on the server calls, so an operator who turns the
-- probe off gets the engine's own functions back, not a sleeping shim. Flip
-- RFTDCore.WireProbeEnabled to disarm.
--
-- The wraps themselves are the safe shape: measure inside a pcall, then ALWAYS
-- `return orig(...)` with the exact varargs, so a probe fault can never block a
-- real network call and the optional-leading-player overload survives untouched.
-- Idempotency flags stop double-wrapping if this file is required twice.
--
-- INSTALL TIMING is deliberate: on the first OnTick, not at file scope. Two
-- reasons. SandboxVars is not reliably populated at load (RDLog documents the
-- same lazy-read constraint), and default-off needs the config BEFORE deciding
-- to touch a global. OnTick is also the only server event this family has proven
-- fires on a dedi. By the first tick, GlobalModData.init is long past - which is
-- what makes getOnlinePlayers() safe to call from the ModData wrap at all
-- (GameServer.udpEngine is null during IsoWorld.init and the resulting Java NPE
-- escapes pcall, logging as a hard error). The serverReady flag stays anyway:
-- transmit can be called from anywhere and the landmine is cheap to re-guard.

if not isServer() then return end

require "RDWire"
require "RDLog"

RDMeter = RDMeter or {}

local RATE_CALLS_SEC  = 20   -- calls/sec in a window past which a key is flagged
local ALERTS_PER_KEY  = 2    -- storm guard: instant alerts per key per window

local cfg       = nil        -- resolved once on first tick
local stats     = {}         -- "dir|key" -> { calls, bytes, maxSingle, alerts, dir, key, partial }
local lastDump  = 0
local installed = false

local serverReady = false
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
        enabled   = (sb("WireProbeEnabled") == true),
        dumpMs    = sbNum("WireProbeDumpSeconds", 30, 5, 600) * 1000,
        -- 25, not 12. At 12 the 2026-08-02 live capture truncated 194 of 722
        -- windows (one held 37 distinct keys), so better than a quarter of the
        -- reports silently under-counted the tail - and the tail is where a new
        -- offender shows up first. `keys` vs `shown` still records when it bites.
        topN      = sbNum("WireProbeTopN", 25, 1, 50),
        oversized = sbNum("WireProbeOversizedKB", 8, 1, 1024) * 1024,
    }
end

function RDMeter.enabled()
    return (cfg ~= nil) and cfg.enabled
end

-- ---------------------------------------------------------------------------
-- Aggregation
-- ---------------------------------------------------------------------------

-- dir: "C2S" | "S2C" | "MDATA"   key: "module:command" | "ModData:<tag>"
--
-- `args` is the payload itself and is optional, but pass it wherever it is in
-- hand: it is what lets RDWire tell a correctly-paged chunk from an unsplit
-- blob. Without it a declared stream still classifies (the declaration is keyed
-- by name), but an undeclared one carrying seq/total cannot be recognised.
function RDMeter.record(dir, key, est, partial, args)
    if not (cfg and cfg.enabled) then return end
    est = est or 0

    -- Bucketed by DIRECTION AND key, never key alone. The same command name
    -- legitimately travels both ways - a client asks, the server answers - and
    -- those are different payloads with different costs. Keyed by name only they
    -- merged into one row whose `dir` was whichever side recorded last, summing
    -- a 40-byte request into a 30 KB response and reporting the total under one
    -- arbitrary direction. That is how PhunZonesPlayerSetup read as a 693 KB
    -- C2S key in the 2026-08-02 capture while its own oversized events, which
    -- take dir straight from the call, correctly said S2C.
    local id = dir .. "|" .. key
    local s = stats[id]
    if not s then
        s = { calls = 0, bytes = 0, maxSingle = 0, alerts = 0,
              dir = dir, key = key, partial = false }
        stats[id] = s
    end
    s.calls     = s.calls + 1
    s.bytes     = s.bytes + est
    if est > s.maxSingle then s.maxSingle = est end
    if partial then s.partial = true end

    local v = RDWire.classify(key, est, partial, args, cfg.oversized)

    -- Chunk bookkeeping. `over` is the TRUE breach count for the window, which
    -- the alert counter below is not and was never able to be - it stops at
    -- ALERTS_PER_KEY, so a reader treating alert hits as a breach count reads
    -- back the cap (11 windows x 2 = "22 failures" on a key that breached 64
    -- times out of 64). Both numbers ship; only this one means what it says.
    if v.chunked ~= "no" then
        s.chunked = v.chunked
        s.chunks  = (s.chunks or 0) + 1
        if v.budget then s.chunkBudget = v.budget end
        if v.streamStart then s.streams = (s.streams or 0) + 1 end
    end
    if v.over then s.over = (s.over or 0) + 1 end

    -- A single payload over its ceiling is worth knowing about now, not in up
    -- to a full window's time. partial always alerts: too big to finish
    -- measuring is strictly worse news than merely large.
    if v.reason and s.alerts < ALERTS_PER_KEY then
        s.alerts = s.alerts + 1
        RDLog.forensic("wire", "RD.WIRE_OVERSIZED", nil, {
            dir     = tostring(dir),
            key     = tostring(key),
            est     = est,
            -- reason is the field to read. `partial` stays for the existing
            -- readers, but it answers "could we measure it", never "was it split".
            reason  = v.reason,
            chunked = v.chunked,
            budget  = v.budget,
            ceiling = v.ceiling,
            seq     = v.seq,
            total   = v.total,
            partial = partial and true or false,
        }, "RFTDCore")
    end
end

-- Top-N by total bytes over the window, then reset. Structured rows, not a
-- formatted table: OSN wrote human-readable text because it owned its own log
-- file, but this lands in the forensic ring as a JSONL envelope, so it stays
-- queryable. `est`/`estPerSec` are named to keep the approximation honest.
-- windowSec is passed in, not derived from lastDump: the caller has already
-- advanced lastDump to now, so reading it here would always measure zero and
-- silently fall back to the nominal cadence. Rates would look right and be wrong.
function RDMeter.dump(now, windowSec)
    if not (cfg and cfg.enabled) then return end
    if type(windowSec) ~= "number" or windowSec <= 0 then windowSec = cfg.dumpMs / 1000 end

    -- s.key is set at creation; the table key is "dir|key" and is not the label.
    local rows = {}
    for _, s in pairs(stats) do
        rows[#rows + 1] = s
    end
    if #rows == 0 then return end

    table.sort(rows, function(a, b) return a.bytes > b.bytes end)

    local out = {}
    local n = math.min(cfg.topN, #rows)
    for i = 1, n do
        local r = rows[i]
        local rate = r.calls / windowSec
        out[i] = {
            dir       = tostring(r.dir),
            key       = tostring(r.key),
            calls     = r.calls,
            callsSec  = rate,
            est       = r.bytes,
            estPerSec = r.bytes / windowSec,
            maxSingle = r.maxSingle,
            highRate  = (rate > RATE_CALLS_SEC) or nil,
            partial   = r.partial or nil,
            -- Paging shape, so a report can say "declared paged, 4096 B budget,
            -- 64 of 64 chunks over, 3 streams" instead of guessing from size.
            -- All nil-when-absent: a key that never paged adds no fields.
            chunked     = r.chunked or nil,
            chunkBudget = r.chunkBudget or nil,
            chunks      = r.chunks or nil,
            streams     = r.streams or nil,
            over        = r.over or nil,
        }
    end

    RDLog.forensic("wire", "RD.WIRE_TOP", nil, {
        windowSec = windowSec,
        keys      = #rows,
        shown     = n,
        rows      = out,
    }, "RFTDCore")

    stats = {}
end

-- ---------------------------------------------------------------------------
-- Capture wraps
-- ---------------------------------------------------------------------------

local function installWraps()
    -- OUTBOUND: server -> client(s). No event exists for this; the wrap is the
    -- only way to see it.
    if sendServerCommand and not RDMeter._wrapSSC then
        RDMeter._wrapSSC = true
        local orig = sendServerCommand
        sendServerCommand = function(...)
            local a1, a2, a3, a4 = ...
            pcall(function()
                local m, c, args = RDWire.parseSend(a1, a2, a3, a4)
                if m and c then
                    local est, partial = RDWire.commandEstimate(m, c, args)
                    RDMeter.record("S2C", tostring(m) .. ":" .. tostring(c), est, partial, args)
                end
            end)
            return orig(...)
        end
    end

    -- GLOBAL MOD-DATA: the full blob goes to every connection uncapped, so the
    -- honest cost is blob x recipients. This is the one path with no other
    -- visibility anywhere in Core.
    if ModData and ModData.transmit and not RDMeter._wrapMD then
        RDMeter._wrapMD = true
        local orig = ModData.transmit
        ModData.transmit = function(tag)
            pcall(function()
                local t = ModData.getOrCreate and ModData.getOrCreate(tag)
                local est, partial = RDWire.estimate(t)
                est = est + #tostring(tag) + 2
                local n = 1
                if serverReady then
                    -- guarded: the result drives the divisor below - n stays 1 when the roster is
                    -- not available yet, rather than the rate being computed against nil.
                    local ok, players = pcall(getOnlinePlayers)
                    if ok and players then
                        local sz = players:size()
                        if type(sz) == "number" and sz > 0 then n = sz end
                    end
                end
                RDMeter.record("MDATA", "ModData:" .. tostring(tag), est * n, partial)
            end)
            return orig(tag)
        end
    end
end

-- ---------------------------------------------------------------------------
-- One listener: first-tick install, then the throttled dump.
-- ---------------------------------------------------------------------------

local waitedTicks = 0

Events.OnTick.Add(function()
    if not installed then
        -- DO NOT LATCH AN ABSENT SANDBOX (2026-08-07). This used to resolve
        -- config unconditionally on the first tick: if SandboxVars.RFTDCore was
        -- not populated yet, `enabled` latched false and stayed false for the
        -- whole session - the probe off, silently, with the sandbox file saying
        -- ON. So: wait until the table actually exists, or the server says it
        -- has finished starting, or ~10s of ticks have passed (the backstop for
        -- a world with no RFTDCore sandbox page at all). Whichever comes first
        -- is the moment the answer is real rather than merely early.
        waitedTicks = waitedTicks + 1
        local haveSandbox = (SandboxVars ~= nil) and type(SandboxVars.RFTDCore) == "table"
        if not haveSandbox and not serverReady and waitedTicks < 600 then return end

        installed = true
        cfg = resolveConfig()
        if cfg.enabled then
            installWraps()
            print("[RFTDCore] RDMeter armed: wire probe on, dump every "
                .. tostring(cfg.dumpMs / 1000) .. "s, top " .. tostring(cfg.topN)
                .. ", oversized > " .. tostring(cfg.oversized) .. "B -> forensic stream 'wire'.")
            -- The stream's birth certificate: one record the moment the probe
            -- arms, so forensic/wire/ exists and is proven writable BEFORE any
            -- traffic arrives. An armed probe over an idle server produces no
            -- dumps (nothing to dump), and without this line that state is
            -- indistinguishable from broken - which is precisely the misread
            -- that burned a day in 2026-08-07's "logging is shattered" hunt.
            RDLog.forensic("wire", "RD.WIRE_ARMED", nil, {
                dumpSec   = cfg.dumpMs / 1000,
                topN      = cfg.topN,
                oversized = cfg.oversized,
            }, "RFTDCore")
            -- Flushed now rather than on the next cadence, so the directory
            -- exists the moment the armed line prints and the two cannot
            -- disagree. pcall'd like every logging touch.
            pcall(function() RDLog.flush() end)
        else
            -- OFF IS SAID OUT LOUD, once. A silent default-off is how "the
            -- probe is off" gets diagnosed as "logging is shattered": no wire
            -- directory, no console line, nothing to distinguish disabled from
            -- broken. One sentence closes that hole.
            print("[RFTDCore] RDMeter: wire probe OFF"
                .. " (RFTDCore.WireProbeEnabled=false; flip it and restart to arm)")
        end
        return
    end
    if not cfg.enabled then return end
    local now = RDShared.nowMs()
    if now == 0 then return end
    if now - lastDump < cfg.dumpMs then return end
    local prev = lastDump
    lastDump = now
    -- First pass only establishes the window start; there is no elapsed period
    -- to compute rates against yet.
    if prev == 0 then return end
    -- No guard: tail of an engine-dispatched handler, and Event.trigger already
    -- isolates each listener (Event.java:53-63). A dump fault costs this window.
    RDMeter.dump(now, (now - prev) / 1000)
end)

return RDMeter

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
