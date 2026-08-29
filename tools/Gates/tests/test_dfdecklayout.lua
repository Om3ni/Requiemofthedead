-- DFDeckLayout fixture - the exact verified engine file contract.
--
-- The stubs model what LuaManager actually does, per CLAUDE.md's rule that a
-- fixture must implement the surface it stands in for:
--   getFileWriter  -> nil on a denied path/failed open, never a throw
--   LuaFileWriter  -> write/close delegate to PrintWriter and never raise
--   getFileReader  -> nil when absent; otherwise a real BufferedReader whose
--                     readLine/close CANNOT throw into Lua. BufferedReader is
--                     an exposed class (LuaManager.java:1651), so an
--                     IOException inside either is a Java BODY throw that
--                     MethodCaller swallows, returning nil
--                     (MethodCaller.java:33-56).
-- Corrected 2026-08-19: this fixture used to inject error() into readLine and
-- close, modelling an event that cannot happen and holding production to two
-- guards that could never fire. A read fault reaches Lua as EARLY EOF and is
-- indistinguishable from a genuinely short file, which is what is modelled now.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/shared/DFDeckLayout.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        realPrint("FAIL DFDeckLayout: " .. message)
    end
end

-- ---- engine stubs -------------------------------------------------------
local writerMode, writes, opened = "ok", {}, {}
function getFileWriter(filename, createIfNull, append)
    opened[#opened + 1] = { filename = filename, createIfNull = createIfNull, append = append }
    if writerMode == "nil" then return nil end
    return {
        write = function(_, s) writes[#writes + 1] = s end,
        close = function() end,
    }
end

local readerLines, readerMode, closeCount = {}, "ok", 0
function getFileReader(filename, createIfNull)
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
print = function(s) logged[#logged + 1] = tostring(s) end

-- DFFile is loaded for real, not stubbed: the read boundary now lives there,
-- and these assertions are worth more exercising the composed pair.
require = function() return true end
DFFile, DFDeckLayout = nil, nil
-- The REAL RDFile (write mechanism since 2026-08-25).
dofile(ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/RDFile.lua")
local okf = pcall(dofile, ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/shared/DFFile.lua")
local ok, err = pcall(dofile, SOURCE)
print = realPrint
check(okf, "DFFile loads")
check(ok, "module loads: " .. tostring(err))

-- ---- save ---------------------------------------------------------------
local n = DFDeckLayout.save("DFDeck_layout.txt", {
    zones = { w = 800.7, h = 600.2 },
})
check(n == 1, "save reports one written row")
check(#opened == 1 and opened[1].filename == "DFDeck_layout.txt"
      and opened[1].createIfNull == true and opened[1].append == false,
      "opens the supplied file create-and-truncate")
check(writes[1] == "zones w=800 h=600\n", "floors both dimensions into the per-tab line")

-- A malformed record must not cost its peers their size. This is the defect
-- the old blanket pcall hid: math.floor(nil) threw and aborted the whole walk.
writes, opened = {}, {}
n = DFDeckLayout.save("f.txt", {
    a = { w = 100, h = 100 },
    bad = { w = nil, h = 50 },
    c = { w = 200, h = 200 },
})
check(n == 2, "skips the malformed row and still writes both good peers")
local joined = table.concat(writes)
check(joined:find("a w=100 h=100", 1, true) and joined:find("c w=200 h=200", 1, true),
      "neither surviving row is lost to the bad one")

writerMode = "nil"
check(DFDeckLayout.save("denied.exe", {}) == nil, "a denied path is the engine's nil, not an exception")
writerMode = "ok"

-- ---- load ---------------------------------------------------------------
readerMode = "nil"
local sizes = DFDeckLayout.load("missing.txt")
check(type(sizes) == "table" and next(sizes) == nil, "absent file loads as empty defaults")

readerMode = "ok"
readerLines = { "zones w=800 h=600", "players w=1024 h=768", "w= h=", nil }
closeCount = 0
sizes = DFDeckLayout.load("f.txt")
check(sizes.zones and sizes.zones.w == 800 and sizes.zones.h == 600, "parses a per-tab row")
check(sizes.players and sizes.players.w == 1024, "parses every well-formed row")
check(sizes["w="] == nil, "the legacy single-line format is forgotten, not adopted")
check(closeCount == 1, "the reader is closed on the clean path")

-- A read fault mid-file. MethodCaller has already swallowed the IOException, so
-- what Lua sees is the sequence stopping early - the deck keeps the rows it got.
-- Three of four sizes restored beats none, which is the documented intent.
readerMode = "ok"
readerLines = { "a w=10 h=10", "b w=20 h=20", "c w=30 h=30" }
closeCount, logged = 0, {}
print = function(s) logged[#logged + 1] = tostring(s) end
sizes = DFDeckLayout.load("bad.txt")
print = realPrint
check(sizes.a and sizes.b and sizes.c, "rows parsed before the fault survive it")
check(sizes.never == nil, "nothing past the fault is invented")
check(closeCount == 1, "a truncated read still closes the reader - no leaked handle")
check(#logged == 0,
      "no diagnostic: this is indistinguishable from a clean short file, so claiming a fault would be a lie")

-- The close call is unconditional and costs the caller nothing. There is no
-- close fault to inject for the same reason as above.
readerLines = { "a w=10 h=10" }
closeCount, logged = 0, {}
print = function(s) logged[#logged + 1] = tostring(s) end
sizes = DFDeckLayout.load("c.txt")
print = realPrint
check(sizes.a and sizes.a.w == 10, "the close call does not cost the caller its parsed rows")
check(closeCount == 1, "close is called exactly once")

realPrint(string.format("DFDeckLayout: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
