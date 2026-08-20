-- test_dfplayerregistry.lua - the player panel's tenant registry.
--
-- WHY THIS EXISTS: the settings sheet is ONE DFForm over every mod's
-- registration, which means one composition function decides whether
-- Bookmark's toggle writes to Bookmark's store or to Last Rites' - a routing
-- bug here is silent data corruption across mods, discovered only by a player
-- whose setting "didn't stick" (or worse, stuck somewhere else). So the
-- composition is pinned where it lives, in Core, independent of any shell.
--
-- WHAT IT PINS:
--   * refusals: no id, and no get function, are rejected loudly - a sheet
--     without a reader would render every row blank.
--   * getTabs() sorts by order then label, and isSelectable() honours the
--     placeholder flag (disabled = true reserves a greyed slot).
--   * sheetForm() namespaces keys per tenant, so two mods using the same pref
--     key ("enabled" is inevitable) cannot collide, and routes get/set back
--     to the OWNING tenant with the ORIGINAL key.
--   * a tenant whose schema opens with its own { group = } header keeps it;
--     one without gets a header injected from its title - the sheet always
--     reads as sections-by-mod.
--   * every schema field a tenant supplied rides through the copy (help,
--     min/max/step/unit, values...) - DFForm reads them all.
--   * schema-as-a-function is called fresh on every compose (that is what
--     makes getText() labels translate at open time, not load time).
--   * one tenant's error costs that tenant its value, never the sheet its
--     click handling: a throwing get() reads nil, a throwing set() is
--     swallowed, a missing set() is a no-op.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_dfplayerregistry.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFPlayerRegistry.lua"

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
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        if detail then print("  " .. tostring(detail)) end
    end
end

-- ---------------------------------------------------------------------------
-- Engine + Core stubs. DFPrefs must exist before load: the registry registers
-- Core's display tenant at file scope.
-- ---------------------------------------------------------------------------

require = function() end
isServer = function() return false end

local prefStore = { fontScale = 2, opacity = 60 }
DFPrefs = {
    SCHEMA = {
        { group = "Display" },
        { key = "fontScale", kind = "enum", numValues = 3, label = "Text size" },
        { key = "opacity", kind = "int", min = 20, max = 100, step = 5, label = "Panel opacity" },
    },
    get = function(k) return prefStore[k] end,
    set = function(k, v) prefStore[k] = v end,
}

local chunk, err = loadfile(SRC)
if not chunk then
    print("FAIL load: " .. tostring(err))
    os.exit(1)
end
chunk()

-- ---------------------------------------------------------------------------
-- Refusals and aliases
-- ---------------------------------------------------------------------------

ok("alias registerPlayerTab",      Dragonfly and Dragonfly.registerPlayerTab == DFPlayerRegistry.registerPlayerTab)
ok("alias registerPlayerSettings", Dragonfly and Dragonfly.registerPlayerSettings == DFPlayerRegistry.registerPlayerSettings)

DFPlayerRegistry.registerPlayerTab(nil)
DFPlayerRegistry.registerPlayerTab({ label = "no id" })
eq("tab without id refused", next(DFPlayerRegistry.tabs), nil)

DFPlayerRegistry.registerPlayerSettings({ id = "noget", title = "No Get" })
eq("sheet without get refused", DFPlayerRegistry.sheets["noget"], nil)

-- ---------------------------------------------------------------------------
-- Tab sorting and placeholders
-- ---------------------------------------------------------------------------

DFPlayerRegistry.registerPlayerTab{ id = "zeta",  label = "Zeta",  order = 20 }
DFPlayerRegistry.registerPlayerTab{ id = "alpha", label = "Alpha", order = 20 }
DFPlayerRegistry.registerPlayerTab{ id = "first", label = "First", order = 10, disabled = true }

