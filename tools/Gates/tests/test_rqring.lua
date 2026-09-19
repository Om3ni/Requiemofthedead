-- RQRing fixture - which sandbox switch owns which ring, by id prefix.
--
-- The gate is a prefix test, and prefixes nest: "boss_emp_" also starts with
-- "boss_". Until 2026-09-17 the Boss's EMPulse blast ring was therefore owned
-- by the Boss switch, when it is an EMP blast radius like any other. This pins
-- the ownership table so the next nested prefix cannot slip past review.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDDirge/42/media/lua/client/RQRing.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL RQRing: " .. message) end
end

-- Engine surface: a cell that always has a square, a marker factory that
-- records each ring drawn, a clock. Events register and are never fired.
local drawn = {}
local function marker()
    return { remove = function() end, setScaleCircleTexture = function() end }
end
function getCell()
    return { getGridSquare = function() return {} end }
end
function getWorldMarkers()
    -- Method call: self, square, r, g, b, circle flag, size.
    return { addGridSquareMarker = function(_, _, r, g, b, _, size)
        drawn[#drawn + 1] = size
        return marker()
    end }
end
function getTimestampMs() return 1000 end
Events = { OnGameStart = { Add = function() end }, OnTick = { Add = function() end } }

local cfg = {}
RQConfig = { get = function() return cfg end }

RQRing = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))

local white = { r = 1, g = 1, b = 1 }
local function drawsWith(flags, ringId)
    cfg = flags
    local before = #drawn
    RQRing.show(ringId, 0, 0, 0, 5, white)
    RQRing.clear(ringId)
    return #drawn == before + 1
end

-- Every ring id family, with only its OWN switch on. The Boss EMPulse ring
-- is the one whose family is not its prefix.
local FAMILIES = {
    { id = "emp_10_20",       switch = "showEMPRing" },
    { id = "boss_emp_42",     switch = "showEMPRing" },
    { id = "boss_42",         switch = "showBossRing" },
    { id = "boss_aura_42",    switch = "showBossRing" },
    { id = "scav_42",         switch = "showScavengerRing" },
    { id = "scav_eat_42",     switch = "showScavengerRing" },
    { id = "jugg_42",         switch = "showJuggernautRing" },
    { id = "screamer_42",     switch = "showScreamerRing" },
    { id = "glutton_42",      switch = "showGluttonRing" },
}
local ALL = { "showEMPRing", "showBossRing", "showScavengerRing", "showJuggernautRing",
              "showScreamerRing", "showGluttonRing" }

for _, fam in ipairs(FAMILIES) do
    check(not drawsWith({}, fam.id), fam.id .. " is blocked with every switch off")
    check(drawsWith({ [fam.switch] = true }, fam.id), fam.id .. " draws under " .. fam.switch)
    for _, other in ipairs(ALL) do
        if other ~= fam.switch then
            check(not drawsWith({ [other] = true }, fam.id),
                fam.id .. " does not draw under " .. other)
        end
    end
end

-- The regression this fixture exists for, stated on its own.
check(drawsWith({ showEMPRing = true }, "boss_emp_7") and not drawsWith({ showBossRing = true }, "boss_emp_7"),
    "the Boss's EMPulse ring follows the EMP switch and ignores the Boss switch")

-- An id outside every family is not gated at all.
check(drawsWith({}, "somethingelse_1"), "an ungated prefix draws with every switch off")

-- Scale: the marker is asked for radius * TILE_SCALE, the one tweak point.
cfg = { showEMPRing = true }
drawn = {}
RQRing.show("emp_1_1", 0, 0, 0, 8, white)
check(math.abs(drawn[1] - 8 * RQRing.TILE_SCALE) < 0.0001, "ring size is radius times TILE_SCALE")
RQRing.clear("emp_1_1")

print(string.format("RQRing: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
