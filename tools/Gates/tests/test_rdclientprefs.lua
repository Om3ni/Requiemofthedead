-- RDClientPrefs fixture - the flat key=value preference store, and the format
-- two mods now share.
--
-- WHY THIS EXISTS: this file is where a player's settings live, and the failure
-- mode of a preference format is SILENT. A reader that stops recognising a line
-- does not error - it falls through to the caller's default, and the setting
-- looks like it was never made. Promoting the store out of LRPrefs and OEPrefs
-- means one edit can now do that to both mods at once, so the round trip is
-- pinned here rather than discovered by someone whose toggles keep resetting.
--
-- STUBS MODEL THE VERIFIED SURFACE. getFileReader/getFileWriter are exposed
-- globals whose faults are swallowed by MethodCaller (MethodCaller.java:33-56)
-- and which signal failure by returning nil, so the fakes return nil rather
-- than throwing - and BufferedReader.readLine reports end of file as nil
-- (LuaManager.java:1651), which is what the missing-file case models. Nothing
-- here throws to force a guard the engine cannot justify.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/RDClientPrefs.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL RDClientPrefs: " .. message) end
end

-- ---- engine stubs -------------------------------------------------------
function isServer() return false end

local gameStarts = {}
Events = { OnGameStart = { Add = function(fn) gameStarts[#gameStarts + 1] = fn end } }

-- A fake disk: filename -> the exact byte string that was written.
local disk = {}
local writerRefused = false

function getFileReader(name, _create)
    local body = disk[name]
    if body == nil then return nil end            -- missing file: nil, not a throw
    local lines, pos = {}, 1
    -- BufferedReader.readLine strips CR and LF alike on the way back in.
    for line in string.gmatch(body, "([^\r\n]*)\r?\n") do lines[#lines + 1] = line end
    local r = {}
    function r:readLine()
        local l = lines[pos]
        pos = pos + 1
        return l                                   -- nil past the end = EOF
    end
    function r:close() end
    return r
end

-- append is HONOURED here on purpose. The store passes append = false so the
-- file is a complete snapshot every time; a stub that ignored the flag would
-- make the snapshot assertion below pass no matter what the store asked for.
function getFileWriter(name, _create, append)
    if writerRefused then return nil end           -- refused extension / failed open
    local buf = {}
    local w = {}
    function w:write(s) buf[#buf + 1] = s end
    function w:close()
        local body = table.concat(buf)
        disk[name] = append and ((disk[name] or "") .. body) or body
    end
    return w
end

-- ---- load ---------------------------------------------------------------
dofile(SOURCE)
check(type(RDClientPrefs) == "table", "module did not define RDClientPrefs")

-- A store with no file writes nowhere, and finding that out at save() time
-- means the settings are already gone.
check(not pcall(RDClientPrefs.store), "store() accepted a missing filename")
check(not pcall(RDClientPrefs.store, ""), "store() accepted an empty filename")

local FILE = "RFTDTest_clientprefs.txt"
local prefs = RDClientPrefs.store(FILE)

-- ---- defaults on an absent file -----------------------------------------
check(prefs.get("never_set", "fallback") == "fallback",
    "an unset key did not fall back to the caller's default")
check(prefs.get("never_set") == nil, "an unset key with no default was not nil")
check(prefs.get("never_set", false) == false,
    "a `false` default was treated as absent - the classic `or` bug, and it "
    .. "would silently force every opt-out toggle back on")

-- ---- round trip ----------------------------------------------------------
prefs.set("a_true",   true)
prefs.set("a_false",  false)
prefs.set("an_int",   42)
prefs.set("a_float",  -1.5)
prefs.set("a_zero",   0)

local fresh = RDClientPrefs.store(FILE)
check(fresh.get("a_true")  == true,  "true did not survive the round trip")
check(fresh.get("a_false") == false, "false did not survive the round trip")
check(fresh.get("an_int")  == 42,    "an integer did not survive the round trip")
check(fresh.get("a_float") == -1.5,  "a negative float did not survive the round trip")
check(fresh.get("a_zero")  == 0,     "zero did not survive the round trip")
check(fresh.get("a_false", true) == false,
    "a stored `false` was read back as unset, so its default won instead")

-- ---- the file is a snapshot, not a log -----------------------------------
prefs.set("an_int", 7)
local _, newlines = string.gsub(disk[FILE], "\r\n", "")
check(newlines == 5, "expected 5 lines after overwriting a key, got "
    .. tostring(newlines) .. " - append instead of create would grow the file "
    .. "forever and let the last stale line win by accident")
check(RDClientPrefs.store(FILE).get("an_int") == 7, "the overwrite did not stick")

-- ---- unsupported values are skipped, never written -----------------------
prefs.set("a_table", { 1, 2 })
prefs.set("a_string", "hello")
check(string.find(disk[FILE], "a_table") == nil, "a table was written to the file")
check(string.find(disk[FILE], "a_string") == nil, "a string was written to the file")
-- ...but the in-memory cache still holds them for the rest of the session, and
-- a reload is where they disappear. That asymmetry is the format's, not a bug
-- here - it is why the serializer is documented as booleans and numbers only.
check(RDClientPrefs.store(FILE).get("a_string") == nil,
    "an unsupported value came back from disk")

-- ---- malformed lines -----------------------------------------------------
disk[FILE] = "good=true\r\nno_equals_here\r\n=novalue\r\nempty=\r\nbad=notanumber\r\n"
local parsed = RDClientPrefs.store(FILE)
check(parsed.get("good") == true, "a valid line was lost because of its neighbours")
check(parsed.get("") == nil, "an empty key was stored")
check(parsed.get("empty") == nil, "an empty value was stored")
check(parsed.get("bad") == nil, "an unparseable value was stored")

-- ---- a refused writer loses the file, never the session ------------------
local keeper = RDClientPrefs.store(FILE)
keeper.get("good")                 -- force the load
writerRefused = true
keeper.set("good", false)
check(keeper.get("good") == false,
    "a refused getFileWriter discarded the in-memory value too; the toggle "
    .. "would snap back under the operator's hand")
writerRefused = false

-- ---- startup load --------------------------------------------------------
check(#gameStarts > 0, "no OnGameStart loader was registered")
local ok = pcall(gameStarts[#gameStarts])
check(ok, "the startup loader threw")

realPrint(string.format("RDClientPrefs: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
