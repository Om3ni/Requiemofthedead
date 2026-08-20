-- test_ljsweep.lua - axe selection for the Lumberjack sweep.
--
-- WHY THIS FILE EXISTS: LJS.bestAxe had no coverage at all while it carried a
-- live defect. The old implementation wrapped its WHOLE walk in one pcall
-- because getTreeDamage is declared only on HandWeapon (HandWeapon.java:52-55,
-- :1523-1529 - the entire decompile mentions the name exactly twice, there and
-- at IsoTree.java:219), so a CHOP_TREE-tagged non-weapon indexes it to nil and
-- calling nil throws. That reading was correct; the containment was not. One
-- such item anywhere in the pack aborted the entire search and returned nil,
-- so the sweep reported "no axe" while the player was holding one.
--
-- The engine surfaces modelled here, all verified:
--   * hasTag / isBroken exist on InventoryItem (:2665-2669, :2934), so the
--     isAxe predicate is safe on ANY item - which matters because it runs
--     inside getAllEvalRecurse, where the engine discards a predicate's error
--     entirely (ItemContainer.java:3618-3621 into KahluaThread.java:1261-1278).
--     A throwing predicate would read as "false" with nothing in the log, so
--     the predicate must never depend on throwing.
--   * getTreeDamage exists ONLY on HandWeapon. An item without it indexes to
--     nil in Kahlua rather than throwing on the index, so a presence test is
--     exact.
--   * getAllEvalRecurse returns a fresh list, never nil, and never contains
--     null entries (ItemContainer.java:1854-1856, :1239-1261).

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDOddsAndEnds"
    .. "/42/media/lua/client/Lumberjack/LJSweep.lua"

local pass, failures = 0, {}
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else failures[#failures + 1] = "FAIL " .. name
        .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")" end
end

-- ── engine surface ──────────────────────────────────────────────────────────

ItemTag = { CHOP_TREE = "base:choptree" }

function isServer() return false end
function isClient() return true end
local realRequire = require
function require(_) end

OEShared = { enabled = function() return true end }
SandboxVars = { RFTDOddsAndEnds = {} }

-- The file registers its context-menu hook at load scope.
local added = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(_, fn) added[name] = fn end }
    rawset(t, name, e)
    return e
end })
function getText(key) return key end

-- An item with no getTreeDamage field at all - the Kahlua truth for a
-- non-HandWeapon, where indexing an absent method yields nil.
local function taggedItem(name, broken)
    return {
        name    = name,
        hasTag  = function(_, tag) return tag == ItemTag.CHOP_TREE end,
        isBroken = function() return broken == true end,
    }
end

-- A real chopper: same tags, plus the HandWeapon-only accessor.
local function axe(name, treeDamage, broken)
    local o = taggedItem(name, broken)
    o.getTreeDamage = function() return treeDamage end
    return o
end

local function nonAxe(name)
    return {
        name = name,
        hasTag = function() return false end,
        isBroken = function() return false end,
    }
end

local heldItem, packContents
local player = {
    getPrimaryHandItem = function() return heldItem end,
    getInventory = function()
        return {
            getAllEvalRecurse = function(_, predicate)
                local hits = {}
                for _, it in ipairs(packContents) do
                    if predicate(it) then hits[#hits + 1] = it end
                end
                return {
                    size = function() return #hits end,
                    get  = function(_, i) return hits[i + 1] end,
                }
            end,
        }
    end,
}

realRequire("os")
local chunk = assert(loadfile(SRC))
chunk()
local LJS = Lumberjack.Sweep

local function named(item) return item and item.name or nil end

-- ── the ordinary contract ───────────────────────────────────────────────────

heldItem, packContents = nil, {}
eq("no chopper carried yields nil", named(LJS.bestAxe(player)), nil)

heldItem, packContents = nil, { axe("hatchet", 10) }
eq("a lone packed axe is chosen", named(LJS.bestAxe(player)), "hatchet")

heldItem, packContents = nil, { axe("hatchet", 10), axe("felling", 25), axe("dull", 3) }
eq("the best TreeDamage wins", named(LJS.bestAxe(player)), "felling")

heldItem = axe("held", 25)
packContents = { axe("spare", 25) }
eq("a tie keeps the axe already in hand", named(LJS.bestAxe(player)), "held")

heldItem = axe("held", 10)
packContents = { axe("sharper", 30) }
eq("a strictly better packed axe still wins", named(LJS.bestAxe(player)), "sharper")

heldItem, packContents = nil, { axe("broken", 99, true), axe("whole", 5) }
eq("a broken chopper is not a candidate", named(LJS.bestAxe(player)), "whole")

heldItem, packContents = nil, { nonAxe("spoon"), axe("hatchet", 10) }
eq("an untagged item is not a candidate", named(LJS.bestAxe(player)), "hatchet")

-- ── the regression: a tagged non-weapon must cost only itself ───────────────
--
-- This is the defect. Under the old whole-walk guard every one of these
-- returned nil, because the first getTreeDamage call on the tagged non-weapon
-- threw and aborted the entire search.

heldItem, packContents = nil, { taggedItem("decorative-axe"), axe("felling", 25) }
eq("a tagged non-weapon does not hide an axe behind it",
    named(LJS.bestAxe(player)), "felling")

heldItem, packContents = nil, { axe("felling", 25), taggedItem("decorative-axe") }
eq("a tagged non-weapon does not discard an axe found before it",
    named(LJS.bestAxe(player)), "felling")

heldItem = nil
packContents = { axe("dull", 3), taggedItem("wall-mount"), axe("felling", 25) }
eq("the best axe still wins across a tagged non-weapon",
    named(LJS.bestAxe(player)), "felling")

heldItem, packContents = taggedItem("held-decoration"), { axe("hatchet", 10) }
eq("a tagged non-weapon IN HAND does not suppress the pack",
    named(LJS.bestAxe(player)), "hatchet")

heldItem, packContents = nil, { taggedItem("only-decoration") }
eq("a tagged non-weapon alone is not a chopper", named(LJS.bestAxe(player)), nil)

-- ── the predicate must never rely on throwing ───────────────────────────────
-- isAxe runs inside getAllEvalRecurse, whose errors the engine discards
-- silently, so it may only touch surfaces every InventoryItem carries.

local probed = {}
local probeItem = {
    hasTag = function(_, tag) probed.hasTag = true; return tag == ItemTag.CHOP_TREE end,
    isBroken = function() probed.isBroken = true; return false end,
}
probeItem.getTreeDamage = function() return 7 end
heldItem, packContents = nil, { probeItem }
LJS.bestAxe(player)
eq("the predicate asks hasTag", probed.hasTag, true)
eq("the predicate asks isBroken", probed.isBroken, true)

-- ── results ─────────────────────────────────────────────────────────────────

if #failures > 0 then
    for _, f in ipairs(failures) do print(f) end
    print(string.format("test_ljsweep: %d/%d checks FAILED", #failures, pass + #failures))
    os.exit(1)
end
print(string.format("test_ljsweep: %d checks passed", pass))
