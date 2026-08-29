-- SPDX-License-Identifier: GPL-3.0-or-later
-- test_lmchunk.lua - the baseline chunker: the store never leaves as one blob.
--
-- WHY THIS EXISTS: the wire probe caught RFTDLimes:baseline at 20 KB, S2C,
-- reason "unsplit" - our own telemetry flagging our own traffic on every
-- join. The fix pages baselines through LMSync.sliceZones, sized against
-- RDWire's own estimator (the same model the meter judges the result by,
-- Reaper's rule). This file pins the slicer's contract:
--
--   * every slice fits the budget (the entire point)
--   * every zone arrives exactly once, whole - a slicer that drops or
--     duplicates a zone corrupts the client's store silently
--   * deterministic: same store, same slices, every machine, every run
--   * an EMPTY store still yields ONE slice - the client needs total=1 to
--     know the stream completed (Reaper's lesson: an empty result that
--     sends nothing leaves the receiver waiting forever)
--   * a single zone LARGER than the budget ships alone and oversized
--     rather than vanishing - the meter names it, which is correct for a
--     record nothing can split
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmchunk.lua <repo-root>

local ROOT = arg[1] or "."
local LM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/"
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/"

-- LMSync's client half is the ELSE of the isServer() gate, so it loads here
-- and registers listeners; stub what it touches at file scope. The slicer is
-- the shared surface under test - the wire halves stay dormant no-ops.
function isServer() return false end
function isClient() return false end
local noop = { Add = function() end }
Events = { OnGameStart = noop, EveryOneMinute = noop,
           OnServerCommand = noop, OnTick = noop }
RDNet = { send = function() end, reply = function() end,
          broadcast = function() end, register = function() end,
          adopt = function() end }
Limes = Limes or {}

local realRequire = require
require = function() end
-- The REAL RDShared: LMSync registers the mod version at file scope now
-- (2026-08-25); same rule as the sixteen-stub sweep.
dofile(CORE .. "shared/RDShared.lua")
local okW, errW = pcall(dofile, CORE .. "shared/RDWire.lua")
local okS, errS = pcall(dofile, LM .. "shared/LMSync.lua")
require = realRequire
if not (okW and okS) then
    print("FATAL: could not load slicer deps")
    print("  " .. tostring(errW or "") .. " " .. tostring(errS or ""))
    os.exit(2)
end

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

-- A store shaped like the live one: many mid-sized zones.
local function makeStore(n)
    local zones = {}
    for i = 1, n do
        zones["Zone_" .. string.format("%03d", i)] = {
            inherits = "Hard",
            rects  = { { i * 100, i * 100, i * 100 + 50, i * 100 + 50 },
                       { i * 100 + 60, i * 100, i * 100 + 90, i * 100 + 30 } },
            fields = { tier = i % 6, title = "Zone number " .. i,
                       nobuilding = true, dirgeSpawnChance = 15,
                       dirgeScreamerWeight = 10, minSprinterRisk = 5 },
        }
    end
    return zones
end

local BUDGET = 3072
local store  = makeStore(45)
local slices = LMSync.sliceZones(store, BUDGET)

isTrue("a 45-zone store splits", #slices > 1, "slices " .. #slices)

-- Budget: every slice's own estimate fits.
local allFit = true
for i = 1, #slices do
    if slices[i].est > BUDGET then allFit = false end
end
isTrue("every slice fits the budget", allFit)

-- Conservation: every zone exactly once, record identity preserved.
local seen, dup, total = {}, 0, 0
for i = 1, #slices do
    for name, rec in pairs(slices[i].zones) do
        total = total + 1
        if seen[name] then dup = dup + 1 end
        seen[name] = rec
    end
end
eq("no zone is duplicated", dup, 0)
eq("every zone arrives", total, 45)
local whole = true
for name, rec in pairs(store) do
    if seen[name] ~= rec then whole = false end
end
isTrue("records ride by reference, unmangled", whole)

-- Determinism: a second pass slices identically.
local again = LMSync.sliceZones(store, BUDGET)
eq("same store, same slice count", #again, #slices)
local sameShape = true
for i = 1, #slices do
    for name in pairs(slices[i].zones) do
        if not again[i] or again[i].zones[name] == nil then sameShape = false end
    end
end
isTrue("same store, same slice membership", sameShape)

-- The empty store still completes a stream.
local empty = LMSync.sliceZones({}, BUDGET)
eq("an empty store yields exactly one slice", #empty, 1)
local none = true
for _ in pairs(empty[1].zones) do none = false end
isTrue("...and it is empty", none)

-- A monster record ships alone rather than vanishing.
local monster = { Whale = { rects = {}, fields = { title = string.rep("x", 6000) } },
                  Minnow = { rects = {}, fields = { tier = 1 } } }
local ms = LMSync.sliceZones(monster, BUDGET)
local whaleFound, whaleAlone = false, false
for i = 1, #ms do
    if ms[i].zones.Whale then
        whaleFound = true
        local n = 0
        for _ in pairs(ms[i].zones) do n = n + 1 end
        whaleAlone = (n == 1)
    end
end
isTrue("an unsplittable record still ships", whaleFound)
isTrue("...alone in its slice", whaleAlone)

-- The slice estimate tracks RDWire's model - the meter and the slicer must
-- agree on what a chunk weighs, or "declared paged, budget 3072" reports
-- breaches against a different ruler than the one that cut the pages.
local est = RDWire.estimate(slices[1].zones)
isTrue("slice estimate is grounded in RDWire's model",
    math.abs(slices[1].est - est) < 600,
    "slice says " .. slices[1].est .. ", RDWire says " .. est)

print(string.format("LMChunk: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
