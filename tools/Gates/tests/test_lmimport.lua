-- test_lmimport.lua - behavioural tests for the PhunZones importer under real
-- Lua 5.1, INCLUDING a full parse of the live fixture (docs/dirge-phunzones.md,
-- the production custom layer, ~120 zones with inheritance).
--
-- The fixture pass is the one that matters: the importer will run exactly once
-- against exactly this shape of data, so the test that proves the milestone is
-- "the real dataset survives the trip" - zone counts, spot values, template
-- zones, the void template, multi-rect geometry - not synthetic minimums. The
-- synthetic literals around it pin the parser's grammar edges (escapes,
-- bracket keys, comments, depth cap, error line numbers) where the fixture is
-- too well-behaved to reach.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmimport.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/shared/LMImport.lua"
local FIXTURE = ROOT .. "/docs/dirge-phunzones.md"

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
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

-- ---------------------------------------------------------------------------
-- The literal parser, grammar edges
-- ---------------------------------------------------------------------------

local t = LMImport.parseLua('return { a = 1, b = "two", c = true, d = { 1, 2; 3 }, }')
eq("number value",        t.a, 1)
eq("string value",        t.b, "two")
eq("boolean value",       t.c, true)
eq("positional entries",  t.d[3], 3)

t = LMImport.parseLua('{ ["with space"] = -4.5, [7] = "seven" }')
eq("bracket string key",  t["with space"], -4.5)
eq("bracket number key",  t[7], "seven")

t = LMImport.parseLua('-- leading comment\nreturn { -- inline\n  x = "a\\"b\\nc" -- trailing\n}')
eq("escapes in strings",  t.x, 'a"b\nc')

t = LMImport.parseLua("{ s = 'single quotes' }")
eq("single-quoted string", t.s, "single quotes")

local bad, perr = LMImport.parseLua('return { a = 1,\n  b = @ }')
eq("garbage rejected", bad, nil)
isTrue("error carries a line number", tostring(perr):find("line 2"), perr)

bad, perr = LMImport.parseLua('{ a = "unterminated }')
eq("unterminated string rejected", bad, nil)

bad, perr = LMImport.parseLua('{ a = 1 } trailing')
eq("trailing content rejected", bad, nil)

local deep = string.rep("{ x = ", 40) .. "1" .. string.rep(" }", 40)
bad, perr = LMImport.parseLua(deep)
eq("depth cap holds", bad, nil)
isTrue("depth cap names itself", tostring(perr):find("nesting"), perr)

-- ---------------------------------------------------------------------------
-- The mapping, synthetically
-- ---------------------------------------------------------------------------

local ok, res = LMImport.parsePhunZones([[return { version = 2, data = {
    Town = {
        points = { { 10, 10, 90, 90 } },
        inherits = "Med",
        difficulty = 3,
        dirgeSpawnChance = "25",
        dirgeScreamerWeight = "",
        minSprinterRisk = "5",
        nobuilding = true,
        noannounce = false,
        zeds = "remove",
        lewtkey = "Gun Stores",
        title = "The Town",
        order = 2,
        oddity = "kept",
        nested = { cannot = "survive" },
    },
    Med = { difficulty = 2 },
    ["Bad Name!"] = { difficulty = 1 },
} }]])

isTrue("mapping parse ok", ok, res)
local z = res.zones.Town
eq("points -> rects verbatim",     z.rects[1][4], 90)
eq("inherits kept by name",        z.inherits, "Med")
eq("difficulty crosses to tier",   z.fields.tier, 3)
eq("dirge string becomes number",  z.fields.dirgeSpawnChance, 25)
eq("empty dirge string omitted",   z.fields.dirgeScreamerWeight, nil)
eq("sprinter risk becomes number", z.fields.minSprinterRisk, 5)
eq("restriction flag boolean",     z.fields.nobuilding, true)
eq("false flag kept as false",     z.fields.noannounce, false)
eq("zeds string kept",             z.fields.zeds, "remove")
eq("lewtkey kept",                 z.fields.lewtkey, "Gun Stores")
eq("title kept",                   z.fields.title, "The Town")
eq("order becomes number",         z.fields.order, 2)
eq("unknown scalar preserved",     z.fields.oddity, "kept")
eq("unknown table dropped",        z.fields.nested, nil)
eq("template zone imported",       #res.zones.Med.rects, 0)
eq("unusable name skipped",        res.zones["Bad Name!"], nil)
eq("count skips the skipped",      res.count, 2)

local sawNested, sawBadName = false, false
for i = 1, #res.warnings do
    if res.warnings[i]:find("nested") then sawNested = true end
    if res.warnings[i]:find("Bad Name!") then sawBadName = true end
end
isTrue("table drop warned", sawNested, "no nested-table warning")
isTrue("name skip warned",  sawBadName, "no bad-name warning")

ok, res = LMImport.parsePhunZones("return { data = 42 }")
eq("dataless export refused", ok, false)

ok, res = LMImport.parsePhunZones("return { version = 3, data = { A = { difficulty = 1 } } }")
isTrue("wrong version imports anyway", ok, res)
isTrue("wrong version warned", #res.warnings > 0, "no version warning")

-- ---------------------------------------------------------------------------
-- The live fixture
-- ---------------------------------------------------------------------------

local f = io.open(FIXTURE, "rb")
if not f then
    print("FATAL: fixture not found: " .. FIXTURE)
    os.exit(2)
end
local text = f:read("*a")
f:close()

ok, res = LMImport.parsePhunZones(text)
isTrue("fixture parses", ok, res)
if ok then
    isTrue("fixture zone count is production-sized (" .. res.count .. ")", res.count >= 90, res.count)

    local lv = res.zones.Louisville
    isTrue("Louisville present", lv ~= nil, "missing")
    eq("Louisville rect count",        #lv.rects, 3)
    eq("Louisville inherits",          lv.inherits, "Very_Hard")
    eq("Louisville tier",              lv.fields.tier, 5)
    eq("Louisville dirgeSpawnChance",  lv.fields.dirgeSpawnChance, 25)
    eq("Louisville minSprinterRisk",   lv.fields.minSprinterRisk, 20)
    eq("Louisville maxSprinterRisk",   lv.fields.maxSprinterRisk, 35)
    eq("Louisville rect 2 corner",     lv.rects[2][1], 11907)

    local void = res.zones["void"]
    isTrue("void template imported",   void ~= nil, "missing")
    if void then
        eq("void has no geometry",     #void.rects, 0)
        eq("void nosafehouse",         void.fields.nosafehouse, true)
        eq("void minSprinterRisk",     void.fields.minSprinterRisk, 0)
    end

    -- Every inherits target in the production data resolves inside the set.
    local dangling = 0
    for _, zz in pairs(res.zones) do
        if zz.inherits and not res.zones[zz.inherits] then dangling = dangling + 1 end
    end
    eq("no dangling inheritance in production data", dangling, 0)

    -- Every zone name survives the .ini section grammar.
    local badNames = 0
    for name in pairs(res.zones) do
        if not name:match("^[%w_%-%.]+$") then badNames = badNames + 1 end
    end
    eq("every name .ini-safe", badNames, 0)
end

print(string.format("LMImport: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
