-- test_rdmeter.lua - behavioural tests for RDMeter's aggregation under real Lua 5.1.
--
-- RDMeter is server-gated and engine-facing, so unlike RDWire it needs stubs:
-- isServer, Events, SandboxVars, RDShared and RDLog. They are deliberately the
-- thinnest possible - enough to reach RDMeter.record and RDMeter.dump, nothing
-- more - because the thing under test is the aggregation, not the wraps.
--
-- WHAT THIS PINS, and why it exists at all: RDMeter bucketed by key alone until
-- 2026-08-02, so a command name that travels BOTH ways - a client asks, the
-- server answers - collapsed into a single row. Bytes from a 40-byte request and
-- a 30 KB response were summed, and `dir` reported whichever side recorded last.
-- PhunZonesPlayerSetup read as a 693 KB C2S key in the live capture while its own
-- oversized events correctly said S2C. Nothing in-game breaks when this
-- regresses; the traffic report just quietly lies about who is talking. Pin it.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdmeter.lua <repo-root>

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"

-- --------------------------------------------------------------------------
-- Stubs
-- --------------------------------------------------------------------------

function isServer() return true end

local tickHandlers = {}
Events = {
    OnTick         = { Add = function(_, f) end },
    OnServerStarted= { Add = function(_, f) end },
}
-- PZ's Events.X.Add is called as a dot-call with one arg in this file.
Events.OnTick.Add          = function(f) tickHandlers[#tickHandlers + 1] = f end
Events.OnServerStarted.Add = function(f) end

SandboxVars = { RFTDCore = {
    WireProbeEnabled     = true,
    WireProbeDumpSeconds = 30,
    -- left unset on purpose: the code default is what we are asserting
    WireProbeOversizedKB = 8,
} }

RDShared = { nowMs = function() return 0 end }

local emitted = {}
RDLog = { forensic = function(stream, event, _, payload)
    emitted[#emitted + 1] = { stream = stream, event = event, payload = payload }
end }

-- RDMeter does `require "RDWire"`; point require at the real file so the
-- estimator under test is the shipped one, not a fake.
local realRequire = require
require = function(name)
    if name == "RDWire" then return dofile(BASE .. "/shared/RDWire.lua") end
    if name == "RDLog"  then return RDLog end
    return realRequire(name)
end

local okLoad, err = pcall(dofile, BASE .. "/server/RDMeter.lua")
require = realRequire
if not okLoad then
    print("FATAL: could not load RDMeter.lua")
    print("  " .. tostring(err))
    os.exit(2)
end

-- Arm it: cfg resolves on the first tick.
if #tickHandlers == 0 then print("FATAL: RDMeter registered no OnTick handler"); os.exit(2) end
tickHandlers[1]()

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end
local function isTrue(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(detail)) end
end

-- The birth certificate: arming must emit one RD.WIRE_ARMED into the wire
-- stream immediately, so an armed probe over an idle server is distinguishable
-- from a broken one - forensic/wire/ exists before any traffic does.
isTrue("arming emits RD.WIRE_ARMED",
    emitted[1] and emitted[1].stream == "wire" and emitted[1].event == "RD.WIRE_ARMED",
    emitted[1] and (tostring(emitted[1].stream) .. "/" .. tostring(emitted[1].event)) or "nothing emitted")
eq("the armed record carries the dump cadence", emitted[1] and emitted[1].payload.dumpSec, 30)

local function dumpRows()
    emitted = {}
    RDMeter.dump(30000, 30)
    for _, e in ipairs(emitted) do
        if e.event == "RD.WIRE_TOP" then return e.payload end
    end
    return nil
end
local function rowFor(rows, dir, key)
    for _, r in ipairs(rows) do
        if r.dir == dir and r.key == key then return r end
    end
    return nil
end

-- --------------------------------------------------------------------------
-- The regression: same key, both directions
-- --------------------------------------------------------------------------

RDMeter.record("C2S", "Mod:Setup", 40, false)
RDMeter.record("S2C", "Mod:Setup", 30000, false)

local p = dumpRows()
isTrue("a dump was emitted", p ~= nil, "no RD.WIRE_TOP event")
eq("both directions survive as separate rows", p and p.keys, 2)

local c2s = rowFor(p.rows, "C2S", "Mod:Setup")
local s2c = rowFor(p.rows, "S2C", "Mod:Setup")
isTrue("C2S row exists", c2s ~= nil, "missing C2S row")
isTrue("S2C row exists", s2c ~= nil, "missing S2C row")
eq("C2S bytes are not inflated by the response", c2s and c2s.est, 40)
eq("S2C bytes are not diluted by the request",   s2c and s2c.est, 30000)
eq("C2S maxSingle stays on its own side", c2s and c2s.maxSingle, 40)
eq("S2C maxSingle stays on its own side", s2c and s2c.maxSingle, 30000)
eq("key label is the bare key, not the dir|key bucket id", c2s and c2s.key, "Mod:Setup")

-- --------------------------------------------------------------------------
-- Same direction still aggregates (the bucketing must not over-split)
-- --------------------------------------------------------------------------

RDMeter.record("S2C", "Mod:Ping", 10, false)
RDMeter.record("S2C", "Mod:Ping", 30, false)
p = dumpRows()
local ping = rowFor(p.rows, "S2C", "Mod:Ping")
eq("repeat calls on one direction aggregate", ping and ping.calls, 2)
eq("repeat calls sum their bytes",            ping and ping.est,   40)
eq("maxSingle is the largest single call",    ping and ping.maxSingle, 30)

-- --------------------------------------------------------------------------
-- MDATA is its own direction, never merged into S2C
-- --------------------------------------------------------------------------

RDMeter.record("S2C",   "ModData:Zones", 100, false)
RDMeter.record("MDATA", "ModData:Zones", 5000, false)
p = dumpRows()
eq("MDATA does not merge into S2C", p.keys, 2)
eq("MDATA row keeps its own bytes",
   (rowFor(p.rows, "MDATA", "ModData:Zones") or {}).est, 5000)

-- --------------------------------------------------------------------------
-- The dump resets, so windows do not accumulate across reports
-- --------------------------------------------------------------------------

RDMeter.record("S2C", "Mod:Once", 5, false)
dumpRows()
emitted = {}
RDMeter.dump(60000, 30)
local second = nil
for _, e in ipairs(emitted) do if e.event == "RD.WIRE_TOP" then second = e.payload end end
eq("an empty window emits nothing", second, nil)

-- --------------------------------------------------------------------------
-- topN default: 25 after the 2026-08-02 truncation finding (was 12)
-- --------------------------------------------------------------------------

for i = 1, 40 do RDMeter.record("S2C", "Bulk:k" .. i, i, false) end
p = dumpRows()
eq("all 40 keys are counted", p.keys, 40)
eq("topN default shows 25",   p.shown, 25)
isTrue("rows are ranked by bytes descending",
       p.rows[1].est > p.rows[#p.rows].est,
       "rows not sorted")

print(string.format("test_rdmeter: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
