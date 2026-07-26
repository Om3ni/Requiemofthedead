-- RQConfig - all the knobs in one place
-- Sandbox options are enum-based (indices into value arrays)
-- so the player picks from a dropdown instead of typing numbers.
-- Cached after first read so we're not hitting SandboxVars every tick.

RQConfig = RQConfig or {}

RQConfig.JUGGERNAUT_MIN_BASE_HEALTH = 1.0

RQConfig.HEALTH_MULTIPLIER = {
    Screamer   = 2,
    Juggernaut = 10,  -- big health pool to survive being in the open while casting, and to make EMP and Glutton devouring more meaningful
    EMP        = 2,
    Glutton    = 2,   -- starts tougher, grows more by eating
    Scavenger  = 2,   -- survives long enough to actually rage
    Boss       = 10,
}

RQConfig.COLORS = {
    Screamer   = { r = 0.6, g = 0.0,  b = 1.0,  a = 0.6 },  -- Purple
    Juggernaut = { r = 0.2, g = 0.6,  b = 1.0,  a = 0.3 },  -- Blue (matches JUGG_RING_COLOR so ring and buffed normals are identical)
    EMP        = { r = 0.2, g = 0.95, b = 0.7,  a = 0.4 },  -- Electric teal (cast/detonation telegraph ring)
    EMPInner   = { r = 1.0, g = 0.4,  b = 0.0,  a = 0.6 },  -- Orange: EMP body highlight + inner knockdown ring share this (distinct from Juggernaut blue)
    Glutton    = { r = 0.1, g = 1.0,  b = 0.2,  a = 0.3 },  -- Green
    Scavenger  = { r = 0.1, g = 1.0,  b = 0.2,  a = 0.3 },  -- Green (passive); shifts to red->blue rage gradient via RQScavenger.getHighlightColor on rage
    Boss       = { r = 1.0, g = 0.84, b = 0.0,  a = 0.4 },  -- Gold
}

RQConfig.SCREAMER_SPAWN_RADIUS = 8  -- Radius for spawning new zombies

-- sandbox-options.txt enum options store 1-based indices

local E_SPAWN_CHANCE        = {1, 3, 5, 10, 15, 20, 30}         -- default idx=4 -> 10%
-- (per-type spacing is now integer sandbox options, no enum table needed)
local E_CAST_5              = {1, 2, 3, 5, 8}                    -- 5-tier cast time (seconds)
local E_CAST_4              = {1, 2, 3, 5}                       -- 4-tier cast time (seconds)
local E_TYPE_WEIGHT         = {0, 5, 10, 15, 20, 30, 40, 50}    -- per-type spawn weight %
local E_SCREAMER_INTERVAL   = {15, 30, 45, 60, 90, 120}          -- default idx=4 -> 60s
local E_SCREAMER_CAST       = {1, 2, 3, 5, 8}                    -- default idx=3 -> 3s
local E_SCREAMER_RANGE      = {10, 15, 20, 30, 40}               -- default idx=3 -> 20
local E_SCREAMER_SOUND      = {20, 40, 60, 80, 100}              -- default idx=3 -> 60
local E_SCREAMER_SPAWN_MIN  = {10, 15, 20, 25}                   -- default idx=1 -> 10
local E_SCREAMER_SPAWN_MAX  = {15, 20, 25, 30}                   -- default idx=3 -> 25
local E_SCREAMER_THRESHOLD  = {3, 5, 8, 10, 15}                  -- default idx=2 -> 5
local E_JUGG_RADIUS         = {3, 5, 8, 12, 20}                  -- default idx=3 -> 8
local E_JUGG_BUFF           = {5, 10, 15, 20, 25}                -- default idx=2 -> 10%
local E_EMP_RANGE           = {5, 10, 15, 20, 30}                -- default idx=3 -> 15
local E_EMP_CAST            = {1, 2, 3, 5, 8}                    -- default idx=3 -> 3s
local E_EMP_RADIUS          = {3, 5, 8, 12, 20}                  -- default idx=3 -> 8
local E_EMP_DRAIN           = {20, 35, 50, 75}                   -- default idx=2 -> 35%
local E_GLUTTON_RADIUS      = {1, 2, 3, 5, 8, 12, 20}            -- default idx=7 -> 20
local E_GLUTTON_MULT        = {2, 3, 5, 8, 10}                   -- default idx=3 -> 5
local E_DEVOUR_TIME         = {10, 20, 30, 45, 60, 90}           -- default idx=1 -> 10s
local E_BOSS_COOLDOWN       = {5, 10, 15, 20, 30, 60}            -- default idx=3 -> 15s

