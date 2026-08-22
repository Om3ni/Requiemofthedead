-- DFSandboxModel fixture - the reflection that feeds the Admin tab.
--
-- WHY THIS EXISTS: this model replaced a registration API. Nothing registers
-- with it; it walks getSandboxOptions() and takes what is there. That is the
-- right call - a registry has two sources of truth and they drift - but it
-- moves the risk into the WALK, and the walk has three ways to be silently
-- wrong: include another mod's options, lose the declaration order that section
-- boundaries depend on, or mistake a real option for a divider. All three
-- render as a panel that looks fine and lies.
--
-- STUBS MODEL THE VERIFIED SURFACE, which is vanilla's own: ServerSettingsScreen
-- builds its mod pages from exactly these calls (:5133-5190). getOptionByIndex
-- is ZERO-based and getValueTranslationByIndex is ONE-based, and the stubs keep
-- that asymmetry because getting it backwards is the obvious bug.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/client/Admin/DFSandboxModel.lua"

local passed, failed = 0, 0
local realPrint = print
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; realPrint("FAIL DFSandboxModel: " .. message) end
end

-- ---- engine stubs -------------------------------------------------------
function isServer() return false end
require = function() return true end
DFKit = {}

local TEXT = {}
function getText(k) return TEXT[k] or k end

local opts = {}   -- declaration order, exactly as the engine preserves it

local function mkOpt(name, page, otype, custom, label, value, default)
    return {
        name = name, page = page, otype = otype, custom = custom,
        label = label, value = value, default = default,
        getName = function(s) return s.name end,
        getPageName = function(s) return s.page end,
        getType = function(s) return s.otype end,
        isCustom = function(s) return s.custom end,
        getTranslatedName = function(s) return s.label end,
        getTooltip = function(s) return s.name .. " tip" end,
        getDefaultValue = function(s) return s.default end,
        getValueAsString = function(s) return tostring(s.value) end,
        getValue = function(s) return s.value end,
        getNumValues = function(s) return s.numValues or 0 end,
        getValueTranslationByIndex = function(s, k) return "v" .. k end,
    }
end

local so = {}
function so:getNumOptions() return #opts end
function so:getOptionByIndex(i) return opts[i + 1] end   -- ZERO-based
function so:getOptionByName(n)
    for _, o in ipairs(opts) do if o.name == n then return o end end
end
function getSandboxOptions() return so end

local function add(...) opts[#opts + 1] = mkOpt(...) end

-- Dirge: two sections via header decoys.
add("RFTDDirge.DebugMode", "RFTDDirge", "boolean", true, "Debug", "false", "false")
add("RFTDDirge.VisualsHeader", "RFTDDirge", "boolean", true,
    "_________ Visuals _________", "false", "false")
add("RFTDDirge.ShowCastBarText", "RFTDDirge", "boolean", true, "Cast bar", "true", "false")
-- Husbandry: no headers at all - must render flat, not broken.
add("RFTDHusbandry.Enable", "RFTDHusbandry", "boolean", true, "Enable", "true", "true")
add("RFTDHusbandry.Rate", "RFTDHusbandry", "double", true, "Rate", "1.5", "1.0")
-- A foreign mod, and a vanilla option. Neither may appear.
add("PhunZones.Something", "PhunZones", "boolean", true, "Phun", "true", "true")
add("Zombies", nil, "enum", false, "Zombie count", "3", "3")

DFSandboxModel = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local mods = DFSandboxModel.build()

-- ---- membership ----------------------------------------------------------
-- isCustom() alone is TRUE for every mod on the server, so it is not a filter
-- for ours. The prefix is. Getting this wrong fills an RFTD admin panel with
-- other people's options.
local pages = {}
for _, m in ipairs(mods) do pages[m.page] = true end
check(pages["RFTDDirge"] and pages["RFTDHusbandry"], "an RFTD page was dropped")
check(not pages["PhunZones"],
    "ANOTHER MOD'S OPTIONS WERE INCLUDED - isCustom() is true for every mod, "
    .. "so the RFTD prefix is the only thing keeping this panel ours")
check(not pages[nil] and #mods == 2, "expected exactly 2 RFTD pages, got " .. #mods)

-- ---- sections ------------------------------------------------------------
local dirge
for _, m in ipairs(mods) do if m.page == "RFTDDirge" then dirge = m end end
check(dirge ~= nil, "Dirge missing")
check(#dirge.sections == 2, "expected 2 Dirge sections, got " .. #dirge.sections)
check(dirge.sections[1].title == nil, "the leading section was given a title")
check(dirge.sections[2].title == "Visuals",
    "section title not cleaned of its underscore scenery, got "
    .. tostring(dirge.sections[2].title))

-- The header itself must NOT appear as a row. It is a divider; showing it as a
-- checkbox is exactly the junk toggle the panel exists to hide.
for _, sec in ipairs(dirge.sections) do
    for _, o in ipairs(sec.options) do
        check(o.short ~= "VisualsHeader", "the header decoy was rendered as an option row")
    end
end
check(dirge.count == 2, "Dirge option count wrong: " .. tostring(dirge.count))

-- Declaration order decides which section an option belongs to, so an option
-- after the header must land after it.
check(dirge.sections[1].options[1].short == "DebugMode", "pre-header option misplaced")
check(dirge.sections[2].options[1].short == "ShowCastBarText", "post-header option misplaced")

-- ---- a mod that declines the convention ---------------------------------
-- It renders flat. It is not broken, and it gets no empty divider above it.
local hb
for _, m in ipairs(mods) do if m.page == "RFTDHusbandry" then hb = m end end
check(#hb.sections == 1, "a header-less mod did not collapse to one section")
check(hb.sections[1].title == nil, "a header-less mod was given a section title")
check(#hb.sections[1].options == 2, "a header-less mod lost options")

-- ---- values are read live, never cached ----------------------------------
-- This is the two-way requirement: a knob turned in the vanilla settings screen
-- must move on this panel. Both are views over the same SandboxOptions, so the
-- model must not snapshot a value at build time.
check(DFSandboxModel.valueOf("RFTDHusbandry.Rate") == "1.5", "value read wrong")
so:getOptionByName("RFTDHusbandry.Rate").value = "2.5"
check(DFSandboxModel.valueOf("RFTDHusbandry.Rate") == "2.5",
    "VALUE WAS CACHED - a change made in the vanilla screen would never appear "
    .. "on this panel, which is the whole two-way promise")

check(DFSandboxModel.isDefault("RFTDHusbandry.Enable"), "a default value read as changed")
check(not DFSandboxModel.isDefault("RFTDHusbandry.Rate"), "a changed value read as default")

-- ---- enums resolve their labels -----------------------------------------
opts = {}
local e = mkOpt("RFTDCore.Mode", "RFTDCore", "enum", true, "Mode", "2", "1")
e.numValues = 3
opts[1] = e
local m2 = DFSandboxModel.build()
local row = m2[1].sections[1].options[1]
check(row.values and #row.values == 3, "enum values not resolved")
check(row.values[1] == "v1", "enum value translation is not 1-based")

realPrint(string.format("DFSandboxModel: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
