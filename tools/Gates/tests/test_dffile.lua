-- DFFile fixture - Dragonfly's single engine file-read boundary.
--
-- WHAT THE STUBS MODEL, and why this file was rewritten 2026-08-19:
--
-- The old fixture injected `error("java.io.IOException: read error")` into
-- readLine and close, on the doctrine that a BufferedReader fault reaches Lua
-- as a throw. That doctrine is dead and DFFile.lua's own header now says so:
-- getFileReader hands back a real java.io.BufferedReader, but BufferedReader is
-- an EXPOSED class (LuaManager.java:1651), so an IOException inside readLine or
-- close is a Java BODY throw - MethodCaller swallows it, stack-traces it to the
-- console, and the call returns nil (MethodCaller.java:33-56).
--
-- So the fixture was asserting a physically impossible event, which is exactly
-- what CLAUDE.md sect. 2 forbids, and it was holding production hostage to two
-- guards that could never fire. Production correctly dropped them, along with
-- the `complete` second return value they fed - which was always true.
--
-- THE CONTRACT THIS NOW PINS: from Lua, a read fault is INDISTINGUISHABLE from
-- end-of-file. Both present as readLine returning nil and the loop ending. That
-- indistinguishability is the property worth testing, because the moment
-- someone believes they can tell the two apart they will write a guard that
-- never fires, or a `complete` flag that is always true, all over again.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/shared/DFFile.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL DFFile: " .. message) end
end

-- readerLines is what the reader yields. A nil inside the sequence IS the
-- fault model: early EOF. There is deliberately no "throw" mode - see above.
local readerLines, readerMode, closeCount, opened = {}, "ok", 0, {}
function getFileReader(filename, createIfNull)
    opened[#opened + 1] = { filename = filename, createIfNull = createIfNull }
    if readerMode == "nil" then return nil end
    local i = 0
    return {
        readLine = function()
            i = i + 1
            return readerLines[i]
        end,
        close = function() closeCount = closeCount + 1 end,
    }
end

local logged = {}
local function capture() print = function(s) logged[#logged + 1] = tostring(s) end end
local function release() print = realPrint end

require = function() return true end
DFFile = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- absent file
readerMode = "nil"
check(DFFile.readLines("missing.txt") == nil, "an absent or denied file is nil, not an empty table")
check(opened[1].createIfNull == false, "never asks the engine to create the file")

-- clean read
readerMode, readerLines, closeCount = "ok", { "one", "two", "three" }, 0
local lines = DFFile.readLines("f.txt")
check(#lines == 3 and lines[1] == "one" and lines[3] == "three", "reads every line in order")
check(closeCount == 1, "closes the reader on the clean path")

-- The contract is ONE return value. A second one coming back means someone has
-- reintroduced a completeness signal that the engine cannot actually supply.
local _, extra = DFFile.readLines("f.txt")
check(extra == nil, "returns lines only - no completeness flag the reader cannot support")

-- empty file
readerLines, closeCount = {}, 0
lines = DFFile.readLines("empty.txt")
check(#lines == 0, "an empty file reads as no lines")
check(closeCount == 1, "an empty file still closes the reader")

-- Read fault mid-file. MethodCaller has already swallowed the IOException and
-- returned nil, so this is what Lua actually sees: the sequence just stops.
readerMode, readerLines, closeCount, logged = "ok", { "a", "b" }, 0, {}
capture(); lines = DFFile.readLines("bad.txt"); release()
check(#lines == 2 and lines[1] == "a" and lines[2] == "b", "lines read before the fault are returned")
check(closeCount == 1, "a truncated read still closes the reader - no leaked handle")
check(#logged == 0, "no diagnostic: Lua cannot tell this from a clean short file, so claiming a fault would be a lie")

-- The indistinguishability itself. A genuinely short file and a file cut off by
-- an I/O fault must produce byte-identical results, because from Lua they ARE
-- the same event. If these ever diverge, something is inventing information.
readerLines, closeCount = { "a", "b" }, 0
local truncated = DFFile.readLines("truncated.txt")
readerLines, closeCount = { "a", "b" }, 0
local short = DFFile.readLines("short.txt")
check(#truncated == #short and truncated[1] == short[1] and truncated[2] == short[2],
      "a fault-truncated read and a genuinely short read are indistinguishable")

-- A close fault is the same lane: swallowed by MethodCaller, returns nil, and
-- the caller keeps its lines. Nothing to inject, so what is pinned instead is
-- that close is always reached and the lines survive it.
readerLines, closeCount, logged = { "a", "b" }, 0, {}
capture(); lines = DFFile.readLines("c.txt"); release()
check(#lines == 2, "the close call never costs the caller its recovered lines")
check(closeCount == 1, "close is called exactly once, not per line")

realPrint(string.format("DFFile: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
