-- test_rctuning.lua - the Lifecycle tab's dial schema and its input gate.
--
-- WHY THIS IS TESTABLE: RCTuning.lua touches the engine at file scope only
-- through require (stubbed to a no-op). coerce() and field() are pure, and
-- snapshot() needs nothing but a SandboxVars table and an isServer() answer,
-- both of which are one-line stubs.
--
-- WHAT IT PINS, and why each one matters:
--   * coerce IS THE SERVER'S GATE. A client sends {key, value} over the wire
--     and hSetTuning writes whatever survives coerce into the override table,
--     where it is read back on every cfg() call for the rest of the save. An
--     unknown key, a string where a number belongs, or an out-of-range enum
--     must die here or it is durable corruption, not a bad frame.
--   * INTS CLAMP, ENUMS REFUSE. Deliberately asymmetric. A slider dragged to
--     its own maximum should survive a schema whose max later moved down, so
--     ints clamp. An enum index has no meaningful "nearest valid" - option 9
--     of 4 is not option 4, it is a client sending nonsense - so it refuses.
--   * BOOLS ARE STRICT. tonumber("true") is nil and "false" is truthy in Lua,
--     so a bool that accepted anything but a real boolean would set every
--     switch ON the moment a client sent a string.
--   * THE LIVE FLAG. NoVanillaVehicles must stay live = false. The engine
--     snapshots the spawn distribution once per session (VehicleType.java:147),
--     so a panel that presented it as live would be lying, and the tab reads
--     this exact field to decide whether to draw the "restart" marker.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_rctuning.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDReclamation/42/media/lua/shared/RCTuning.lua"

require = function() end

-- RCTuning resolves each dial's help text through getText at load time, so the
-- harness needs a translation stub. Returning the key back is exactly what the
-- engine does for a missing entry, which keeps the "visible failure, not a
-- silent blank" property testable below.
getText = function(k) return k end

local okLoad, err = pcall(dofile, SRC)
if not okLoad then
    print("FATAL: could not load " .. SRC)
    print("  " .. tostring(err))
    os.exit(2)
end

if type(RCTuning) ~= "table" or type(RCTuning.coerce) ~= "function" then
    print("FATAL: RCTuning did not define coerce()")
    os.exit(2)
end

local pass, fail = 0, 0
local function ok(cond, what)
    if cond then pass = pass + 1
    else fail = fail + 1; print("  FAIL " .. what) end
end
local function eq(got, want, what)
    ok(got == want, string.format("%s (got %s, want %s)",
        what, tostring(got), tostring(want)))
end

-- ---------------------------------------------------------------------------
-- Unknown keys - the first thing a hostile or stale client hits
-- ---------------------------------------------------------------------------
local v, reason = RCTuning.coerce("NotADial", 5)
eq(v, nil, "unknown key refused")
eq(reason, "unknown", "unknown key reports why")

v, reason = RCTuning.coerce("__proto__", true)
eq(v, nil, "junk key refused")

-- A key that exists in SandboxVars but is NOT on the schema must still be
-- refused: the schema is the allow-list, not the sandbox file. Otherwise the
-- panel becomes a general-purpose writer for every option the mod has.
v = RCTuning.coerce("SpawnerAccess", 3)
eq(v, nil, "off-schema sandbox option refused")

-- ---------------------------------------------------------------------------
-- Booleans - strict, because Lua truthiness is not the client's truthiness
-- ---------------------------------------------------------------------------
eq(RCTuning.coerce("JanitorEnabled", true), true, "bool true accepted")
eq(RCTuning.coerce("JanitorEnabled", false), false, "bool false accepted")
eq(RCTuning.coerce("JanitorEnabled", "true"), nil, "bool rejects string 'true'")
eq(RCTuning.coerce("JanitorEnabled", "false"), nil, "bool rejects string 'false'")
eq(RCTuning.coerce("JanitorEnabled", 1), nil, "bool rejects 1")
eq(RCTuning.coerce("JanitorEnabled", 0), nil, "bool rejects 0")
eq(RCTuning.coerce("JanitorEnabled", nil), nil, "bool rejects nil")

-- ---------------------------------------------------------------------------
-- Integers - clamped, floored, and never a string
-- ---------------------------------------------------------------------------
eq(RCTuning.coerce("RespawnPerSweep", 5), 5, "int in range passes through")
eq(RCTuning.coerce("RespawnPerSweep", -3), 0, "int below min clamps to min")
eq(RCTuning.coerce("RespawnPerSweep", 9999), 20, "int above max clamps to max")
eq(RCTuning.coerce("RespawnPerSweep", 0), 0, "int zero is legal (pauses placement)")
eq(RCTuning.coerce("RespawnPerSweep", 3.7), 3, "int floors a float")
eq(RCTuning.coerce("RespawnPerSweep", "hello"), nil, "int rejects a non-numeric string")
eq(RCTuning.coerce("RespawnPerSweep", true), nil, "int rejects a boolean")

-- A numeric string is accepted (tonumber): the wire may carry either, and
-- refusing "5" would be a false negative on a legitimate client.
eq(RCTuning.coerce("RespawnPerSweep", "5"), 5, "int accepts a numeric string")

-- The distance pair - the dials most likely to be sent absurd values.
eq(RCTuning.coerce("RespawnMinDistance", 0), 0, "min distance may be zero")
eq(RCTuning.coerce("RespawnMinDistance", 100000), 400, "min distance clamps")
eq(RCTuning.coerce("RespawnMaxDistance", 5), 20, "max distance clamps up to its floor")
eq(RCTuning.coerce("RespawnMaxDistance", 1000), 1000, "max distance accepts its ceiling")

