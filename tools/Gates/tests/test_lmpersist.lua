-- test_lmpersist.lua - behavioural tests for the RFTDLimes.ini layer under real
-- Lua 5.1, with the same in-memory filesystem idiom as test_rdlog.
--
-- WHAT THIS PINS:
--
--   ROUND TRIP  serialize(parse(serialize(z))) is byte-identical - the file is
--               rewritten on every edit, so any drift would compound silently
--               into a diff-noise generator (the writer's whole discipline is
--               deterministic output: sorted sections, sorted keys).
--   AUTOTYPE    "true"/"25"/"Gun Stores" come back boolean/number/string; the
--               registry heals the rest. An admin hand-editing `tier = 5` must
--               not produce the string "5" reaching a numeric consumer.
--   THE JOURNAL the writeLog line lands BEFORE the truncate-overwrite - that
--               ordering IS the crash diagnosis story (§8), so it is pinned as
--               behaviour, not left as a comment.
--   FULL CYCLE  production fixture -> import -> serialize -> parse -> apply:
--               the exact first-boot path the shadow install will run.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmpersist.lua <repo-root>

local ROOT = arg[1] or "."
local BASE = ROOT .. "/RequiemOfTheDead/Contents/mods"
local CORE  = BASE .. "/RFTDCore/42/media/lua/shared"
local LIMES = BASE .. "/RFTDLimes/42/media/lua"

-- --------------------------------------------------------------------------
-- In-memory filesystem + engine stubs
-- --------------------------------------------------------------------------

local FS  = {}   -- path -> content
local LOG = {}   -- writeLog journal, in call order tagged against writes

function isServer() return true end

