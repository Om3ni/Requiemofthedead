-- RQWireHeadroom fixture - oversized-delta telemetry cannot block delivery,
-- and after 2026-08-19 that is guaranteed by ORDER at the call site rather
-- than by a guard here. See the note beside the last two assertions.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/server/RQWireHeadroom.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL RQWireHeadroom: " .. message)
    end
end

function isServer() return true end
function require() end

local estimate = 0
RDWire = { estimate = function() return estimate end }

local records = {}
local forensicFailure = nil
RDLog = {
    forensic = function(...)
        if forensicFailure then error(forensicFailure) end
        records[#records + 1] = { ... }
    end,
}

local realPrint = print
local warnings = {}
print = function(message) warnings[#warnings + 1] = tostring(message) end

RQWireHeadroom = nil
local loaded, loadErr = pcall(dofile, SOURCE)
check(loaded, "module loads: " .. tostring(loadErr))

estimate = 6144
RQWireHeadroom.observe({ changed = { a = {}, b = {} }, removed = { 1 } })
check(#records == 0, "deltas at the threshold do not emit telemetry")

estimate = 7000
RQWireHeadroom.observe({ changed = { a = {}, b = {} }, removed = { 1, 2, 3 } })
check(#records == 1, "oversized deltas emit one forensic record")
check(records[1][1] == "wire" and records[1][2] == "RQ.DELTA_LARGE"
    and records[1][5] == "RFTDDirge", "record preserves the forensic contract")
local payload = records[1][4]
check(payload.fp == "zombieDelta" and payload.est == 7000
    and payload.changed == 2 and payload.removed == 3, "record reports the measured delta shape")

-- The observer does NOT swallow a sink fault, and that is deliberate.
--
-- This fixture used to assert the opposite, with a stub made to error() where
-- the real RDLog.forensic cannot: its whole write path is RDJson.encode (total
-- for any payload) onto getFileWriter, which returns nil rather than throwing,
-- through a PrintWriter that records I/O errors internally - which is why Core
-- calls the same primitive bare (RDLog.lua:192-198). A stub more hostile than
-- the thing it stands in for was manufacturing the justification for a guard,
-- which CLAUDE.md section 2 names explicitly.
--
-- What actually protected delivery was never this pcall, it was ORDER, and the
-- order now lives at the call site: RQServer broadcasts the delta FIRST and
-- observes after (RQServer.lua:1365-1366), so no telemetry fault can reach the
-- send at all. These assertions pin the absence of the guard - re-add one and
-- they go red, and whoever adds it owes a reason.
forensicFailure = "fixture sink failure"
local escaped = not pcall(RQWireHeadroom.observe, { changed = {}, removed = {} })
check(escaped, "a forensic sink fault propagates rather than being swallowed")
check(#warnings == 0, "the observer prints nothing of its own, got " .. #warnings)

print = realPrint
print(string.format("RQWireHeadroom: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