-- Janitor window: 0 is meaningful (off), so it must not be clamped away.
eq(RCTuning.coerce("JanitorAbandonDays", 0), 0, "abandonment window accepts 0 (= off)")
eq(RCTuning.coerce("JanitorAbandonDays", 365), 365, "abandonment window accepts its max")
eq(RCTuning.coerce("JanitorAbandonDays", -1), 0, "abandonment window clamps negatives")

-- ---------------------------------------------------------------------------
-- Enums - refused rather than clamped
-- ---------------------------------------------------------------------------
eq(RCTuning.coerce("RespawnCondition", 1), 1, "enum accepts first option")
eq(RCTuning.coerce("RespawnCondition", 4), 4, "enum accepts last option")
v, reason = RCTuning.coerce("RespawnCondition", 5)
eq(v, nil, "enum refuses past the last option")
eq(reason, "range", "enum out of range reports why")
eq(RCTuning.coerce("RespawnCondition", 0), nil, "enum refuses 0 (options are 1-based)")
eq(RCTuning.coerce("RespawnCondition", -1), nil, "enum refuses a negative")

-- ---------------------------------------------------------------------------
-- Schema integrity - the tab renders straight off this
-- ---------------------------------------------------------------------------
local dials, groups = 0, 0
local seen = {}
for i = 1, #RCTuning.SCHEMA do
    local f = RCTuning.SCHEMA[i]
    if f.group then
        groups = groups + 1
    else
        dials = dials + 1
        ok(type(f.key) == "string" and f.key ~= "", "entry " .. i .. " has a key")
        ok(not seen[f.key], "key " .. tostring(f.key) .. " appears once")
        seen[f.key] = true
        ok(type(f.label) == "string" and f.label ~= "", tostring(f.key) .. " has a label")
        ok(f.kind == "bool" or f.kind == "int" or f.kind == "enum",
            tostring(f.key) .. " has a known kind")
        -- Every dial must carry help. DFForm only draws the "?" glyph when it
        -- finds a non-empty string, so a missing one is invisible in the panel
        -- - the row simply has no way to explain itself and nothing complains.
        -- A bulk edit once landed this field INSIDE the neighbouring `values`
        -- table on one entry, which parsed fine and silently cost that dial its
        -- help; this assertion is what makes that class of slip loud.
        ok(type(f.help) == "string" and f.help ~= "",
            tostring(f.key) .. " has help text")
        ok(f.help == "Sandbox_RC_" .. tostring(f.key) .. "_tooltip",
            tostring(f.key) .. " help resolves from its own sandbox tooltip key")
        if f.kind == "int" then
            ok(type(f.min) == "number" and type(f.max) == "number",
                tostring(f.key) .. " int declares min and max")
            ok(f.min < f.max, tostring(f.key) .. " int range is non-empty")
        elseif f.kind == "enum" then
            ok(type(f.numValues) == "number" and f.numValues > 1,
                tostring(f.key) .. " enum declares numValues")
            ok(type(f.values) == "table" and #f.values == f.numValues,
                tostring(f.key) .. " enum labels match numValues")
        end
    end
end
ok(dials > 0, "schema declares dials")
ok(groups > 0, "schema declares group headers")

-- Every dial must round-trip through field() - the tab and the server both
-- resolve by key, and a dial the index cannot find is a control that silently
-- does nothing.
for key in pairs(seen) do
    ok(RCTuning.field(key) ~= nil, "field() resolves " .. key)
end
eq(RCTuning.field("NopeNotHere"), nil, "field() returns nil for an unknown key")

-- The one dial that is NOT live, and the reason it must stay that way.
local nv = RCTuning.field("NoVanillaVehicles")
ok(nv ~= nil, "NoVanillaVehicles is on the schema")
eq(nv and nv.live, false, "NoVanillaVehicles is marked restart-required")
ok(nv and type(nv.note) == "string" and nv.note ~= "",
    "NoVanillaVehicles explains why it needs a restart")

-- Its sibling IS live: the story interceptor reads cfg per spawn, so toggling
-- it takes effect immediately. If these two ever get the same flag, one of
-- them is lying to the admin.
local ns = RCTuning.field("NoVanillaStoryVehicles")
ok(ns ~= nil, "NoVanillaStoryVehicles is on the schema")
eq(ns and ns.live, true, "NoVanillaStoryVehicles is live")

-- ---------------------------------------------------------------------------
-- snapshot() - what the panel paints when the sandbox is sparse
-- ---------------------------------------------------------------------------
isServer = function() return false end
RCShared = RCShared or {}
local fakeOverrides = { RespawnPerSweep = 7 }
RCShared.getOverrides = function() return fakeOverrides end

SandboxVars = { RFTDReclamation = { JanitorAbandonDays = 21, RespawnPerSweep = 2 } }

local values, moved = RCTuning.snapshot()
eq(values.RespawnPerSweep, 7, "snapshot prefers the override")
eq(moved.RespawnPerSweep, true, "snapshot marks an overridden dial as moved")
eq(values.JanitorAbandonDays, 21, "snapshot falls through to sandbox")
eq(moved.JanitorAbandonDays, nil, "snapshot does not mark an un-overridden dial")

-- A dial absent from BOTH layers must still render something sane rather than
-- a blank control - this is the case for a save whose sandbox file predates
-- the option.
ok(values.RespawnMinDistance ~= nil, "snapshot bakes a default for a missing option")
eq(values.RespawnCondition, 1, "missing enum defaults to option 1")
eq(values.RespawnEnabled, true, "missing bool defaults to on")

print(string.format("RCTuning: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