function writeLog(logger, line)
    LOG[#LOG + 1] = { logger = logger, line = line, fsHasFile = FS["RFTDLimes.ini"] ~= nil }
end

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

Events = { OnServerStarted = { Add = function() end } }

local realRequire = require
require = function() end   -- everything LMPersist requires is dofiled below

for _, src in ipairs({
    CORE .. "/RDJson.lua",
    LIMES .. "/shared/LMCore.lua",
    -- The .ini dialect moved out of LMPersist on 2026-08-05 so the client can
    -- read the format the server writes. LMPersist.parse/serialize are thin
    -- delegates now, so this suite still addresses them and still tests the
    -- same round trip - but the code has to be loaded first.
    LIMES .. "/shared/LMIni.lua",
    LIMES .. "/shared/LMImport.lua",
    LIMES .. "/server/LMPersist.lua",
}) do
    local ok, err = pcall(dofile, src)
    if not ok then
        print("FATAL: could not load " .. src)
        print("  " .. tostring(err))
        os.exit(2)
    end
end
require = realRequire

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

-- ---------------------------------------------------------------------------
-- Parse, from a hand-written admin file
-- ---------------------------------------------------------------------------

local zones, warnings = LMPersist.parse([[
; an admin wrote this by hand
orphankey = before-any-section
[Downtown]
inherits = Hard
rects = 100,200,300,400 ; 300 , 200 , 500 , 250
tier = 5
title = Down Town
nofire = true
lewtkey = Gun Stores

# hash comments too
[Hard]
tier = 4
sprinters = 12.5

[Broken]
rects = 1,2,3
]])

eq("two rects parsed",            #zones.Downtown.rects, 2)
eq("rect numbers with spaces",    zones.Downtown.rects[2][3], 500)
eq("inherits parsed",             zones.Downtown.inherits, "Hard")
eq("number autotyped",            zones.Downtown.fields.tier, 5)
eq("boolean autotyped",           zones.Downtown.fields.nofire, true)
eq("string stays string",         zones.Downtown.fields.title, "Down Town")
eq("string with spaces survives", zones.Downtown.fields.lewtkey, "Gun Stores")
eq("float autotyped",             zones.Hard.fields.sprinters, 12.5)
eq("template section fine",       #zones.Hard.rects, 0)

local sawOrphan, sawBadRect = false, false
for i = 1, #warnings do
    if warnings[i]:find("orphankey") then sawOrphan = true end
    if warnings[i]:find("bad rect") then sawBadRect = true end
end
isTrue("key before section warned", sawOrphan, "no orphan-key warning")
isTrue("three-number rect warned",  sawBadRect, "no bad-rect warning")

-- ---------------------------------------------------------------------------
-- Serialize: deterministic, and a stable round trip
-- ---------------------------------------------------------------------------

local text1 = LMPersist.serialize(zones)
local zones2, w2 = LMPersist.parse(text1)
eq("round trip carries no warnings", #w2, 0)
local text2 = LMPersist.serialize(zones2)
eq("serialize(parse(serialize)) is byte-identical", text1, text2)

isTrue("sections sorted", text1:find("%[Broken%].*%[Downtown%].*%[Hard%]"), "section order wrong")
isTrue("keys sorted within a section", text1:find("lewtkey.-nofire.-tier.-title"), "key order wrong")
eq("round-tripped value intact", zones2.Downtown.fields.tier, 5)
eq("round-tripped rects intact", zones2.Downtown.rects[2][4], 250)

-- Newlines cannot survive in a value: the grammar is one line per key.
local dirty = { D = { rects = {}, fields = { title = "two\nlines" } } }
local z3 = LMPersist.parse(LMPersist.serialize(dirty))
eq("newline in value folded to a space", z3.D.fields.title, "two lines")

-- ---------------------------------------------------------------------------
-- Save: the journal precedes the write
-- ---------------------------------------------------------------------------

eq("save reports ok", LMPersist.save(zones, "test-edit", "tester"), true)
isTrue("file landed", FS["RFTDLimes.ini"] ~= nil, "no file written")
eq("file content is the serialization", FS["RFTDLimes.ini"], text1)
isTrue("journal line written", #LOG >= 1, "writeLog never called")
eq("journal logger is the mod", LOG[1].logger, "RFTDLimes")
isTrue("journal precedes the truncate (fresh file)", LOG[1].fsHasFile == false,
    "writeLog fired after the file already existed")
isTrue("journal names the why and who", LOG[1].line:find("test%-edit") and LOG[1].line:find("tester"),
    LOG[1].line)

-- readAll round trip through the stub jail. The engine reader is line-based
-- (BufferedReader.readLine), so a file's trailing newline is unknowable -
-- readAll returns the content sans final "\n". parse() is indifferent; pinned
-- here so nobody "fixes" a byte comparison against it later.
eq("readAll returns what save wrote (modulo trailing newline)",
    LMPersist.readAll("RFTDLimes.ini") .. "\n", text1)
eq("readAll on absent file is nil",   LMPersist.readAll("NotThere.ini"), nil)

-- ---------------------------------------------------------------------------
-- Full first-boot cycle: fixture -> import -> save -> parse -> apply
-- ---------------------------------------------------------------------------

local f = io.open(ROOT .. "/docs/dirge-phunzones.md", "rb")
if not f then
    print("FATAL: fixture not found")
    os.exit(2)
end
local fixture = f:read("*a")
f:close()

local ok, res = LMImport.parsePhunZones(fixture)
isTrue("fixture imports", ok, res)

LMPersist.save(res.zones, "first-boot import", "server")
local reloaded, w4 = LMPersist.parse(LMPersist.readAll("RFTDLimes.ini"))
eq("production data reloads without warnings", #w4, 0)

local n1, n2 = 0, 0
for _ in pairs(res.zones) do n1 = n1 + 1 end
for _ in pairs(reloaded) do n2 = n2 + 1 end
eq("every zone survives the disk trip", n2, n1)
eq("Louisville tier survives",         reloaded.Louisville.fields.tier, 5)
eq("Louisville rects survive",         #reloaded.Louisville.rects, 3)
eq("Louisville inherits survives",     reloaded.Louisville.inherits, "Very_Hard")
eq("dirge dial survives as a number",  reloaded.Louisville.fields.dirgeSpawnChance, 25)

local applyWarnings = Limes.apply(reloaded, 1)
isTrue("production data applies (warnings are unregistered-consumer keys only)",
    Limes.revision == 1, "apply failed")
local lv = Limes.getLocation(12000, 2000)   -- inside Louisville rect 2
isTrue("live lookup lands in Louisville", lv and lv.name == "Louisville",
    lv and lv.name or "nil")
eq("resolved tier through the whole pipe", lv and lv.fields.tier, 5)

-- The serialize of the reloaded store still matches itself (idempotence held
-- across the import shapes too).
eq("production round trip is stable",
    LMPersist.serialize(reloaded), LMPersist.serialize(LMPersist.parse(LMPersist.serialize(reloaded))))

print(string.format("LMPersist: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
