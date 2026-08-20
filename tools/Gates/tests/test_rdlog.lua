-- test_rdlog.lua - behavioural tests for RDLog's immutable forensic archive.
--
-- Runs against an in-memory filesystem standing in for the engine's cache-dir
-- file APIs. The contract pinned here is the forensic one that matters:
--
--   * a closed archive file is never reopened, truncated, or reclaimed;
--   * UTC time windows start fresh files without depending on saved counters;
--   * restarts and same-millisecond filename collisions preserve both copies;
--   * line/byte thresholds roll to a new part instead of dropping evidence;
--   * pre-archive ring and legacy files remain byte-for-byte untouched;
--   * a missing clock can only create an undated file, never erase one;
--   * refused writers remain visible through the failure counter/self-test.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rdlog.lua <repo-root>

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua"

-- --------------------------------------------------------------------------
-- In-memory filesystem + engine stubs
-- --------------------------------------------------------------------------

local FS = {}
local TRUNCATES = {}

function isServer() return true end

function getFileWriter(path, _, append)
    if not append then
        FS[path] = ""
        TRUNCATES[path] = (TRUNCATES[path] or 0) + 1
    end
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

Events = {
    OnTick         = { Add = function() end },
    EveryOneMinute = { Add = function() end },
}

SandboxVars = { RFTDCore = {} }

-- 2026-08-07 00:00 UTC, aligned to the default four-hour window.
local EPOCH0 = 1786060800
local CLOCK  = EPOCH0
local function setClock(sec) CLOCK = sec end
local function setHours(h) CLOCK = EPOCH0 + math.floor(h * 3600) end

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
local function loadRDLog()
    require = function(name)
        if name == "RDShared" then return RDShared end
        return realRequire(name)
    end
    local loaded, err = pcall(dofile, BASE .. "/server/RDLog.lua")
    require = realRequire
    if not loaded then
        print("FATAL: could not load RDLog.lua")
        print("  " .. tostring(err))
        os.exit(2)
    end
end

loadRDLog()

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

local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
    end
end