local tabs = DFPlayerRegistry.getTabs()
eq("tab count", #tabs, 3)
eq("tab order 1", tabs[1].id, "first")
eq("tab order 2 (label breaks tie)", tabs[2].id, "alpha")
eq("tab order 3", tabs[3].id, "zeta")
eq("placeholder not selectable", DFPlayerRegistry.isSelectable(tabs[1]), false)
eq("real tab selectable", DFPlayerRegistry.isSelectable(tabs[2]), true)
eq("nil not selectable", DFPlayerRegistry.isSelectable(nil), false)

-- ---------------------------------------------------------------------------
-- Sheet composition
-- ---------------------------------------------------------------------------

-- Tenant A: no group header of its own, static schema, same key name as B's.
local aStore = { enabled = true }
DFPlayerRegistry.registerPlayerSettings{
    id = "amod", title = "A Mod", order = 20,
    schema = {
        { key = "enabled", kind = "bool", label = "A on", help = "A help" },
    },
    get = function(k) return aStore[k] end,
    set = function(k, v) aStore[k] = v end,
}

-- Tenant B: schema as a FUNCTION, own group header, extra fields, no set.
local composes = 0
local bStore = { enabled = false, reach = 40 }
DFPlayerRegistry.registerPlayerSettings{
    id = "bmod", title = "B Mod", order = 30,
    schema = function()
        composes = composes + 1
        return {
            { group = "B's Own Heading" },
            { key = "enabled", kind = "bool", label = "B on" },
            { key = "reach", kind = "int", min = 0, max = 100, step = 5, unit = "tiles", label = "Reach" },
        }
    end,
    get = function(k) return bStore[k] end,
    -- no set: read-only tenant
}

-- Tenant C: everything it does throws.
DFPlayerRegistry.registerPlayerSettings{
    id = "cmod", title = "C Mod", order = 40,
    schema = { { key = "boom", kind = "bool", label = "Boom" } },
    get = function() error("get boom") end,
    set = function() error("set boom") end,
}

local form = DFPlayerRegistry.sheetForm()
local s = form.schema

-- Display (order 10) leads with its OWN header - none injected for it.
eq("display header kept", s[1].group, "Display")
ok("no doubled display header", s[2].group == nil and s[2].kind == "enum")

-- A Mod (order 20) had no header: one is injected from its title.
local iA
for i = 1, #s do if s[i].group == "A Mod" then iA = i end end
ok("A header injected", iA ~= nil)
ok("A row follows its header", iA and s[iA + 1] and s[iA + 1].kind == "bool")

-- B Mod (order 30) kept its own heading, no "B Mod" header injected.
local sawBTitle, iBHead = false, nil
for i = 1, #s do
    if s[i].group == "B Mod" then sawBTitle = true end
    if s[i].group == "B's Own Heading" then iBHead = i end
end
ok("B's own header kept", iBHead ~= nil)
eq("no header injected for B", sawBTitle, false)

-- Namespacing: the two "enabled" rows are distinct keys, and neither is bare.
local keys = {}
for i = 1, #s do if s[i].key then keys[#keys + 1] = s[i].key end end
local seen, dup = {}, false
for i = 1, #keys do
    if seen[keys[i]] then dup = true end
    seen[keys[i]] = true
end
eq("no duplicate composed keys", dup, false)
eq("no bare key survives", seen["enabled"], nil)

-- Field carry-through on B's int row.
local reachRow
for i = 1, #s do
    if s[i].kind == "int" and s[i].unit == "tiles" then reachRow = s[i] end
end
ok("reach row present", reachRow ~= nil)
eq("min carried", reachRow and reachRow.min, 0)
eq("max carried", reachRow and reachRow.max, 100)
eq("step carried", reachRow and reachRow.step, 5)
eq("label carried", reachRow and reachRow.label, "Reach")

-- Routing: reads reach the owning store with the original key...
local aKey, bKey, bReach, cKey
for i = 1, #s do
    local k = s[i].key
    if k and s[i].label == "A on" then aKey = k end
    if k and s[i].label == "B on" then bKey = k end
    if k and s[i].label == "Reach" then bReach = k end
    if k and s[i].label == "Boom" then cKey = k end
end
eq("A read", form.get(aKey), true)
eq("B read", form.get(bKey), false)
eq("B int read", form.get(bReach), 40)

-- ...writes land on the OWNER and nobody else...
form.set(aKey, false)
eq("A write lands", aStore.enabled, false)
eq("B untouched by A's write", bStore.enabled, false)

-- ...a set-less tenant is a no-op, not an error...
form.set(bKey, true)
eq("read-only tenant unmoved", bStore.enabled, false)

-- ...and a throwing tenant costs only itself.
eq("throwing get reads nil", form.get(cKey), nil)
form.set(cKey, true)   -- must not propagate the error
eq("A still readable after C threw", form.get(aKey), false)

-- Unknown namespaced keys are a nil read and a swallowed write.
eq("unknown key reads nil", form.get("ghost\31key"), nil)
form.set("ghost\31key", 1)

-- Display routes through the DFPrefs stub.
local fsKey
for i = 1, #s do if s[i].numValues == 3 then fsKey = s[i].key end end
eq("display read", form.get(fsKey), 2)
form.set(fsKey, 3)
eq("display write", prefStore.fontScale, 3)

-- Schema functions run fresh per compose.
eq("B composed once", composes, 1)
DFPlayerRegistry.sheetForm()
eq("B composed again on recompose", composes, 2)

-- ---------------------------------------------------------------------------
print(string.format("DFPlayerRegistry: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
