-- test_rdlog.lua - behavioural tests for RDLog's forensic ring under real Lua 5.1.
--
-- Runs against an in-memory filesystem standing in for getFileWriter /
-- getFileReader / cacheFileExists / listFilesInZomboidLuaDirectory, so the ring
-- arithmetic is exercised without a game. Only the FORENSIC path is covered;
-- chronicle needs RDEvents/RDSeasonServer/RDIdentity and is a separate concern.
-- RDLog.legacyLine is the entry point used throughout because it pushes a raw
-- string - no envelope machinery, so a rotation test stays a rotation test.
--
-- WHAT THIS PINS, and why (all three were live defects before 2026-08-02):
--
--   BYTES  the ring bounded LINES while disk is spent in BYTES. Record size
--          spans an order of magnitude between streams, so "20000 lines" meant
--          4 MB for one stream and 30+ MB for another. Raising RDMeter's topN
--          from 12 to 25 the same day roughly doubled wire line size and would
--          have silently doubled the footprint with no setting changed.
--   ORPHANS  seg = (seg+1) % ring only ever visits 0..ring-1, so lowering the
--          ring stranded the segments above it holding their bytes forever.
--   CLAMP  a head written under a larger ring named a segment outside the
--          current one; the stream would append there, then wrap inside the
--          ring and never return, orphaning a full segment.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdlog.lua <repo-root>

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"

-- --------------------------------------------------------------------------
-- In-memory filesystem + engine stubs
-- --------------------------------------------------------------------------

local FS = {}   -- path -> content string

function isServer() return true end

function getFileWriter(path, _, append)
    if not append then FS[path] = "" end
    if FS[path] == nil then FS[path] = "" end
    return {
        write = function(_, s) FS[path] = FS[path] .. s end,
        close = function() end,
    }
end

function getFileReader(path)
    local content = FS[path]
    if content == nil then return nil end
    local pos = 1
    return {
        readLine = function()
            if pos > #content then return nil end
            local nl = content:find("\n", pos, true)
            local line
            if nl then line = content:sub(pos, nl - 1); pos = nl + 1
            else line = content:sub(pos); pos = #content + 1 end
            return line
        end,
        close = function() end,
    }
end

function cacheFileExists(path) return FS[path] ~= nil end

