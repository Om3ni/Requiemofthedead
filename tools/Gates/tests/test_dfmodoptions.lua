-- test_dfmodoptions.lua - the player panel's adoption of PZAPI.ModOptions.
--
-- WHY THIS EXISTS: this bridge writes to a file it does not own, on behalf of
-- mods that have never heard of us. Two of its behaviours are the kind that
-- are discovered by a stranger losing data:
--
--   * PZAPI.ModOptions:save() rewrites ModOptions.ini from the options loaded
--     THIS session plus `OtherOptions` - the verbatim lines belonging to mods
--     that are not active. `OtherOptions` is filled by :load() and by nothing
--     else, so a save that was not preceded by a successful load ERASES the
--     saved settings of every mod the player is not currently running. The
--     refusal that prevents that is pinned here first, before anything else.
--
--   * every value write goes through a stranger's callbacks in an order
--     MainOptions defined (onChange on interaction, onChangeApply only when
--     the value actually moved, then the mod's apply(), then the file). Get
--     that order wrong and mods misbehave in ways that look like OUR panel is
--     broken, on installs we cannot reproduce.
--
-- WHAT ELSE IT PINS: every ModOptions type maps to the DFForm kind that stores
-- the same thing (combobox and enum both store an INDEX - swapping in a value
-- would be silent corruption); fractional sliders snap to their step instead
-- of accumulating float dust; controls with no equivalent here are shown but
-- refuse the edit rather than vanishing; a mod contributing only headings gets
-- no section; and a key naming a mod that has gone away is a nil read and a
-- swallowed write, not an error.
--
-- Usage (normally via tools\run-tests.bat):
--   lua5.1.exe tools/tests/test_dfmodoptions.lua <repo-root>

local ROOT = arg[1] or "."
local SRC  = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDCore/42/media/lua/client/DFModOptionsBridge.lua"

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
-- Engine stubs
-- ---------------------------------------------------------------------------

require  = function() end
isServer = function() return false end
getText  = function(s) return s end          -- identity: labels are pinned raw
getKeyName = function(code) return "KEY" .. tostring(code) end

local booted = {}
-- Add is called with a dot, so the listener is the FIRST argument.
Events = { OnGameStart = { Add = function(fn) booted[#booted + 1] = fn end } }

-- The registry stub captures the tenancy the bridge registers at file scope.
local sheet
DFPlayerRegistry = {
    registerPlayerSettings = function(spec) sheet = spec end,
}

-- ---------------------------------------------------------------------------
-- A fake PZAPI.ModOptions, shaped exactly like the real one's data
-- (media/lua/client/PZAPI/ModOptions.lua): setValue mutates the option, and
-- the element half is simply absent, which is the case when the ESC options
-- screen has not built its widgets.
-- ---------------------------------------------------------------------------

local loads, saves = 0, 0
local loadThrows = true

PZAPI = { ModOptions = {
    Data = {}, Dict = {},
    load = function(self) loads = loads + 1 if loadThrows then error("no ini") end end,
    save = function(self) saves = saves + 1 end,
} }

local function newGroup(id, name)
    local g = { modOptionsID = id, name = name, data = {}, dict = {}, applied = 0 }
    g.apply = function(self) self.applied = self.applied + 1 end
    table.insert(PZAPI.ModOptions.Data, g)
    PZAPI.ModOptions.Dict[id] = g
    return g
end

local function add(g, o)
    o.changes, o.applies = 0, 0
    o.onChange      = function(self, v) self.changes = self.changes + 1 self.lastChange = v end
    o.onChangeApply = function(self, v) self.applies = self.applies + 1 self.lastApply = v end
    table.insert(g.data, o)
    if o.id then g.dict[o.id] = o end
    return o
end

local function setScalar(self, v) self.value = v end

-- Registered out of alphabetical order on purpose: the sheet must sort.
local zeta = newGroup("zeta", "Zeta Mod")
local zOn = add(zeta, { type = "tickbox", id = "on", name = "Z On", value = true,
                        tooltip = "z tip", setValue = setScalar })

local alpha = newGroup("alpha", "Alpha Mod")
add(alpha, { type = "title", name = "A Heading" })
add(alpha, { type = "description", text = "prose that has no row here" })
add(alpha, { type = "separator" })
local aTick = add(alpha, { type = "tickbox", id = "on", name = "A On", value = false,
                           setValue = setScalar })
local aCombo = add(alpha, { type = "combobox", id = "mode", name = "Mode",
                            values = { "Low", "Mid", "High" }, selected = 2,
                            setValue = function(self, v) self.selected = v end })
local aSlider = add(alpha, { type = "slider", id = "rate", name = "Rate",
                             min = 0, max = 1, step = 0.1, value = 0.5,
                             setValue = setScalar })
local aText = add(alpha, { type = "textentry", id = "note", name = "Note",
                           value = "hi", setValue = setScalar })
local aMulti = add(alpha, { type = "multipletickbox", id = "parts", name = "Parts",
                            values = { { name = "One", value = true },
                                       { name = "Two", value = false } },
                            setValue = function(self, i, v) self.values[i].value = v end })
local aKey = add(alpha, { type = "keybind", id = "bind", name = "Bind", key = 63,
                          tooltip = "bind tip" })
local aColor = add(alpha, { type = "colorpicker", id = "hue", name = "Hue",
                            color = { r = 1, g = 0.5, b = 0, a = 1 } })
local aBtn = add(alpha, { type = "button", id = "go", name = "Go" })

-- A mod that parked only a heading: no dial, so no section.
local empty = newGroup("empty", "Empty Mod")
add(empty, { type = "title", name = "Nothing Below" })

-- ---------------------------------------------------------------------------

local chunk, err = loadfile(SRC)
if not chunk then
    print("FAIL load: " .. tostring(err))
    os.exit(1)
end
chunk()

ok("registered a sheet", sheet ~= nil)
eq("sheet id", sheet and sheet.id, "modoptions")
ok("seated below the family", sheet and sheet.order and sheet.order > 100)
ok("schema is a function", type(sheet and sheet.schema) == "function")
eq("boot listener hooked", #booted, 1)

-- ---------------------------------------------------------------------------
-- THE REFUSAL. While the ini cannot be read, no write may reach save().
-- ---------------------------------------------------------------------------

eq("no save yet", saves, 0)
sheet.set("alpha" .. "\30" .. "on", true)
eq("write refused without a load", aTick.value, false)
eq("save NEVER called without a load", saves, 0)
eq("apply not called either", alpha.applied, 0)

-- Reads are still allowed to try - a blank sheet helps nobody.
eq("read works regardless", sheet.get("alpha\30on"), false)

-- ---------------------------------------------------------------------------
-- With the ini readable, the bridge comes alive - and loads exactly once.
-- ---------------------------------------------------------------------------

loadThrows = false
local loadsBefore = loads
sheet.set("alpha\30on", true)
eq("write lands once loadable", aTick.value, true)
eq("save called", saves, 1)
ok("loaded on demand", loads > loadsBefore)

local loadsAfter = loads
sheet.get("alpha\30on")
sheet.set("alpha\30on", false)
eq("ini read only once", loads, loadsAfter)
eq("second write lands", aTick.value, false)

-- ---------------------------------------------------------------------------
-- Schema shape
-- ---------------------------------------------------------------------------

local s = sheet.schema()

local function rowByLabel(lbl)
    for i = 1, #s do if s[i].label == lbl then return s[i], i end end
    return nil
end
local function groupIndex(name)
    for i = 1, #s do if s[i].group == name then return i end end
    return nil
end

local iAlpha, iZeta = groupIndex("Alpha Mod"), groupIndex("Zeta Mod")
ok("alpha section present", iAlpha ~= nil)
ok("zeta section present", iZeta ~= nil)
ok("sorted by display name, not load order", iAlpha and iZeta and iAlpha < iZeta)
eq("headings-only mod gets no section", groupIndex("Empty Mod"), nil)
ok("a title becomes a sub-header", groupIndex("A Heading") ~= nil)

eq("description dropped", rowByLabel("prose that has no row here"), nil)

local rTick = rowByLabel("A On")
eq("tickbox -> bool", rTick and rTick.kind, "bool")

local rCombo = rowByLabel("Mode")
eq("combobox -> enum", rCombo and rCombo.kind, "enum")
eq("enum value count", rCombo and rCombo.numValues, 3)
eq("enum values carried", rCombo and rCombo.values and rCombo.values[3], "High")

local rSlider = rowByLabel("Rate")
eq("slider -> int", rSlider and rSlider.kind, "int")
eq("slider min", rSlider and rSlider.min, 0)
eq("slider max", rSlider and rSlider.max, 1)
eq("slider step", rSlider and rSlider.step, 0.1)

local rText = rowByLabel("Note")
eq("textentry -> text", rText and rText.kind, "text")

ok("multi box heading", groupIndex("Parts") ~= nil)
local rOne, rTwo = rowByLabel("One"), rowByLabel("Two")
eq("multi row 1 is a bool", rOne and rOne.kind, "bool")
eq("multi row 2 is a bool", rTwo and rTwo.kind, "bool")
ok("multi rows have distinct keys", rOne and rTwo and rOne.key ~= rTwo.key)

local rTip = rowByLabel("Z On")
eq("tooltip becomes help", rTip and rTip.help, "z tip")

-- Controls with no equivalent: shown, and refusing.
local rKey = rowByLabel("Bind")
eq("keybind shown as text", rKey and rKey.kind, "text")
ok("keybind refuses edits", rKey and type(rKey.validate) == "function")
eq("refusal is false", rKey and select(1, rKey.validate("x")), false)
ok("refusal explains where to go", rKey and select(2, rKey.validate("x")):find("ESC") ~= nil)
ok("tooltip kept alongside the refusal", rKey and rKey.help:find("bind tip") ~= nil)
ok("colorpicker shown", rowByLabel("Hue") ~= nil)
ok("button shown", rowByLabel("Go") ~= nil)

-- Every key must be unique - two mods both using "on" is the collision this
-- namespacing exists for.
local seen, dup = {}, false
for i = 1, #s do
    local k = s[i].key
    if k then
        if seen[k] then dup = true end
        seen[k] = true
    end
end
eq("no duplicate keys across mods", dup, false)
eq("no bare key survives", seen["on"], nil)

-- ---------------------------------------------------------------------------
-- Reads, per type
-- ---------------------------------------------------------------------------

eq("bool read", sheet.get(rTick.key), false)
eq("enum read is the INDEX", sheet.get(rCombo.key), 2)
eq("slider read", sheet.get(rSlider.key), 0.5)
eq("text read", sheet.get(rText.key), "hi")
eq("multi read box 1", sheet.get(rOne.key), true)
eq("multi read box 2", sheet.get(rTwo.key), false)
eq("keybind reads a name", sheet.get(rKey.key), "KEY63")
eq("colour reads 0-255", sheet.get(rowByLabel("Hue").key), "255, 128, 0")

eq("unknown key reads nil", sheet.get("ghost\30key"), nil)
eq("malformed key reads nil", sheet.get("nosep"), nil)

-- ---------------------------------------------------------------------------
-- Writes: the callback order MainOptions defined
-- ---------------------------------------------------------------------------

local savesBefore = saves
local appliedBefore = alpha.applied
sheet.set(rCombo.key, 3)
eq("enum write stores the index", aCombo.selected, 3)
eq("onChange fired", aCombo.changes, 1)
eq("onChangeApply fired on real movement", aCombo.applies, 1)
eq("mod apply() ran", alpha.applied, appliedBefore + 1)
eq("file saved", saves, savesBefore + 1)

-- Same value again: interaction hook yes, movement hook no.
sheet.set(rCombo.key, 3)
eq("onChange fires again", aCombo.changes, 2)
eq("onChangeApply does NOT", aCombo.applies, 1)

sheet.set(rTwo.key, true)
eq("multi write lands on its own box", aMulti.values[2].value, true)
eq("multi sibling untouched", aMulti.values[1].value, true)

sheet.set(rText.key, "there")
eq("text write", aText.value, "there")

-- Refused types never write and never save.
local savesAtRefusal = saves
sheet.set(rKey.key, "F1")
eq("keybind write refused", aKey.key, 63)
eq("colour write refused", aColor.color.r, 1)
sheet.set(rowByLabel("Go").key, "x")
eq("no save from a refused type", saves, savesAtRefusal)
eq("button untouched", aBtn.value, nil)

-- A key naming a mod that has gone away: swallowed, not thrown.
sheet.set("ghost\30key", 1)
eq("stale write saves nothing", saves, savesAtRefusal)

-- ---------------------------------------------------------------------------
-- Sliders: fractional steps snap to the grid instead of drifting
-- ---------------------------------------------------------------------------

sheet.set(rSlider.key, 0.5 + 0.1)          -- 0.6000000000000001 in binary
eq("float dust rounded away", aSlider.value, 0.6)
sheet.set(rSlider.key, 0.44)               -- off the grid entirely
eq("off-grid value snapped to step", aSlider.value, 0.4)
sheet.set(rSlider.key, 99)
eq("clamped to max", aSlider.value, 1)
sheet.set(rSlider.key, -99)
eq("clamped to min", aSlider.value, 0)

-- ---------------------------------------------------------------------------
-- An install with nothing parked shows no trace of us.
-- ---------------------------------------------------------------------------

PZAPI.ModOptions.Data, PZAPI.ModOptions.Dict = {}, {}
eq("no mods, no rows", #sheet.schema(), 0)

-- And no PZAPI at all is a quiet nothing, not a crash.
PZAPI = nil
eq("no api, no rows", #sheet.schema(), 0)
eq("no api, nil read", sheet.get("a\30b"), nil)
sheet.set("a\30b", true)

-- ---------------------------------------------------------------------------
print(string.format("DFModOptionsBridge: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
