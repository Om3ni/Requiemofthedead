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
-- DEFAULT OFF, and when off the wraps are NOT installed. OSN was a drop-in /
-- drop-out probe, so leaving hooks resident and no-oping the body was free. Core
-- is permanent, and these wraps reassign globals that every mod on the server
-- calls - owning `sendServerCommand` forever, for every mod, is not something
-- infrastructure should do unasked. Flip RFTDCore.WireProbeEnabled to arm it.
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
local stats     = {}         -- key -> { calls, bytes, maxSingle, alerts, dir, partial }
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
    local ok, v = pcall(function() return SandboxVars.RFTDCore and SandboxVars.RFTDCore[key] end)
    if ok then return v end
    return nil
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
        topN      = sbNum("WireProbeTopN", 12, 1, 50),
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
function RDMeter.record(dir, key, est, partial)
    if not (cfg and cfg.enabled) then return end
    est = est or 0

    local s = stats[key]
    if not s then
        s = { calls = 0, bytes = 0, maxSingle = 0, alerts = 0, dir = dir, partial = false }
        stats[key] = s
    end
    s.calls     = s.calls + 1
    s.bytes     = s.bytes + est
    s.dir       = dir
    if est > s.maxSingle then s.maxSingle = est end
    if partial then s.partial = true end

    -- A single payload over the threshold is worth knowing about now, not in up
    -- to a full window's time. partial always alerts: too big to finish
    -- measuring is strictly worse news than merely large.
    if (est > cfg.oversized or partial) and s.alerts < ALERTS_PER_KEY then
        s.alerts = s.alerts + 1
        RDLog.forensic("wire", "RD.WIRE_OVERSIZED", nil, {
            dir     = tostring(dir),
            key     = tostring(key),
            est     = est,
            partial = partial and true or false,
        })
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

    local rows = {}
    for key, s in pairs(stats) do
        rows[#rows + 1] = s
        s.key = key
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
        }
    end

    RDLog.forensic("wire", "RD.WIRE_TOP", nil, {
        windowSec = windowSec,
        keys      = #rows,
        shown     = n,
        rows      = out,
    })

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
                    RDMeter.record("S2C", tostring(m) .. ":" .. tostring(c), est, partial)
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
                    local ok, players = pcall(getOnlinePlayers)
                    if ok and players then
                        local ok2, sz = pcall(function() return players:size() end)
                        if ok2 and type(sz) == "number" and sz > 0 then n = sz end
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

Events.OnTick.Add(function()
    if not installed then
        installed = true
        cfg = resolveConfig()
        if cfg.enabled then
            installWraps()
            print("[RFTDCore] RDMeter armed: wire probe on, dump every "
                .. tostring(cfg.dumpMs / 1000) .. "s, top " .. tostring(cfg.topN)
                .. ", oversized > " .. tostring(cfg.oversized) .. "B -> forensic stream 'wire'.")
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
    pcall(RDMeter.dump, now, (now - prev) / 1000)
end)

return RDMeter
