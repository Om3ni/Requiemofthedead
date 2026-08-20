-- test_lmdirge.lua - the M1 bridges: Dirge spawn overrides and the RQSuppress
-- zone term, under real Lua 5.1.
--
-- These are the first files that make a zone DO something, and both are
-- takeovers of another mod's surface, so what needs pinning is not arithmetic
-- but contract:
--
--   AUTHORITY   an empty Limes store must NOT take over. A server that has
--               installed Limes but not yet imported would otherwise lose the
--               per-zone Dirge rules PhunZones was still supplying, and it
--               would look like a regression at the worst possible moment.
--   SEMANTICS   getEffectiveRules keeps its three promises exactly: a set zone
--               value wins, a blank one inherits the cfg snapshot through
--               __index, and a point with no overrides returns the caller's
--               OWN table so the spawn path allocates nothing.
--   COERCION    PhunZones persisted these as strings ("15"). Registering them
--               as numbers is what makes the store hand Dirge a number, and
--               the registry's min/max is the only clamp - the spawn path
--               deliberately has none.
--   LOAD ORDER  neither bridge may assume its host mod parsed first. install()
--               is idempotent and must never chain a wrapper onto itself.
--   QUIET       the suppression term returns nil rather than 1.0 when it has
--               nothing to say, or RQSuppress holds a pointless group active
--               through its linger window forever.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_lmdirge.lua <repo-root>

local ROOT  = arg[1] or "."
local LIMES = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLimes/42/media/lua"

-- --------------------------------------------------------------------------
-- Engine stubs. Same shape as test_lmpersist: the bridges are engine-light,
-- they just need isServer, Events and a stand-in for the mod they wrap.
-- --------------------------------------------------------------------------

function isServer() return false end   -- client side, so LMSuppress loads too

