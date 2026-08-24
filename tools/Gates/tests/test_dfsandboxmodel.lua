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
local DF = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua"
local SOURCE = DF .. "/client/Admin/DFSandboxModel.lua"

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
-- The REAL DFOverlay. buildServer stamps its page with DFOverlay.SERVER_KEY and
-- three separate files key on that constant agreeing; a stubbed string here
-- would let them drift apart while every fixture stayed green.
dofile(DF .. "/shared/DFOverlay.lua")

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

-- ---- SERVER options - a DIFFERENT registry with a SMALLER surface ---------
--
-- buildServer had no fixture at all until 2026-08-23, and a live 42.20.3 client
-- found out why: it reused the sandbox reader, which calls getTranslatedName().
-- A ServerOption does not have one. Its interface is asConfigOption() and
-- getTooltip() and nothing more (ServerOptions.java:637-641); getName() and
-- getType() come from the *ConfigOption base it extends, which is precisely why
-- those two worked and the third threw "Object tried to call nil".
--
-- SO THE FAKE BELOW DELIBERATELY OMITS getTranslatedName. That omission is the
-- test. Per CLAUDE.md sect. 2 a fixture must implement the verified surface it
-- stands in for and no more - a fake that is more generous than the engine
-- proves nothing, and this one was generous in exactly one method.

local sopts = {}
local function mkServerOpt(name, otype, value, default)
    return {
        name = name, otype = otype, value = value, default = default,
        getName    = function(s) return s.name end,
        getType    = function(s) return s.otype end,
        -- getTranslatedName is ABSENT ON PURPOSE. Do not add it.
        getTooltip = function(s) return s.name .. " tip" end,
        getDefaultValue  = function(s) return s.default end,
        getValueAsString = function(s) return tostring(s.value) end,
        getValue         = function(s) return s.value end,
        getNumValues = function(s) return s.numValues or 0 end,
        getValueTranslationByIndex = function(s, k) return "sv" .. k end,
    }
end
local svo = {}
function svo:getNumOptions() return #sopts end
function svo:getOptionByIndex(i) return sopts[i + 1] end   -- ZERO-based
function svo:getOptionByName(n)
    for _, o in ipairs(sopts) do if o.name == n then return o end end
end
function getServerOptions() return svo end
local function addSv(...) sopts[#sopts + 1] = mkServerOpt(...) end

addSv("PVP", "boolean", "true", "true")
addSv("PVPMeleeDamageModifier", "double", "0.3", "0.3")
addSv("SafehouseAllowTrepass", "boolean", "true", "true")
addSv("MapRemotePlayerVisibility", "integer", "1", "1")
addSv("ServerWelcomeMessage", "text", "hi", "")
addSv("SomethingUnbucketed", "boolean", "false", "false")

local sv = DFSandboxModel.buildServer()
check(sv ~= nil, "buildServer returned nothing")

-- THE REGRESSION. Reading a server option must not touch getTranslatedName,
-- and the label falls back to the raw name - which is what vanilla's own
-- settings screen shows (ServerSettingsScreen.lua:2570).
-- buildServer returns ONE page-shaped table - the same shape build() emits per
-- mod - so the view never has to know which registry it is drawing.
local function findRow(page, name)
    for _, sec in ipairs((page or {}).sections or {}) do
        for _, r in ipairs(sec.options) do
            if r.name == name then return r, sec end
        end
    end
end
local pvp = findRow(sv, "PVP")
check(pvp ~= nil, "the PVP server option did not survive the walk")
check(pvp and pvp.label == "PVP",
    "a server option's label was not its raw name: " .. tostring(pvp and pvp.label))
check(pvp and pvp.type == "boolean", "the server option type was lost")
check(pvp and pvp.tooltip == "PVP tip", "the server option tooltip was lost")

-- Server names are not namespaced, so short == name. Downstream keys on name,
-- but the view draws short, and letting them diverge here would silently
-- truncate every row at the first dot in a value like a welcome message.
check(pvp and pvp.short == "PVP", "short diverged from name on a server option")

-- Bucketing is by name prefix, longest-match irrelevant - PVPMeleeDamage...
-- must land under PVP, not under a section of its own.
local _, pvpSec = findRow(sv, "PVPMeleeDamageModifier")
check(pvpSec and pvpSec.title == "PVP",
    "PVPMeleeDamageModifier landed in section " .. tostring(pvpSec and pvpSec.title))

-- Anything matching no prefix goes to Other, and Other sorts LAST - it is the
-- leftovers bucket and reads as one at the bottom, not wedged between Map and
-- PVP.
local _, otherSec = findRow(sv, "SomethingUnbucketed")
check(otherSec and otherSec.title == "Other", "an unbucketed option missed Other")
local secs = sv.sections
check(secs[#secs].title == "Other", "Other was not sorted last")
for i = 2, #secs - 1 do
    check(secs[i - 1].title < secs[i].title,
        "server sections were not alphabetical before Other")
end

-- The page carries the sentinel three files key on, and a total the footer
-- draws without re-walking.
check(sv.page == DFOverlay.SERVER_KEY, "the server page lost its sentinel key")
check(sv.count == #sopts, "the page count was " .. tostring(sv.count)
    .. ", expected " .. #sopts)

-- Enum server options resolve their labels the same 1-based way. Their
-- translations are hardcoded to AntiCheat's keys in the engine
-- (ServerOptions.java:629-634) - TIS's quirk, not ours - so the only thing
-- worth pinning here is the indexing.
sopts = {}
local se = mkServerOpt("AntiCheatProtectionType", "enum", "2", "1")
se.numValues = 3
sopts[1] = se
local sv2 = DFSandboxModel.buildServer()
local srow = findRow(sv2, "AntiCheatProtectionType")
check(srow and srow.values and #srow.values == 3, "server enum values not resolved")
check(srow and srow.values[1] == "sv1", "server enum translation is not 1-based")
check(srow and srow.label == "AntiCheatProtectionType",
    "an enum server option's label was not its raw name")

-- No registry at all is nil, not an empty page: the view must be able to tell
-- "there are no server options" from "this build has no server options screen".
function getServerOptions() return nil end
check(DFSandboxModel.buildServer() == nil,
    "buildServer invented a page when the registry was absent")

realPrint(string.format("DFSandboxModel: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
