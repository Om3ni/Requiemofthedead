-- test_lmimport.lua - the dialect door under real Lua 5.1: schema-1 JSON in,
-- schema-1 JSON out, the .ini restore lane, and the one-shot ladder migration.
--
-- THE PHUNZONES DIALECT DIED 2026-08-27 (S2 of the redesign) and its fixture
-- pass died with it - the offline converter (tools/limes-zone-converter.html)
-- owns that translation now, and its own smoke test runs under node. What
-- this file owns since then: the JSON sharing surface is lossless both ways,
-- a pre-redesign store (the old six-rung template ladder) migrates onto the
-- record-kind model exactly once, and PhunZones text is refused with
-- directions rather than a parse error.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmimport.lua <repo-root>

local ROOT = arg[1] or "."
local LM   = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua/"
local CORE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/shared/"

require = function() return true end   -- deps are dofile'd below

for _, src in ipairs({ CORE .. "RDJson.lua", LM .. "shared/LMCore.lua",
                       LM .. "shared/LMIni.lua", LM .. "shared/LMEdit.lua",
                       LM .. "shared/LMImport.lua" }) do
    local okDep, derr = pcall(dofile, src)
    if not okDep then
        print("FATAL: could not load " .. src)
        print("  " .. tostring(derr))
        os.exit(2)
    end
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
-- Schema-1 JSON in: envelope, kind mapping, moon nesting, loot-array-to-
-- grammar, terminal-structure normalization, and the sniffing.
-- ---------------------------------------------------------------------------

local S1DOC = [[{
  "schema": 1,
  "revision": 7,
  "records": {
    "_default": { "fields": { "zeds": "" } },
    "Newcomer": { "kind": "tier", "fields": { "rank": 1 } },
    "IDDQL": { "kind": "tier", "fields": { "rank": 5, "dirgeSpawnChance": 25 },
               "moon": { "phases": "full", "fields": { "dirgeSpawnChance": 40 } } },
    "Gun_Stores": { "kind": "profile", "name": "Gun Stores",
                    "fields": { "nosafehouse": true },
                    "loot": [ { "kind": "item", "name": "Base.Shotgun", "pct": 75 },
                              { "kind": "category", "name": "Ammo", "pct": 50 },
                              { "kind": "item", "name": "bad name!", "pct": 10 } ] },
    "Louisville": { "tier": "IDDQL", "name": "Louisville",
                    "rects": [ [100, 100, 400, 400], [1, 2, 3] ],
                    "fields": { "nobuilding": true } },
    "Gun_Row": { "parent": "Louisville", "profiles": ["Gun_Stores"],
                 "rects": [ [120, 120, 140, 140] ],
                 "fields": { "kind": "sneaky", "nested": { "no": 1 } } },
    "Rogue_Tier": { "kind": "tier", "parent": "Louisville", "tier": "IDDQL",
                    "rects": [ [0, 0, 9, 9] ], "profiles": ["Gun_Stores"],
                    "fields": {} },
    "Bad Id!": { "fields": {} }
  }
}]]

