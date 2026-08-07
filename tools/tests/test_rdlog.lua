-- test_rdlog.lua - behavioural tests for RDLog's forensic ring under real Lua 5.1.
--
-- Runs against an in-memory filesystem standing in for getFileWriter /
-- getFileReader / cacheFileExists / listFilesInZomboidLuaDirectory, so the ring
-- arithmetic is exercised without a game. Only the FORENSIC path is covered;
-- chronicle needs RDEvents/RDSeasonServer/RDIdentity and is a separate concern.
-- RDLog.legacyLine is the entry point used throughout because it pushes a raw
-- string - no envelope machinery, so a rotation test stays a rotation test.
--
-- WHAT THIS PINS, and why:
--
--   CLOCK  (2026-08-05, the big one) rotation is a pure function of the wall
--          clock: seg = floor(now/period) % ring. The previous design rotated
--          on ACCUMULATED lines/bytes, and those counters live in a file-scope
--          Lua local that resets on every boot while the file keeps appending -
--          so on the live remote server the largest single run contributed 414
--          lines / 0.62 MB against gates of 20000 lines / 4 MB. The ring had
--          never rotated once, on any stream, on any server, and head.txt had
--          never been written. The tests below therefore drive the clock, not
--          the volume, and the RESTART cases matter most: a stream that is
--          torn down and rebuilt mid-period must resume its segment, and one
--          rebuilt in a later period must roll.
--   CEILING  lines/bytes are per-segment caps now, NOT triggers. Hitting one
--          drops records until the next period; it must never advance the
--          segment, because that would break "the file holding a moment can be
--          computed from that moment".
--   ORPHANS  seg = (seg+1) % ring only ever visits 0..ring-1, so lowering the
--          ring stranded the segments above it holding their bytes forever.
--   HEADS  every historical head shape (2, 3 and 4 field) still loads.
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

-- The test clock. RDLog derives its segment from nowSec(), so driving this is
-- how a rotation is provoked - never by writing more data.
--
-- EPOCH0 is a real epoch (2026-08-07 00:00 UTC) chosen so that its 4 h bucket
-- number is divisible by 96 - the largest ring the sandbox allows. That makes
-- `seg` equal `hours/4 % ring` for EVERY ring size a test might use, so the
-- expectations below read as plain arithmetic instead of carrying an offset.
-- It must also be non-zero: nowSec() == 0 is RDShared's "no clock" signal, and
-- RDLog treats that as "do not rotate, do not truncate" - which setClock(0)
-- below deliberately exercises.
local EPOCH0 = 124032 * 4 * 3600      -- 1786060800
local CLOCK  = EPOCH0
local function setClock(sec) CLOCK = sec end
local function setHours(h)   CLOCK = EPOCH0 + math.floor(h * 3600) end
-- The absolute bucket number at hour h - what head.txt actually stores. It is
-- absolute on purpose: two processes must agree on it without sharing state.
local function bucketAt(h)   return math.floor((EPOCH0 + h * 3600) / (4 * 3600)) end

