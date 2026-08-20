-- DFItemQuery fixture - the type-ahead ranking and the session cache contract.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/DFItemQuery.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL DFItemQuery: " .. message) end
end

-- ---- engine stub: the verified ScriptManager surface ---------------------
local function scriptItem(full, disp, obsolete)
    return {
        getFullName    = function() return full end,
        getDisplayName = function() return disp end,
        getObsolete    = function() return obsolete == true end,
    }
end
local pool = {}
local function setPool(list) pool = list end
ScriptManager = { instance = {
    getAllItems = function()
        return { size = function() return #pool end,
                 get  = function(_, i) return pool[i + 1] end }
    end,
} }

DFItemQuery = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

-- ---- pure ranking --------------------------------------------------------
local function entry(full, disp)
    local lfull = string.lower(full)
    local dot = string.find(lfull, ".", 1, true)
    return { full = full, disp = disp, lfull = lfull,
             ldisp = string.lower(disp), lbare = dot and string.sub(lfull, dot + 1) or lfull }
end
local E = {
    entry("Base.Axe", "Axe"),
    entry("Base.AxeStone", "Stone Axe"),
    entry("Base.WoodAxe", "Wood Axe"),
    entry("Base.Saw", "Saw"),
    entry("Mod.AxleRod", "Axle Rod"),
}

local r = DFItemQuery.rank(E, "axe", 8)
check(#r == 3, "matches bare-prefix and substring hits - and NOT AxleRod, because ..axe.. is not a substring of axle")
check(r[1].full == "Base.Axe" and r[2].full == "Base.AxeStone",
      "bare-type prefix outranks everything, alphabetical within rank")
check(r[#r].full ~= "Base.Saw", "a non-match never appears")

r = DFItemQuery.rank(E, "AXE", 8)
check(#r == 3 and r[1].full == "Base.Axe", "matching is case-insensitive")

r = DFItemQuery.rank(E, "stone a", 8)
check(#r == 1 and r[1].full == "Base.AxeStone", "display-name prefix matches too")

r = DFItemQuery.rank(E, "axe", 2)
check(#r == 2, "the limit caps the result set")

check(#DFItemQuery.rank(E, "", 8) == 0, "an empty query returns nothing")
check(#DFItemQuery.rank(E, "   ", 8) == 0, "whitespace is an empty query")
check(#DFItemQuery.rank(E, "zzz", 8) == 0, "no match is an empty answer, not an error")

-- ---- live cache ----------------------------------------------------------
setPool({ scriptItem("Base.Bandage", "Bandage"),
          scriptItem("Base.OldJunk", "Old Junk", true),   -- obsolete
          scriptItem("Base.BandageDirty", "Dirty Bandage") })
r = DFItemQuery.search("band", 8)
check(#r == 2 and r[1].full == "Base.Bandage", "search builds the cache and ranks")
check((function()
    for _, hit in ipairs(DFItemQuery.search("junk", 8)) do
        if hit.full == "Base.OldJunk" then return false end
    end
    return true
end)(), "obsolete scripts are excluded - AddItem would refuse them anyway")

-- The cache is per-session: changing the pool must NOT change results.
setPool({ scriptItem("Base.Nails", "Nails") })
check(#DFItemQuery.search("band", 8) == 2, "the registry is enumerated once and cached")

print(string.format("DFItemQuery: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