local bootHandlers = {}
Events = {
    OnGameBoot      = { Add = function(_, fn) end },
    OnServerStarted = { Add = function(_, fn) end },
    OnGameStart     = { Add = function(_, fn) bootHandlers[#bootHandlers + 1] = fn end },
}
-- The Add signature above is called as Events.X.Add(fn), so fix the arity.
Events.OnGameBoot.Add      = function(fn) bootHandlers[#bootHandlers + 1] = fn end
Events.OnServerStarted.Add = function(fn) bootHandlers[#bootHandlers + 1] = fn end
Events.OnGameStart.Add     = function(fn) bootHandlers[#bootHandlers + 1] = fn end

local realRequire = require
require = function() end

for _, src in ipairs({
    LIMES .. "/shared/LMCore.lua",
    LIMES .. "/shared/LMDirge.lua",
    LIMES .. "/client/LMSuppress.lua",
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

-- --------------------------------------------------------------------------
-- Registration
-- --------------------------------------------------------------------------

eq("spawn chance registered",   Limes.fields.spec("dirgeSpawnChance").type, "number")
-- side = "both", changed 2026-08-05 and pinned deliberately. These were
-- server-only until the Details panel arrived to tune them per zone: a field the
-- client is never sent renders as its registered default, so an admin edits a
-- blank and saves it over a value they were never shown. If this ever flips back
-- to "server", the panel silently starts lying - hence the assertion.
eq("dirge fields reach the client", Limes.fields.spec("dirgeGluttonWeight").side, "both")
eq("...spacings too",               Limes.fields.spec("dirgeEMPSpacing").side,    "both")
eq("weights clamp at 100",      Limes.fields.spec("dirgeScreamerWeight").max, 100)
eq("spacing clamps at 300",     Limes.fields.spec("dirgeEMPSpacing").max, 300)
eq("suppression is client-side", Limes.fields.spec("weaponDebuffMult").side, "client")
eq("suppression clamps at 1",    Limes.fields.spec("weaponDebuffMult").max, 1)

-- --------------------------------------------------------------------------
-- Authority: an empty store must defer to whatever was there before
-- --------------------------------------------------------------------------

local delegated = 0
RQPhunZones = {
    getEffectiveRules = function(_, _, cfg)
        delegated = delegated + 1
        return cfg
    end,
}

eq("install finds Dirge",      LMDirge.install(), true)
eq("install is idempotent",    LMDirge.install(), true)

local CFG = { spawnChance = 5, screamerWeight = 1, gluttonSpacing = 30 }

Limes.apply({}, 1)
local out = RQPhunZones.getEffectiveRules(100, 100, CFG)
eq("empty store delegates",      delegated, 1)
eq("delegation returns the cfg", out, CFG)

-- --------------------------------------------------------------------------
-- Takeover once zones exist
-- --------------------------------------------------------------------------

Limes.apply({
    -- Strings on purpose: this is the shape PhunZones persisted and the
    -- importer preserves.
    Hard = { rects = {}, fields = { dirgeSpawnChance = "15", dirgeGluttonWeight = "40" } },
    Downtown = {
        inherits = "Hard",
        rects  = { { 0, 0, 99, 99 } },
        fields = { dirgeScreamerWeight = "150", dirgeEMPSpacing = "400" },
    },
    Quiet = { rects = { { 200, 200, 299, 299 } }, fields = { title = "Quiet" } },
}, 2)

delegated = 0
local zoned = RQPhunZones.getEffectiveRules(50, 50, CFG)
eq("populated store does not delegate", delegated, 0)
isTrue("overlay is a new table", zoned ~= CFG, "must not mutate the caller's cfg")

eq("string coerced to number",  zoned.screamerWeight, 100)   -- "150" clamped to max
eq("spacing clamped to 300",    zoned.empSpacing, 300)       -- "400" clamped
eq("inherited from template",   zoned.spawnChance, 15)       -- via Hard
eq("inherited weight",          zoned.gluttonWeight, 40)
eq("unset reads through cfg",   zoned.gluttonSpacing, 30)    -- __index -> CFG
isTrue("cfg itself untouched",  CFG.screamerWeight == 1, "overlay must not write through")

-- A zone that sets none of Dirge's fields costs no allocation: the caller gets
-- its own table back, which is the fast path the spawn loop depends on.
local plain = RQPhunZones.getEffectiveRules(250, 250, CFG)
eq("zone without dirge fields returns cfg", plain, CFG)

-- Outside every zone, likewise.
local nowhere = RQPhunZones.getEffectiveRules(5000, 5000, CFG)
eq("no zone returns cfg", nowhere, CFG)

-- The zombie-shaped call is the one RQServer actually makes at its three sites.
local fakeZombie = { getX = function() return 50 end, getY = function() return 50 end }
local viaZombie = RQPhunZones.getEffectiveRules(fakeZombie, nil, CFG)
eq("zombie form resolves the same", viaZombie.spawnChance, 15)

-- Deleting every zone hands authority back rather than stranding it.
Limes.apply({}, 3)
delegated = 0
RQPhunZones.getEffectiveRules(50, 50, CFG)
eq("emptied store delegates again", delegated, 1)

-- --------------------------------------------------------------------------
-- Suppression term
-- --------------------------------------------------------------------------

local registered = {}
RQSuppress = {
    register = function(group, source, predicate)
        registered[group .. "." .. source] = predicate
    end,
}
eq("suppress installs", LMSuppress.install(), true)
local predicate = registered["zone.limes"]
isTrue("registered under zone.limes", predicate ~= nil, "RQSuppress contract is (group, source, fn)")

Limes.apply({
    Killbox = { rects = { { 0, 0, 99, 99 } }, fields = { weaponDebuffMult = "0.6" } },
    Neutral = { rects = { { 200, 200, 299, 299 } }, fields = { weaponDebuffMult = 1 } },
    Bare    = { rects = { { 400, 400, 499, 499 } }, fields = { title = "Bare" } },
}, 4)

local function playerAt(x, y)
    return { getX = function() return x end, getY = function() return y end }
end

eq("suppression applies in zone", predicate(playerAt(50, 50)), 0.6)
eq("mult of 1 stays quiet",       predicate(playerAt(250, 250)), nil)
eq("unset stays quiet",           predicate(playerAt(450, 450)), nil)
eq("outside every zone is quiet", predicate(playerAt(9000, 9000)), nil)
eq("no player is quiet",          predicate(nil), nil)

print(string.format("LMDirge/LMSuppress: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

-- ---------------------------------------------------------------------------
-- Copyright Project_Omen