-- Get actual value from enum index, fall back to default when out of bounds
local function ev(tbl, idx, defaultIdx)
    local i = idx or defaultIdx
    return tbl[i] or tbl[defaultIdx]
end

-- Cached config singleton (avoids creating new table on each call)
local cachedConfig = nil

-- Read sandbox options with default fallback (result cached, table created only on first call)
function RQConfig.get()
    if cachedConfig then return cachedConfig end
    local sv = SandboxVars and SandboxVars.RFTDDirge

    local screamMin = ev(E_SCREAMER_SPAWN_MIN, sv and sv.ScreamerSpawnMin, 1)
    local screamMax = ev(E_SCREAMER_SPAWN_MAX, sv and sv.ScreamerSpawnMax, 3)

    -- EMP sensory shock durations (ms). Blind is deliberately much shorter
    -- than deafen: with zeds closing in, 3s without sight is a death
    -- sentence, not a scare. Min is clamped to Max so a partial sandbox edit
    -- can't invert the roll; Max = 0 disables that effect outright.
    local blindMax = math.max(0, math.min(10000, tonumber(sv and sv.EMPBlindMaxMs) or 2000))
    local blindMin = math.min(blindMax, math.max(0, tonumber(sv and sv.EMPBlindMinMs) or 500))
    local deafMax  = math.max(0, math.min(30000, tonumber(sv and sv.EMPDeafMaxMs) or 5000))
    local deafMin  = math.min(deafMax, math.max(0, tonumber(sv and sv.EMPDeafMinMs) or 3000))

    cachedConfig = {
        -- General
        enabled              = not (sv and sv.Enabled == false),
        debugMode            = (sv and sv.DebugMode == true),
        spawnChance          = ev(E_SPAWN_CHANCE, sv and sv.SpawnChance, 4),

        -- Per-type spawn weight (% chance once the initial spawn roll passes)
        -- Under 100 leaves remainder = no spawn. Over 100 is normalized
        -- server-side so enabled types keep proportional odds.
        screamerWeight       = ev(E_TYPE_WEIGHT, sv and sv.ScreamerWeight, 2),     -- 5%
        juggernautWeight     = ev(E_TYPE_WEIGHT, sv and sv.JuggernautWeight, 4),   -- 15%
        empWeight            = ev(E_TYPE_WEIGHT, sv and sv.EMPWeight, 5),           -- 20%
        gluttonWeight        = ev(E_TYPE_WEIGHT, sv and sv.GluttonWeight, 6),      -- 30%
        scavengerWeight      = ev(E_TYPE_WEIGHT, sv and sv.ScavengerWeight, 2),    -- 5%

        -- Per-type spacing (integer sandbox options, 0-150 tiles).
        -- Each type checks its own spacing independently of other types:
        -- a new Glutton only needs to clear gluttonSpacing distance from
        -- OTHER Gluttons, not from Juggernauts or anything else. 0
        -- disables the spacing check entirely for that type.
        screamerSpacing      = tonumber(sv and sv.ScreamerSpacing) or 150,
        juggernautSpacing    = tonumber(sv and sv.JuggernautSpacing) or 150,
        empSpacing           = tonumber(sv and sv.EMPSpacing) or 150,
        gluttonSpacing       = tonumber(sv and sv.GluttonSpacing) or 150,
        scavengerSpacing     = tonumber(sv and sv.ScavengerSpacing) or 150,

        -- Per-type enable
        screamerEnabled      = not (sv and sv.ScreamerEnabled == false),
        juggernautEnabled    = not (sv and sv.JuggernautEnabled == false),
        empEnabled           = not (sv and sv.EMPEnabled == false),
        gluttonEnabled       = not (sv and sv.GluttonEnabled == false),
        scavengerEnabled     = not (sv and sv.ScavengerEnabled == false),

        -- Screamer
        screamerRepeatInterval = ev(E_SCREAMER_INTERVAL, sv and sv.ScreamerRepeatInterval, 4) * 1000,
        screamerCastTime       = ev(E_SCREAMER_CAST, sv and sv.ScreamerCastTime, 3) * 1000,
        screamerTriggerRange   = ev(E_SCREAMER_RANGE, sv and sv.ScreamerTriggerRange, 3),
        screamerSoundRadius    = ev(E_SCREAMER_SOUND, sv and sv.ScreamerSoundRadius, 3),
        screamerSpawnMin       = screamMin,
        screamerSpawnMax       = math.max(screamMin, screamMax),
        screamerSpawnThreshold = ev(E_SCREAMER_THRESHOLD, sv and sv.ScreamerSpawnThreshold, 2),

        -- Juggernaut
        juggernautHealthMultiplier = math.max(1, math.min(50,
            tonumber(sv and sv.JuggernautHealthMultiplier) or RQConfig.HEALTH_MULTIPLIER.Juggernaut)),
        juggernautBuffRadius   = ev(E_JUGG_RADIUS, sv and sv.JuggernautBuffRadius, 3),
        juggernautBuffPercent  = ev(E_JUGG_BUFF, sv and sv.JuggernautBuffPercent, 2),
        -- Sandbox value is "weapon damage REDUCTION %" (0 = no debuff, 100 = weapons disabled).
        -- We invert it here so the rest of the code can keep treating the result as a plain
        -- damage multiplier (1.0 = full damage, 0.5 = half, 0.0 = none). Flipping it at this
        -- boundary means every consumer (jugg, boss, scav) keeps its math unchanged.
        juggernautAuraMultiplier = (100 - math.max(0, math.min(100,
            tonumber(sv and sv.JuggernautAuraMultiplier) or 0))) / 100.0,

        -- EMP
        empTriggerRange        = ev(E_EMP_RANGE, sv and sv.EMPTriggerRange, 3),
        empCastTime            = ev(E_EMP_CAST, sv and sv.EMPCastTime, 3) * 1000,
        empRadius              = ev(E_EMP_RADIUS, sv and sv.EMPRadius, 3),
        empBatteryDrain        = ev(E_EMP_DRAIN, sv and sv.EMPBatteryDrain, 2),
        empBlindMinMs          = blindMin,
        empBlindMaxMs          = blindMax,
        empDeafMinMs           = deafMin,
        empDeafMaxMs           = deafMax,

        -- Glutton
        gluttonRadius          = ev(E_GLUTTON_RADIUS, sv and sv.GluttonRadius, 7),
        gluttonMaxMult         = ev(E_GLUTTON_MULT, sv and sv.GluttonMaxMult, 3),

        -- Devouring (shared by Glutton and Scavenger)
        devourTime             = ev(E_DEVOUR_TIME, sv and sv.DevourTime, 1) * 1000,
        -- Boss (admin spawn only)
        bossCastTime           = ev(E_CAST_4, sv and sv.BossCastTime, 3) * 1000,
        bossSkillCooldown      = ev(E_BOSS_COOLDOWN, sv and sv.BossSkillCooldown, 3) * 1000,

        -- Admin / visual options
        showHealthBars         = (sv and sv.ShowHealthBars == true),
        showCastBarText        = (sv and sv.ShowCastBarText == true),    -- default off; EMP labels always shown regardless

        -- Per-type ground-ring visibility. The single global ShowGroundRings
        -- toggle was replaced with these so admins can grant ring telegraphs
        -- on a per-zombie-type basis. Boss and EMP default true -- boss is
        -- apex-tier and needs the skill telegraph, and every emp_* ring IS
        -- the death-detonation warning (EMP has no other rings), which is a
        -- lethal-AoE telegraph players shouldn't lose to an opt-in default.
        -- Everything else defaults false.
        showBossRing           = (sv == nil) and true or (sv.ShowBossRing       ~= false),
        showEMPRing            = (sv == nil) and true or (sv.ShowEMPRing        ~= false),
        showGluttonRing        = (sv and sv.ShowGluttonRing    == true),
        showJuggernautRing     = (sv and sv.ShowJuggernautRing == true),
        showScavengerRing      = (sv and sv.ShowScavengerRing  == true),
        showScreamerRing       = (sv and sv.ShowScreamerRing   == true),

        -- Screamer screen effect strengths (0–1 scale; sandbox exposes as 0–100 integer)
        screamerBlurStrength   = math.max(0, math.min(100, tonumber(sv and sv.ScreamerBlurStrength) or 100)) / 100.0,
        screamerDarkStrength   = math.max(0, math.min(100, tonumber(sv and sv.ScreamerDarkStrength) or 100)) / 100.0,
    }
    return cachedConfig
end

-- Clear config cache (called on game restart to load new sandbox options)
function RQConfig.invalidateCache()
    cachedConfig = nil
end

function RQConfig.getHealthMultiplier(zType)
    if zType == "Juggernaut" then
        return RQConfig.get().juggernautHealthMultiplier or RQConfig.HEALTH_MULTIPLIER.Juggernaut
    end
    return RQConfig.HEALTH_MULTIPLIER[zType]
end

Events.OnGameStart.Add(RQConfig.invalidateCache)

-- Periodic config refresh (catches mid-game sandbox changes, ~1 minute interval)
local configRefreshTicks = 0
Events.OnTick.Add(function()
    configRefreshTicks = configRefreshTicks + 1
    if configRefreshTicks >= 3600 then
        configRefreshTicks = 0
        RQConfig.invalidateCache()
    end
end)

-- Copyright Project_Omen