local function filesFor(name)
    local prefix = "RFTD/forensic/" .. name .. "/"
    local suffix = "." .. name .. ".jsonl.log"
    local out = {}
    for path in pairs(FS) do
        if path:sub(1, #prefix) == prefix
           and path:sub(-#suffix) == suffix
           and path:sub(#prefix + 1):find("/", 1, true) then
            out[#out + 1] = path
        end
    end
    table.sort(out)
    return out
end

local function lineCount(content)
    return select(2, (content or ""):gsub("\n", ""))
end

local function totalLines(paths)
    local n = 0
    for i = 1, #paths do n = n + lineCount(FS[paths[i]]) end
    return n
end

local function headPath(name) return "RFTD/forensic/" .. name .. "/head.txt" end

local function headFields(name)
    local out = {}
    for field in (FS[headPath(name)] or ""):gmatch("[^\t\r\n]+") do
        out[#out + 1] = field
    end
    return out
end

local function reboot()
    loadRDLog()
end

local LINE100 = string.rep("x", 99)

SandboxVars.RFTDCore.ForensicSegmentHours = 4
SandboxVars.RFTDCore.ForensicSegmentLines = 100000
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536

-- --------------------------------------------------------------------------
-- First write: dated immutable path + advisory current pointer
-- --------------------------------------------------------------------------

setHours(0)
RDLog.legacyLine("first", "one")
RDLog.flush()
local firstFiles = filesFor("first")
eq("first write creates one archive part", #firstFiles, 1)
ok("archive is sharded into a UTC date folder",
   firstFiles[1] and firstFiles[1]:find("/2026%-08%-07/2026%-08%-07_00%-00%-00Z_"),
   firstFiles[1])
eq("first part is numbered 000",
   firstFiles[1] and firstFiles[1]:match("_(%d%d%d)%.first%.jsonl%.log$"), "000")
eq("first record landed", FS[firstFiles[1]], "one\n")
local firstHead = headFields("first")
eq("head uses the archive pointer schema", firstHead[1], "v2")
eq("head names the actual current path", firstHead[2], firstFiles[1])
eq("head records current line count", tonumber(firstHead[3]), 1)
eq("archive data was never opened in truncate mode", TRUNCATES[firstFiles[1]], nil)

RDLog.legacyLine("first", "two")
RDLog.flush()
eq("same process and window append to the active part", #filesFor("first"), 1)
eq("the append preserves the first record", FS[firstFiles[1]], "one\ntwo\n")

-- --------------------------------------------------------------------------
-- Time rollover preserves the previous window
-- --------------------------------------------------------------------------

setHours(4)
RDLog.legacyLine("first", "next window")
RDLog.flush()
local timeFiles = filesFor("first")
eq("crossing the UTC boundary creates another file", #timeFiles, 2)
eq("the old window remains byte-for-byte intact", FS[firstFiles[1]], "one\ntwo\n")
eq("all records survive the time rollover", totalLines(timeFiles), 3)
for i = 1, #timeFiles do
    eq("time rollover never truncates archive part " .. i, TRUNCATES[timeFiles[i]], nil)
end

-- --------------------------------------------------------------------------
-- Restart and collision survival
-- --------------------------------------------------------------------------

setHours(8)
reboot() -- capture this exact millisecond as the process session token
RDLog.legacyLine("restart", "before restart")
RDLog.flush()
local beforeRestart = filesFor("restart")[1]

-- Reload at the exact same millisecond. A timestamp alone would collide; the
-- cache probe must choose a suffix and preserve the original file.
reboot()
RDLog.legacyLine("restart", "after restart")
RDLog.flush()
local restartFiles = filesFor("restart")
eq("same-millisecond restart creates a second file", #restartFiles, 2)
eq("restart never appends to the prior process file", FS[beforeRestart], "before restart\n")
eq("both restart records survive", totalLines(restartFiles), 2)
ok("collision suffix is visible in one filename",
   (restartFiles[1]:find("%-1_000%.restart%.jsonl%.log$")
    or restartFiles[2]:find("%-1_000%.restart%.jsonl%.log$")) ~= nil,
   table.concat(restartFiles, " | "))

-- --------------------------------------------------------------------------
-- Size and line thresholds roll; they never drop
-- --------------------------------------------------------------------------

reboot()
SandboxVars.RFTDCore.ForensicSegmentKB = 1
setHours(12)
for _ = 1, 10 do RDLog.legacyLine("bytes", LINE100) end
RDLog.flush()
RDLog.legacyLine("bytes", LINE100)
RDLog.flush()
local byteFiles = filesFor("bytes")
eq("byte threshold creates another part", #byteFiles, 2)
eq("byte threshold preserves every line", totalLines(byteFiles), 11)
eq("first byte part stays at its original content", #FS[byteFiles[1]], 1000)
eq("overflow is written to the next part", #FS[byteFiles[2]], 100)

reboot()
SandboxVars.RFTDCore.ForensicSegmentKB    = 65536
SandboxVars.RFTDCore.ForensicSegmentLines = 5
setHours(16)
for _ = 1, 5 do RDLog.legacyLine("lines", "tiny") end
RDLog.flush()
RDLog.legacyLine("lines", "one more")
RDLog.flush()
local lineFiles = filesFor("lines")
eq("line threshold creates another part", #lineFiles, 2)
eq("line threshold preserves every record", totalLines(lineFiles), 6)

-- A single buffered batch larger than the target must land whole. The target
-- controls handling size; it is never permission to discard a batch.
reboot()
SandboxVars.RFTDCore.ForensicSegmentLines = 5
setHours(20)
for i = 1, 10 do RDLog.legacyLine("batch", "b" .. i) end
RDLog.flush()
eq("oversized first batch is written whole", totalLines(filesFor("batch")), 10)
RDLog.legacyLine("batch", "after batch")
RDLog.flush()
eq("the following record rolls instead of disappearing", #filesFor("batch"), 2)
eq("oversized batch plus following record all survive", totalLines(filesFor("batch")), 11)

-- --------------------------------------------------------------------------
-- Migration: old ring/legacy files are immutable history
-- --------------------------------------------------------------------------

reboot()
SandboxVars.RFTDCore.ForensicSegmentLines = 100000
setHours(24)
local oldRing = "RFTD/forensic/migrate/000.migrate.jsonl.log"
local oldBare = "RFTD/forensic/migrate/000.jsonl.log"
local legacy  = "RFTD/forensic/migrate/000.jsonl"
FS[oldRing], FS[oldBare], FS[legacy] = "ring evidence\n", "bare evidence\n", "legacy evidence\n"
FS[headPath("migrate")] = "0 99 999 1\n"
RDLog.legacyLine("migrate", "new archive evidence")
RDLog.flush()
eq("named ring segment is untouched", FS[oldRing], "ring evidence\n")
eq("bare ring segment is untouched", FS[oldBare], "bare evidence\n")
eq("pre-42.20 legacy segment is untouched", FS[legacy], "legacy evidence\n")
eq("new evidence uses one dated archive file", #filesFor("migrate"), 1)
eq("archive writer never truncates an old ring path", TRUNCATES[oldRing], nil)

-- --------------------------------------------------------------------------
-- Missing clock: undated is safe, recovery rotates forward
-- --------------------------------------------------------------------------

reboot()
setClock(0)
RDLog.legacyLine("noclock", "undated evidence")
RDLog.flush()
local noClockFiles = filesFor("noclock")
eq("missing clock still creates one archive file", #noClockFiles, 1)
ok("missing clock uses an explicit undated folder",
   noClockFiles[1] and noClockFiles[1]:find("/undated/undated_", 1, true), noClockFiles[1])
setHours(28)
RDLog.legacyLine("noclock", "dated evidence")
RDLog.flush()
local recoveredFiles = filesFor("noclock")
eq("clock recovery starts a dated file", #recoveredFiles, 2)
eq("clock recovery preserves both records", totalLines(recoveredFiles), 2)
eq("undated evidence remains untouched", FS[noClockFiles[1]], "undated evidence\n")

-- --------------------------------------------------------------------------
-- Refused writers remain loud and measurable
-- --------------------------------------------------------------------------

reboot()
setHours(32)
eq("no failures on a healthy filesystem", RDLog.writeFailures(), 0)
eq("self-test passes while writes work", RDLog.selfTest(), true)
eq("a passing self-test is not a failure", RDLog.writeFailures(), 0)

local said = {}
local realPrint = print
local realWriter = getFileWriter
print = function(s) said[#said + 1] = tostring(s) end
getFileWriter = function() return nil end

RDLog.legacyLine("refused", "line one")
RDLog.flush()
local afterOne = RDLog.writeFailures()
RDLog.legacyLine("refused", "line two")
RDLog.flush()
local afterTwo = RDLog.writeFailures()
local broken = RDLog.selfTest()

getFileWriter = realWriter
print = realPrint

ok("refused archive writes are counted", afterOne > 0, afterOne)
ok("refused archive writes keep counting", afterTwo > afterOne,
   tostring(afterOne) .. " -> " .. tostring(afterTwo))
eq("self-test fails while the writer is refused", broken, false)
eq("refused records do not fabricate archive files", #filesFor("refused"), 0)

local criticalLogLines = 0
for i = 1, #said do
    if said[i]:find("CRITICAL", 1, true) and said[i]:find(".log file", 1, true) then
        criticalLogLines = criticalLogLines + 1
    end
end
eq("refusal diagnostic is bounded once per extension", criticalLogLines, 1)
eq("self-test recovers with the writer", RDLog.selfTest(), true)

print(string.format("test_rdlog: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
