-- RQHighlight fixture - the outline decision, pinned as a table.
--
-- The rule (owner, 2026-09-17): a special's own outline is an operator's
-- per-type switch, all off by default, because the livery's glowing core is
-- the tell. Two things are NOT the switch's to decide: escort paint (a zombie a
-- Boss aura is painting wears Boss colour, whatever it is), and an escorted
-- Boss (outlined while an ordinary zombie stands in its aura, switch or no
-- switch). Every row here is one of those three rules meeting one type.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQHighlight.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQHighlight: " .. message) end
end

-- File-scope surface: the focus claim require, one render listener, RQBoss's
-- published sets. Kept narrow so a new file-scope dereference fails loudly.
local renderHandler
Events = { OnRenderTick = { Add = function(fn) renderHandler = fn end } }
function require(name)
    if name == "RDZombieFocus" then RDZombieFocus = { isFocused = function() return false end } return end
    if name == "RQBoss" then return end
    error("unexpected fixture require: " .. tostring(name))
end
RQBoss = { bossBuffPainted = {}, escorted = {} }
RQConfig = { COLORS = {
    Boss = "gold", Juggernaut = "blue", EMP = "teal", EMPInner = "orange",
    Glutton = "green", Scavenger = "green", Screamer = "purple",
} }
RQRegistry = { activeZombies = {} }
RQCore = { findZombieByID = function() return nil end }

RQHighlight = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(type(renderHandler) == "function", "one render listener registers")

local C = RQConfig.COLORS
local OFF = {}
local function on(...)
    local cfg = {}
    for _, k in ipairs({ ... }) do cfg[k] = true end
    return cfg
end

-- ---------------------------------------------------------------------------
-- Rule 1: everything off by default
-- ---------------------------------------------------------------------------
for _, zType in ipairs({ "Boss", "EMP", "Glutton", "Juggernaut", "Scavenger", "Screamer" }) do
    check(RQHighlight.colourFor(zType, OFF, C, nil, nil) == nil,
        zType .. " carries no outline with every switch off")
end

-- ---------------------------------------------------------------------------
-- Rule 2: each switch owns exactly its own type
-- ---------------------------------------------------------------------------
check(RQHighlight.colourFor("Juggernaut", on("showJuggernautHighlight"), C) == "blue",
    "the Juggernaut switch outlines a Juggernaut in its colour")
check(RQHighlight.colourFor("Screamer", on("showJuggernautHighlight"), C) == nil,
    "and outlines nothing else")
check(RQHighlight.colourFor("EMP", on("showEMPHighlight"), C) == "orange",
    "an EMP outlines in the inner-ring orange, not the ring teal, so body and ring read as one")
check(RQHighlight.colourFor("Glutton", on("showGluttonHighlight"), C) == "green", "Glutton switch")
check(RQHighlight.colourFor("Scavenger", on("showScavengerHighlight"), C) == "green", "Scavenger switch")
check(RQHighlight.colourFor("Screamer", on("showScreamerHighlight"), C) == "purple", "Screamer switch")
check(RQHighlight.colourFor("Boss", on("showBossHighlight"), C) == "gold",
    "the Boss switch outlines a Boss with or without an escort")
check(RQHighlight.colourFor("Boss", on("showBossHighlight"), C, nil, false) == "gold",
    "explicitly unescorted, switch on: still gold")

-- ---------------------------------------------------------------------------
-- Rule 3: escort paint and the escorted Boss are not the switch's to decide
-- ---------------------------------------------------------------------------
check(RQHighlight.colourFor("Boss", OFF, C, nil, true) == "gold",
    "a Boss with an escort is outlined with its switch OFF")
check(RQHighlight.colourFor("Juggernaut", OFF, C, nil, true) == nil,
    "the escort flag means nothing for any other type")
check(RQHighlight.colourFor("Juggernaut", OFF, C, true, nil) == "gold",
    "a Juggernaut inside a Boss aura wears Boss colour with every switch off - escort paint")
check(RQHighlight.colourFor("Juggernaut", on("showJuggernautHighlight"), C, true, nil) == "gold",
    "and Boss colour wins over the type's own colour when both apply")

-- An unknown type has no switch and no colour, rather than a lookup on nil.
check(RQHighlight.colourFor("Wraith", on("showBossHighlight"), C) == nil, "an unknown type is unpainted")
check(RQHighlight.colourFor(nil, OFF, C) == nil, "no type, no outline")

print(string.format("RQHighlight: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