local ok, res = LMImport.parseSchema1(S1DOC)
isTrue("schema-1 parses", ok, res)
if ok then
    eq("record count skips the unusable id", res.count, 7)
    eq("a tier record keeps its kind",     res.zones.IDDQL.kind, "tier")
    eq("...and its dials",                 res.zones.IDDQL.fields.rank, 5)
    eq("...and its moon gate",             res.zones.IDDQL.moon.phases, "full")
    eq("...and its moon dials",            res.zones.IDDQL.moon.fields.dirgeSpawnChance, 40)
    eq("a zone's parent becomes inherits", res.zones.Gun_Row.inherits, "Louisville")
    eq("a zone's tier lands in the slot",  res.zones.Louisville.tier, "IDDQL")
    eq("the display name becomes the title", res.zones.Louisville.fields.title, "Louisville")
    eq("rects survive",                    res.zones.Louisville.rects[1][3], 400)
    eq("a three-number rect is skipped",   #res.zones.Louisville.rects, 1)
    eq("profiles survive",                 res.zones.Gun_Row.profiles[1], "Gun_Stores")
    eq("the loot array becomes the grammar",
       res.zones.Gun_Stores.fields.lootReduce, "Base.Shotgun=75; cat:Ammo=50")
    eq("a profile keeps its kind",         res.zones.Gun_Stores.kind, "profile")
    eq("a structure-shadowing field is dropped", res.zones.Gun_Row.fields.kind, nil)
    eq("a table-valued field is dropped",  res.zones.Gun_Row.fields.nested, nil)
    eq("the unusable id is gone",          res.zones["Bad Id!"], nil)
    -- Terminal normalization: the tampered tier imports as a CLEAN tier.
    eq("a tier's parent is dropped",       res.zones.Rogue_Tier.inherits, nil)
    eq("a tier's tier is dropped",         res.zones.Rogue_Tier.tier, nil)
    eq("a tier's ground is dropped",       res.zones.Rogue_Tier.rects, nil)
    eq("a tier's profiles are dropped",    res.zones.Rogue_Tier.profiles, nil)
    local sawLoot, sawDropped = false, false
    for _, w in ipairs(res.warnings) do
        if w:find("loot rule 3", 1, true) then sawLoot = true end
        if w:find("cannot have a parent", 1, true) then sawDropped = true end
    end
    isTrue("the bad loot rule is named",      sawLoot, "no loot warning")
    isTrue("dropped structure is named",      sawDropped, "no terminal-drop warning")
end

-- Envelope refusals name the reason.
ok, res = LMImport.parseSchema1('{ "schema": 2, "records": {} }')
eq("a future schema is refused", ok, false)
isTrue("...and says which",      tostring(res):find("schema 2", 1, true) ~= nil, res)
ok, res = LMImport.parseSchema1('{ "schema": 1 }')
eq("a recordless document is refused", ok, false)
ok, res = LMImport.parseSchema1('{ not json')
eq("junk is refused at the JSON layer", ok, false)

-- Sniffing: JSON reaches the JSON lane; Lua literals never do.
isTrue("a JSON object sniffs as JSON",      LMImport.looksLikeJson('  { "schema": 1 }'))
isTrue("an empty JSON object sniffs too",   LMImport.looksLikeJson("{}"))
isTrue("a bare-brace Lua literal does not", not LMImport.looksLikeJson("{ version = 2, data = {} }"))
isTrue("a return-wrapped literal does not", not LMImport.looksLikeJson("return { version = 2 }"))
ok, res = LMImport.parseAny(S1DOC)
isTrue("parseAny routes JSON", ok, res)
if ok then eq("...and reports the dialect", res.format, "json") end

-- The PhunZones dialect is REFUSED WITH DIRECTIONS, not parse-errored: the
-- admin holding that text needs to hear "offline converter", not "line 1".
ok, res = LMImport.parseAny("return { version = 2, data = { A = { points = {} } } }")
eq("a PhunZones layer is refused", ok, false)
isTrue("...pointing at the offline converter",
    tostring(res):find("limes-zone-converter", 1, true) ~= nil, res)

-- ---------------------------------------------------------------------------
-- migrateLadder: a pre-redesign store (as LMIni.parse hands it over) steps
-- onto the record-kind model in one pass, and a current store is untouched.
-- ---------------------------------------------------------------------------

-- Exactly what the old serializer wrote: the six-rung template ladder as
-- kind-less inherits-templates, zones chained through it, `tier = N` lines
-- (which the new parser lands in the SLOT as numeric strings), and the
-- retired sprinter/lewtkey fields.
local OLD_INI = [[
[_default]
tier = 2

[Very_Hard]
inherits = _default
tier = 5
dirgeSpawnChance = 25
lewtkey = Hot

[Medium]
inherits = _default
tier = 2
dirgeSpawnChance = 10

[Intermediate]
inherits = _default
tier = 3
dirgeSpawnChance = 12

[Louisville]
inherits = Very_Hard
rects = 100,100,400,400
minSprinterRisk = 20
maxSprinterRisk = 35
title = Louisville

[Downtown]
inherits = Louisville
rects = 120,120,200,200

[Quarry]
rects = 900,900,950,950
tier = 0
]]

local zones = LMIni.parse(OLD_INI)
local notes = LMImport.migrateLadder(zones)
isTrue("migration reports work", #notes > 0, "no notes")

eq("the archetype became a tier record",  zones.IDDQL.kind, "tier")
eq("...carrying its dials",               zones.IDDQL.fields.dirgeSpawnChance, 25)
eq("...and its rank",                     zones.IDDQL.fields.rank, 5)
eq("...but not its lewtkey",              zones.IDDQL.fields.lewtkey, nil)
eq("the old name is gone",                zones.Very_Hard, nil)
eq("Medium re-created under its own name", zones.Medium.kind, "tier")
eq("...with Medium's dials, not Intermediate's", zones.Medium.fields.dirgeSpawnChance, 10)
eq("Intermediate collapsed away",         zones.Intermediate, nil)
eq("the chained zone stepped onto the slot", zones.Louisville.tier, "IDDQL")
eq("...and off the ladder",               zones.Louisville.inherits, nil)
eq("a real-geography chain is untouched", zones.Downtown.inherits, "Louisville")
eq("...and takes its tier through it, not a slot", zones.Downtown.tier, nil)
eq("a numeric slot mapped by value",      zones.Quarry.tier, "Newcomer")
eq("...and its bare rung was backfilled", zones.Newcomer.kind, "tier")
eq("...with rank only",                   zones.Newcomer.fields.rank, 1)
eq("_default's numeric slot mapped",      zones._default.tier, "Medium")
eq("the sprinter band is stripped",       zones.Louisville.fields.minSprinterRisk, nil)
eq("...both halves",                      zones.Louisville.fields.maxSprinterRisk, nil)
eq("untouched fields ride",               zones.Louisville.fields.title, "Louisville")

-- Idempotence: the migrated store migrates to silence.
eq("a second pass is a no-op", #LMImport.migrateLadder(zones), 0)

-- A CURRENT store is untouched - including a deliberately deleted rung,
-- which must NOT be resurrected by a zone still pointing at it.
local current = {
    _default = { tier = "Medium" },
    Medium   = { kind = "tier", fields = { rank = 3 } },
    Town     = { tier = "Spicy", rects = { { 0, 0, 9, 9 } }, fields = {} },
}
eq("a new-model store notes nothing", #LMImport.migrateLadder(current), 0)
eq("...and the deleted rung stays deleted", current.Spicy, nil)

-- The ini lane runs the migration inline, so restoring an old backup works.
ok, res = LMImport.parseAny(OLD_INI)
isTrue("an old backup restores through parseAny", ok, res)
if ok then
    eq("...migrated on the way in", res.zones.Louisville.tier, "IDDQL")
    local sawNote = false
    for _, w in ipairs(res.warnings) do
        if w:find("migrated:", 1, true) then sawNote = true end
    end
    isTrue("...and says so", sawNote, "no migration note in warnings")
end

-- ---------------------------------------------------------------------------
-- Schema-1 JSON out: export -> import is lossless, and the loot grammar
-- round-trips through the structured array.
-- ---------------------------------------------------------------------------

local store = {
    _default = { tier = "Medium", fields = { zeds = "none" } },
    Medium   = { kind = "tier", fields = { rank = 3 },
                 moon = { phases = "full", fields = { dirgeSpawnChance = 40 } } },
    Guns     = { kind = "profile",
                 fields = { nosafehouse = true,
                            lootReduce = "Base.Shotgun=75; cat:Ammo=50" } },
    Town     = { rects = { { 0, 0, 99, 99 } }, profiles = { "Guns" },
                 fields = { title = "The Town", nobuilding = true } },
    Block    = { inherits = "Town", tier = "Medium",
                 rects = { { 10, 10, 19, 19 } }, fields = {} },
}

local text = LMImport.exportSchema1(store, 42)
isTrue("export produces JSON", LMImport.looksLikeJson(text), text:sub(1, 40))
isTrue("the loot field went out structured", text:find('"loot":', 1, true) ~= nil,
    "no loot array in export")
isTrue("...and not as the raw grammar", text:find("lootReduce", 1, true) == nil,
    "lootReduce leaked alongside the array")
eq("export is deterministic", text, LMImport.exportSchema1(store, 42))

ok, res = LMImport.parseSchema1(text)
isTrue("the export re-imports", ok, res)
if ok then
    eq("every record survives", res.count, 5)
    -- The real pin: fold both through the same pruner and diff - zero changes.
    local before = LMEdit.new(store, 1)
    local after  = LMEdit.new(res.zones, 1)
    after.base = before:snapshot()
    eq("export -> import changes nothing at all", select(3, after:changeSet()), 0)
end

-- A lootReduce the grammar rejects rides VERBATIM instead of being destroyed.
local dirty = { P = { kind = "profile", fields = { lootReduce = "Base.Axe=25; broken rule" } } }
local dtext = LMImport.exportSchema1(dirty, 1)
isTrue("an unparseable loot field exports verbatim",
    dtext:find("broken rule", 1, true) ~= nil, "the bad rule was dropped")
isTrue("...as the field, not the array", dtext:find('"loot":', 1, true) == nil,
    "a partial array was emitted")

print(string.format("LMImport: %d passed, %d failed", pass, fail))
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
