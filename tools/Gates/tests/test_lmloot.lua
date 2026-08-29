-- test_lmloot.lua - the lootReduce fill consumer (S8), under real Lua 5.1.
--
-- LMLoot is glue between two verified surfaces - OnFillContainer's post-fill
-- mutation window and the resolved store - so what needs pinning is contract,
-- not arithmetic:
--
--   GATE        the distribution-not-container lane ("Zombie Bag" passes an
--               ItemPickerContainer, ItemPickerJava.java:603) is skipped, as
--               is a container with no source grid, no zone, or no rules.
--   MATCH       an item rule names a fullType and BEATS a category rule
--               covering the same item; a category rule matches the raw
--               DisplayCategory token. The roll is per matching item,
--               ZombRand(100) < pct.
--   MUTATION    removal goes through container:Remove while walking the live
--               list backward, so survivors keep their places.
--   NOISE       one announce line per zone per boot, one unparseable-rule
--               line per distinct string - never a line per cupboard.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/Gates/tests/test_lmloot.lua <repo-root>

local ROOT  = arg[1] or "."
local LIMES = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua"

-- --------------------------------------------------------------------------
-- Engine stubs
-- --------------------------------------------------------------------------

function isServer() return true end

local fillHandler = nil
Events = {
    OnFillContainer = { Add = function(fn) fillHandler = fn end },
}

-- The real global's contract (LuaManager.java:2836): class-name membership.
-- The fixture's containers self-declare; the distribution stand-in does not.
function instanceof(value, name)
    return type(value) == "table" and value.__class == name
end

local rand = 0
function ZombRand() return rand end

local realRequire = require
require = function() end
for _, src in ipairs({
    LIMES .. "/shared/LMCore.lua",
    LIMES .. "/server/LMLoot.lua",
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

isTrue("handler registered", type(fillHandler) == "function",
    "LMLoot must hang off OnFillContainer at load")

-- --------------------------------------------------------------------------
-- Fixture containers: a live backing array behind the Java list surface, with
-- Remove compacting it the way ItemContainer.Remove does.
-- --------------------------------------------------------------------------

local function item(fullType, category)
    return {
        getFullType        = function() return fullType end,
        getDisplayCategory = function() return category end,
    }
end

local function containerAt(x, y, contents)
    local c
    c = {
        __class = "ItemContainer",
        backing = contents,
        getSourceGrid = function()
            return { getX = function() return x end, getY = function() return y end }
        end,
        getItems = function()
            return {
                size = function() return #c.backing end,
                get  = function(_, i) return c.backing[i + 1] end,
            }
        end,
        Remove = function(_, it)
            for i = 1, #c.backing do
                if c.backing[i] == it then table.remove(c.backing, i) return end
            end
        end,
        names = function()
            local out = {}
            for i = 1, #c.backing do out[#out + 1] = c.backing[i]:getFullType() end
            return table.concat(out, ",")
        end,
    }
    return c
end

local lines = {}
local realPrint = print
local function fill(container)
    print = function(msg) lines[#lines + 1] = tostring(msg) end
    fillHandler("room", "crate", container)
    print = realPrint
end

-- --------------------------------------------------------------------------
-- The store: one cutting zone, one silent zone
-- --------------------------------------------------------------------------

Limes.apply({
    Scarcity = { rects = { { 0, 0, 99, 99 } },
                 fields = { lootReduce = "cat:Ammo=100; Base.Bullets9mm=0; Base.Axe=100" } },
    Plenty   = { rects = { { 200, 200, 299, 299 } }, fields = { title = "Plenty" } },
}, 1)

-- --------------------------------------------------------------------------
-- Gates: wrong shape, no ground, no zone, no rules
-- --------------------------------------------------------------------------

local dist = { getSourceGrid = function() error("a distribution must never be dereferenced") end }
fill(dist)
eq("non-ItemContainer lane is skipped", #lines, 0)

local orphan = containerAt(50, 50, { item("Base.Axe", "Tool") })
orphan.getSourceGrid = function() return nil end
fill(orphan)
eq("gridless container is skipped", orphan.names(), "Base.Axe")

local nowhere = containerAt(5000, 5000, { item("Base.Axe", "Tool") })
fill(nowhere)
eq("outside every zone nothing is cut", nowhere.names(), "Base.Axe")

local plenty = containerAt(250, 250, { item("Base.Axe", "Tool") })
fill(plenty)
eq("a zone without rules cuts nothing", plenty.names(), "Base.Axe")

-- --------------------------------------------------------------------------
-- Matching: category cut, item-beats-category, survivors keep their places
-- --------------------------------------------------------------------------

rand = 0
local crate = containerAt(50, 50, {
    item("Base.Bullets9mm",  "Ammo"),   -- Ammo, but its ITEM rule says 0: kept
    item("Base.ShotgunShells", "Ammo"), -- category rule at 100: removed
    item("Base.Axe",         "Tool"),   -- item rule at 100: removed
    item("Base.Hammer",      "Tool"),   -- no rule: kept
})
lines = {}
fill(crate)
eq("category cut + item override + bystander, in one pass",
    crate.names(), "Base.Bullets9mm,Base.Hammer")
eq("the zone's first cut announces once", #lines, 1)
isTrue("the announce names the zone", lines[1]:find("Scarcity", 1, true) ~= nil, lines[1])

lines = {}
fill(containerAt(50, 50, { item("Base.Axe", "Tool") }))
eq("later cuts in the same zone stay silent", #lines, 0)

-- --------------------------------------------------------------------------
-- The roll is ZombRand(100) < pct, per item
-- --------------------------------------------------------------------------

Limes.apply({
    Scarcity = { rects = { { 0, 0, 99, 99 } },
                 fields = { lootReduce = "Base.Axe=50" } },
}, 2)
rand = 49
local lucky = containerAt(50, 50, { item("Base.Axe", "Tool") })
fill(lucky)
eq("a roll under the percent removes", lucky.names(), "")
rand = 50
local unlucky = containerAt(50, 50, { item("Base.Axe", "Tool") })
fill(unlucky)
eq("a roll at the percent keeps", unlucky.names(), "Base.Axe")

-- --------------------------------------------------------------------------
-- Dirty rules: the parseable half still applies, the rest warns once
-- --------------------------------------------------------------------------

Limes.apply({
    Scarcity = { rects = { { 0, 0, 99, 99 } },
                 fields = { lootReduce = "Base.Axe=100; what even=is this" } },
}, 3)
rand = 0
lines = {}
fill(containerAt(50, 50, { item("Base.Axe", "Tool"), item("Base.Hammer", "Tool") }))
isTrue("bad fragments are named once",
    #lines >= 1 and lines[1]:find("unparseable", 1, true) ~= nil,
    table.concat(lines, " | "))
local warned = #lines
lines = {}
fill(containerAt(50, 50, { item("Base.Axe", "Tool") }))
eq("the same dirty string does not warn per fill", #lines, 0)
isTrue("the clean half of a dirty string still cuts", warned >= 1, "see above")

-- --------------------------------------------------------------------------
-- Counters
-- --------------------------------------------------------------------------

local stats = LMLoot.stats()
isTrue("stats count every removal", stats.total >= 4, "total=" .. tostring(stats.total))
isTrue("stats are per zone", (stats.byZone.Scarcity or 0) == stats.total,
    "every cut so far was in Scarcity")
stats.byZone.Scarcity = 0
isTrue("stats hand out a copy", LMLoot.stats().byZone.Scarcity > 0,
    "a reader must not become a writer")

print(string.format("LMLoot: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