local RDShared = {
    DIR        = "RFTD/",
    EXT_STREAM = ".jsonl.log",
    EXT_DOC    = ".json.txt",
    nowMs      = function() return CLOCK * 1000 end,
    nowSec     = function() return CLOCK end,
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
local function headNums(name)
    local out = {}
    for d in (FS[headPath(name)] or ""):gmatch("%d+") do out[#out + 1] = tonumber(d) end
    return out
end
local function headSeg(name)    return headNums(name)[1] end
local function headBucket(name) return headNums(name)[4] end

-- A SERVER RESTART. RDLog's `streams` table is a file-scope local, so
-- re-executing the file is exactly what a reboot does to it: in-memory
-- counters gone, the filesystem untouched. This is the scenario the old
-- design could not survive, so most of what follows is built on it.
local function reboot()
    require = function(name)
        if name == "RDShared" then return RDShared end
        return realRequire(name)
    end
    local ok, e = pcall(dofile, BASE .. "/server/RDLog.lua")
    require = realRequire
    if not ok then print("FATAL: reload failed: " .. tostring(e)); os.exit(2) end
end

local LINE100 = string.rep("x", 99)   -- 99 chars + newline = 100 bytes on disk


-- --------------------------------------------------------------------------
-- The head is written on the FIRST flush, not after 500 lines
--
-- This is the 2026-08-05 defect in one assertion. head.txt had never existed on
-- any stream on any server, because the only thing that wrote it was a
-- 500-line-per-boot counter that real traffic never reached.
-- --------------------------------------------------------------------------

SandboxVars.RFTDCore.ForensicSegmentHours = 4
SandboxVars.RFTDCore.ForensicRingSegments = 4
SandboxVars.RFTDCore.ForensicSegmentLines = 100000
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536

setHours(0)
RDLog.legacyLine("head", "first line ever")
RDLog.flush()
isTrue("head.txt exists after a single flush", FS[headPath("head")] ~= nil,
       "no head written")
eq("head names segment 0 in period 0", headSeg("head"), 0)
eq("head records the bucket", headBucket("head"), bucketAt(0))

-- --------------------------------------------------------------------------
-- Time rotates; volume does not
-- --------------------------------------------------------------------------

setHours(0)
for _ = 1, 50 do RDLog.legacyLine("time", LINE100) end
RDLog.flush()
eq("50 lines inside one period stay on segment 0", headSeg("time"), 0)
eq("segment 0 holds all 50", #FS[segPath("time", 0)], 5000)

setHours(3.9)                      -- still inside the first 4h window
RDLog.legacyLine("time", LINE100)
RDLog.flush()
eq("still segment 0 at 3.9h", headSeg("time"), 0)
eq("and it appended", #FS[segPath("time", 0)], 5100)

setHours(4)                        -- the boundary
RDLog.legacyLine("time", "period two")
RDLog.flush()
eq("crossing 4h rolls to segment 1", headSeg("time"), 1)
eq("the new bucket is recorded", headBucket("time"), bucketAt(4))
eq("the filled segment is left intact", #FS[segPath("time", 0)], 5100)
eq("segment 1 holds only the new period", FS[segPath("time", 1)], "period two\n")

-- --------------------------------------------------------------------------
-- RESTART SURVIVAL - the property the old design could not hold
-- --------------------------------------------------------------------------

setHours(8)
RDLog.legacyLine("boot", "before the crash")
RDLog.flush()
eq("segment 2 in period 2", headSeg("boot"), 2)

reboot()                           -- counters wiped, same period
setHours(9)
RDLog.legacyLine("boot", "after the crash")
RDLog.flush()
eq("a restart mid-period resumes the same segment", headSeg("boot"), 2)
isTrue("and APPENDS rather than truncating",
       FS[segPath("boot", 2)] == "before the crash\nafter the crash\n",
       FS[segPath("boot", 2)])

reboot()                           -- now a later period
setHours(12)
RDLog.legacyLine("boot", "new period")
RDLog.flush()
eq("a restart in a later period rolls", headSeg("boot"), 3)
eq("the previous segment is untouched by the roll",
   FS[segPath("boot", 2)], "before the crash\nafter the crash\n")

-- Many restarts inside one period must still produce exactly one segment.
for i = 1, 5 do
    reboot()
    setHours(12 + i * 0.1)
    RDLog.legacyLine("boot", "r" .. i)
    RDLog.flush()
end
eq("five restarts in one period do not advance the segment", headSeg("boot"), 3)
eq("every restart appended to the same file",
   select(2, FS[segPath("boot", 3)]:gsub("\n", "")), 6)

-- --------------------------------------------------------------------------
-- The segment is a pure function of the clock
--
-- Any moment maps to a known file without consulting any stored state, which is
-- what makes the scheme restart-proof in the first place.
-- --------------------------------------------------------------------------

SandboxVars.RFTDCore.ForensicRingSegments = 4
for _, case in ipairs({ {0,0}, {4,1}, {8,2}, {12,3}, {16,0}, {20,1}, {36,1} }) do
    reboot()
    setHours(case[1])
    RDLog.legacyLine("pure", "x")
    RDLog.flush()
    eq("hour " .. case[1] .. " maps to segment " .. case[2], headSeg("pure"), case[2])
end

-- --------------------------------------------------------------------------
-- The ring wraps and RECLAIMS - a full turn later, the file is reused, not
-- appended to. This is the only moment anything reclaims disk.
-- --------------------------------------------------------------------------

reboot()
setHours(0)
RDLog.legacyLine("wrap", "oldest")
RDLog.flush()
eq("wrap: segment 0 in period 0", headSeg("wrap"), 0)

reboot()
setHours(16)                       -- exactly one full ring (4 x 4h) later
RDLog.legacyLine("wrap", "newest")
RDLog.flush()
eq("a full turn returns to segment 0", headSeg("wrap"), 0)
eq("and the stale content was reclaimed, not appended to",
   FS[segPath("wrap", 0)], "newest\n")
isTrue("no segment outside the ring was ever created",
       FS[segPath("wrap", 4)] == nil, "segment 004 exists in a 4-ring")

-- --------------------------------------------------------------------------
-- Size settings are CEILINGS, not triggers
--
-- Hitting one must drop records and leave the segment where it is. Advancing
-- here would break the clock mapping proved above.
-- --------------------------------------------------------------------------

reboot()
SandboxVars.RFTDCore.ForensicSegmentKB    = 1        -- 1024 bytes
SandboxVars.RFTDCore.ForensicSegmentLines = 100000
setHours(0)
for _ = 1, 10 do RDLog.legacyLine("cap", LINE100) end
RDLog.flush()
eq("under the ceiling everything lands", #FS[segPath("cap", 0)], 1000)

RDLog.legacyLine("cap", LINE100)                     -- would exceed 1024
RDLog.flush()
eq("the over-ceiling flush is DROPPED, not written", #FS[segPath("cap", 0)], 1000)
eq("and the segment did NOT advance", headSeg("cap"), 0)

setHours(4)                                          -- next period clears it
RDLog.legacyLine("cap", "fresh period")
RDLog.flush()
eq("the next period rolls normally after a ceiling hit", headSeg("cap"), 1)
eq("and accepts records again", FS[segPath("cap", 1)], "fresh period\n")

-- The line ceiling behaves identically.
reboot()
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536
SandboxVars.RFTDCore.ForensicSegmentLines = 5
setHours(0)
for _ = 1, 5 do RDLog.legacyLine("lcap", "tiny") end
RDLog.flush()
RDLog.legacyLine("lcap", "one too many")
RDLog.flush()
eq("the line ceiling does not advance the segment", headSeg("lcap"), 0)
eq("and drops the overflow", select(2, FS[segPath("lcap", 0)]:gsub("\n", "")), 5)

-- --------------------------------------------------------------------------
-- A broken clock must not rotate and must NEVER truncate
-- --------------------------------------------------------------------------

reboot()
SandboxVars.RFTDCore.ForensicSegmentLines = 100000
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536
FS[headPath("noclock")]   = "2 10 500 7\n"
FS[segPath("noclock", 2)] = "precious\n"
setClock(0)                                          -- nowSec() == 0: unavailable
RDLog.legacyLine("noclock", "appended blind")
RDLog.flush()
eq("with no clock the head's segment is kept", headSeg("noclock"), 2)
isTrue("and the existing content is never truncated",
       FS[segPath("noclock", 2)]:sub(1, 8) == "precious",
       FS[segPath("noclock", 2)])

-- --------------------------------------------------------------------------
-- Orphan reclaim after the ring is lowered
-- --------------------------------------------------------------------------

reboot()
setHours(0)

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
-- An out-of-ring head is clamped - only reachable without a clock now, since
-- bucket % ring can never name a segment outside the ring.
-- --------------------------------------------------------------------------

reboot()
setClock(0)                                   -- no clock: the head is trusted
FS[headPath("clamp")]      = "6 10 500 3\n"
FS[segPath("clamp", 6)]    = "orphaned by a shrunken ring"
SandboxVars.RFTDCore.ForensicRingSegments = 4
RDLog.legacyLine("clamp", "x")
RDLog.flush()
isTrue("out-of-ring head is clamped back inside the ring",
       (headSeg("clamp") or 99) < 4, "seg=" .. tostring(headSeg("clamp")))

-- --------------------------------------------------------------------------
-- Every historical head shape still loads
--
-- Fields have only ever been appended, and the parser scans for integers rather
-- than matching positions, so a short head cannot shift the fields before it.
-- A head with NO bucket (two- or three-field, i.e. written before 2026-08-05)
-- cannot prove which period its segment holds, so the clock wins and the
-- segment is reclaimed - correct, and it costs at most one partial period.
-- --------------------------------------------------------------------------

for _, case in ipairs({ { "twofield", "2 5\n" }, { "threefield", "2 5 500\n" } }) do
    local nm, head = case[1], case[2]
    reboot()
    SandboxVars.RFTDCore.ForensicRingSegments = 8
    SandboxVars.RFTDCore.ForensicSegmentLines = 100000
    SandboxVars.RFTDCore.ForensicSegmentKB    = 65536
    FS[headPath(nm)]   = head
    FS[segPath(nm, 2)] = "from an unknown period\n"
    setHours(4)                                -- bucket 1 -> segment 1
    RDLog.legacyLine(nm, "y")
    RDLog.flush()
    eq(nm .. " head loads and the clock places it", headSeg(nm), 1)
    eq(nm .. " head gains a bucket on the next write", headBucket(nm), bucketAt(4))
    eq("the unknown-period segment is left where it was",
       FS[segPath(nm, 2)], "from an unknown period\n")
end

-- A four-field head from THIS period resumes without truncating.
reboot()
SandboxVars.RFTDCore.ForensicRingSegments = 8
FS[headPath("fourfield")]   = "1 3 30 " .. bucketAt(5) .. "\n"
FS[segPath("fourfield", 1)] = "same period\n"
setHours(5)                                    -- the bucket the head names
RDLog.legacyLine("fourfield", "more")
RDLog.flush()
eq("a same-period head resumes its segment", headSeg("fourfield"), 1)
eq("and appends to it", FS[segPath("fourfield", 1)], "same period\nmore\n")

print(string.format("test_rdlog: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