-- Mirrors the engine: bare filenames, non-recursive, directories skipped,
-- and a Java list (size()/get(i), 0-indexed) rather than a Lua table.
function listFilesInZomboidLuaDirectory(dir)
    local prefix = dir .. "/"
    local names = {}
    for path in pairs(FS) do
        if path:sub(1, #prefix) == prefix then
            local rest = path:sub(#prefix + 1)
            if not rest:find("/", 1, true) then names[#names + 1] = rest end
        end
    end
    table.sort(names)
    return {
        size = function() return #names end,
        get  = function(_, i) return names[i + 1] end,
    }
end

Events = {
    OnTick         = { Add = function() end },
    EveryOneMinute = { Add = function() end },
}

SandboxVars = { RFTDCore = {} }

local RDShared = {
    DIR        = "RFTD/",
    EXT_STREAM = ".jsonl.log",
    EXT_DOC    = ".json.txt",
    nowMs      = function() return 0 end,
    nowSec     = function() return 0 end,
    gameDay    = function() return 0 end,
}
_G.RDShared = RDShared

local realRequire = require
require = function(name)
    if name == "RDShared" then return RDShared end
    return realRequire(name)
end
local okLoad, err = pcall(dofile, BASE .. "/server/RDLog.lua")
require = realRequire
if not okLoad then
    print("FATAL: could not load RDLog.lua")
    print("  " .. tostring(err))
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

local function segPath(name, seg)
    return "RFTD/forensic/" .. name .. "/" .. string.format("%03d", seg) .. "." .. name .. ".jsonl.log"
end
local function headPath(name) return "RFTD/forensic/" .. name .. "/head.txt" end
local function headSeg(name)
    local h = FS[headPath(name)] or ""
    return tonumber(h:match("^(%d+)"))
end

local LINE100 = string.rep("x", 99)   -- 99 chars + newline = 100 bytes on disk

-- --------------------------------------------------------------------------
-- Byte-bounded rotation
-- --------------------------------------------------------------------------

SandboxVars.RFTDCore.ForensicRingSegments = 4
SandboxVars.RFTDCore.ForensicSegmentLines = 100000    -- never trips: bytes must
SandboxVars.RFTDCore.ForensicSegmentKB    = 1         -- 1024 bytes per segment

for _ = 1, 10 do RDLog.legacyLine("bytes", LINE100) end
RDLog.flush()
eq("under the byte cap, still on segment 0", headSeg("bytes"), nil)  -- head not yet written
eq("segment 0 holds 10 lines", #FS[segPath("bytes", 0)], 1000)

RDLog.legacyLine("bytes", LINE100)   -- 1100 bytes total, over the 1024 cap
RDLog.flush()
eq("byte cap rolls to segment 1", headSeg("bytes"), 1)
eq("the filled segment keeps its content", #FS[segPath("bytes", 0)], 1100)
eq("the new segment is truncated to zero", FS[segPath("bytes", 1)], "")
isTrue("head records bytes as a third field",
       (FS[headPath("bytes")] or ""):match("^%d+%s+%d+%s+%d+") ~= nil,
       FS[headPath("bytes")])

-- --------------------------------------------------------------------------
-- Line cap still works when bytes are generous
-- --------------------------------------------------------------------------

SandboxVars.RFTDCore.ForensicSegmentLines = 5
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536     -- effectively unbounded
for _ = 1, 5 do RDLog.legacyLine("lines", "tiny") end
RDLog.flush()
eq("line cap still rolls a segment", headSeg("lines"), 1)

-- --------------------------------------------------------------------------
-- The ring wraps rather than growing without end
--
-- Flushed per segment-fill on purpose: rotation is evaluated ONCE per flush, not
-- per line, so a buffer holding several segments' worth still advances a single
-- segment. That is by design and bounded - a buffer is at most BUF_MAX (25)
-- lines - but it means a test that pushes 8 lines and flushes once is testing
-- the buffer, not the ring.
-- --------------------------------------------------------------------------

SandboxVars.RFTDCore.ForensicSegmentLines = 2
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536
for _ = 1, 4 do
    RDLog.legacyLine("wrap", "l")
    RDLog.legacyLine("wrap", "l")
    RDLog.flush()
end
eq("ring wraps back to segment 0", headSeg("wrap"), 0)
isTrue("no segment beyond the ring was created",
       FS[segPath("wrap", 4)] == nil, "segment 004 exists outside a 4-ring")
eq("wrapping truncated segment 0 rather than appending", FS[segPath("wrap", 0)], "")

-- Overshoot is bounded by the buffer, never unbounded: one flush past the cap
-- advances exactly one segment.
SandboxVars.RFTDCore.ForensicSegmentLines = 2
for _ = 1, 8 do RDLog.legacyLine("overshoot", "l") end
RDLog.flush()
eq("a single oversized flush advances exactly one segment", headSeg("overshoot"), 1)

-- --------------------------------------------------------------------------
-- Orphan reclaim after the ring is lowered
-- --------------------------------------------------------------------------

-- Segments left by a previous, larger ring, plus files that must NOT be touched.
for s = 0, 7 do FS[segPath("shrunk", s)] = "stale" end
FS[headPath("shrunk")] = "0 0 0\n"
FS["RFTD/forensic/shrunk/notes.txt"]           = "keep me"
FS["RFTD/forensic/shrunk/004.shrunk.jsonl"]    = "legacy, keep"

SandboxVars.RFTDCore.ForensicRingSegments = 4
SandboxVars.RFTDCore.ForensicSegmentLines = 100000
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536
RDLog.legacyLine("shrunk", "trigger the load")
RDLog.flush()

eq("segment inside the ring is left alone", FS[segPath("shrunk", 3)], "stale")
eq("segment 4 outside the ring is reclaimed", FS[segPath("shrunk", 4)], "")
eq("segment 7 outside the ring is reclaimed", FS[segPath("shrunk", 7)], "")
eq("head.txt is not mistaken for a segment", FS["RFTD/forensic/shrunk/notes.txt"], "keep me")
eq("a legacy .jsonl orphan is not touched",
   FS["RFTD/forensic/shrunk/004.shrunk.jsonl"], "legacy, keep")

-- --------------------------------------------------------------------------
-- A head naming a segment outside the current ring is clamped
-- --------------------------------------------------------------------------

FS[headPath("clamp")]      = "6 10 500\n"
FS[segPath("clamp", 6)]    = "exists so the self-heal probe passes"
SandboxVars.RFTDCore.ForensicRingSegments = 4
RDLog.legacyLine("clamp", "x")
RDLog.flush()
isTrue("out-of-ring head is clamped back inside the ring",
       (headSeg("clamp") or 99) < 4, "seg=" .. tostring(headSeg("clamp")))

-- --------------------------------------------------------------------------
-- Two-field heads from before the bytes column still load
-- --------------------------------------------------------------------------

FS[headPath("oldhead")]   = "2 5\n"
FS[segPath("oldhead", 2)] = "existing"
SandboxVars.RFTDCore.ForensicRingSegments = 8
SandboxVars.RFTDCore.ForensicSegmentLines = 100000
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536
RDLog.legacyLine("oldhead", "y")
RDLog.flush()
eq("a legacy two-field head resumes on its own segment", headSeg("oldhead"), 2)
isTrue("the legacy segment was appended to, not truncated",
       (FS[segPath("oldhead", 2)] or ""):sub(1, 8) == "existing",
       FS[segPath("oldhead", 2)])

print(string.format("test_rdlog: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
