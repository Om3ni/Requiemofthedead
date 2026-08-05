-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQConfig - all the knobs in one place
-- Sandbox options are enum-based (indices into value arrays)
-- so the player picks from a dropdown instead of typing numbers.
-- Cached after first read so we're not hitting SandboxVars every tick.

RQConfig = RQConfig or {}

-- Single source in RQCommon (was a drifting duplicate of the server's copy).
RQConfig.JUGGERNAUT_MIN_BASE_HEALTH = RQCommon.JUGGERNAUT_MIN_BASE_HEALTH
RQConfig.HEALTH_MULTIPLIER          = RQCommon.HEALTH_MULTIPLIER

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

-- sandbox-options.txt enum options store 1-based indices.
-- Single source in RQCommon.ENUMS - aliases, not copies. The old client copy
-- of DEVOUR_TIME had drifted to {10,...} against the server's {15,...}: the
-- cast bar showed 10s for a 15s devour at defaults. Server values are truth.
local E = RQCommon.ENUMS
-- (per-type spacing and every spawn-chance % are integer sandbox options now,
--  no enum table needed)
local E_CAST_4              = E.CAST_4
local E_SCREAMER_INTERVAL   = E.SCREAMER_INTERVAL
local E_SCREAMER_CAST       = E.SCREAMER_CAST
local E_SCREAMER_RANGE      = E.SCREAMER_RANGE
local E_SCREAMER_SOUND      = E.SCREAMER_SOUND
local E_SCREAMER_SPAWN_MIN  = E.SCREAMER_SPAWN_MIN
local E_SCREAMER_SPAWN_MAX  = E.SCREAMER_SPAWN_MAX
local E_SCREAMER_THRESHOLD  = E.SCREAMER_THRESHOLD
local E_JUGG_RADIUS         = E.JUGG_RADIUS
local E_JUGG_BUFF           = E.JUGG_BUFF
local E_EMP_RANGE           = E.EMP_RANGE
local E_EMP_CAST            = E.EMP_CAST
local E_EMP_RADIUS          = E.EMP_RADIUS
local E_EMP_DRAIN           = E.EMP_DRAIN
local E_GLUTTON_RADIUS      = E.GLUTTON_RADIUS
local E_GLUTTON_MULT        = E.GLUTTON_MULT
local E_DEVOUR_TIME         = E.DEVOUR_TIME
local E_BOSS_COOLDOWN       = E.BOSS_COOLDOWN

local ev  = RQCommon.ev
local pct = RQCommon.pct

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
        -- Straight percent, 1% steps (0-100). Same for the five weights below;
        -- PhunZones' per-zone overrides were already raw percentages, so these
        -- reads now speak the overlay's language directly.
        spawnChance          = pct(sv and sv.SpawnChance, 10),

        -- Per-type spawn weight (% chance once the initial spawn roll passes)
        -- Under 100 leaves remainder = no spawn. Over 100 is normalized
        -- server-side so enabled types keep proportional odds.
        screamerWeight       = pct(sv and sv.ScreamerWeight, 5),
        juggernautWeight     = pct(sv and sv.JuggernautWeight, 15),
        empWeight            = pct(sv and sv.EMPWeight, 20),
        gluttonWeight        = pct(sv and sv.GluttonWeight, 30),
        scavengerWeight      = pct(sv and sv.ScavengerWeight, 5),

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
        --
        -- ONE KNOB, THREE FEATURES: Boss and Scavenger auras reuse this exact value
        -- (RQSuppress reads all three playerInAura flags into its "aura" term
        -- group), so changing it moves all three specials' weapon debuffs together.
        --
        -- The shipped default is 40 (declared in media/sandbox-options.txt), i.e. weapons
        -- deal 60% damage inside an aura. The `or 0` below is NOT a second copy of that
        -- default and must NOT be "aligned" to 40 - it is a deliberate fail-SAFE for the
        -- case where SandboxVars.RFTDDirge is unreadable (the duplicate-mod-id trap: a
        -- client subscribed to both a legacy per-mod item and the bundle loads the legacy
        -- copy, which may not declare this option at all). Silently nerfing a player's
        -- weapon because we could not read the server's config is worse than leaving it
        -- alone, so an unreadable sandbox means NO debuff. The asymmetry is the point.
        juggernautAuraMultiplier = (100 - math.max(0, math.min(100,
            tonumber(sv and sv.JuggernautAuraMultiplier) or 0))) / 100.0,

        -- Reach (tiles) of the weapon debuff while holding a FIREARM near a
        -- Juggernaut, Boss, or enraged Scavenger -- the kiting counter
        -- (RQSuppress "aura"/"ranged" source). Firearms out-range the 3-tile
        -- melee aura by nature, so gating their debuff on that ring made it
        -- free to step out and shoot; this radius is the honest engagement
        -- band for ranged play. 0 disables the band (old behavior). If the
        -- sandbox is unreadable the default still applies, but the aura
        -- multiplier above fail-safes to 1.0 in that case, so the band
        -- composes to a no-op -- same asymmetry, one gate.
        rangedProtectRadius    = math.max(0, math.min(50,
            tonumber(sv and sv.RangedProtectRadius) or 15)),

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

        -- Screamer screen effect strengths (0-1 scale; sandbox exposes as 0-100 integer)
        screamerBlurStrength   = math.max(0, math.min(100, tonumber(sv and sv.ScreamerBlurStrength) or 100)) / 100.0,
        screamerDarkStrength   = math.max(0, math.min(100, tonumber(sv and sv.ScreamerDarkStrength) or 100)) / 100.0,

        -- Scream loudness, same 0-1 scale. Purely the audio gain: 0 mutes the
        -- howl and changes nothing else, so the cast bar, ring, disorientation
        -- and the zombie-attracting world sound all still fire. Client-side
        -- knob by nature (each client scales its own playback), but it sits in
        -- sandbox so a server can hold the whole lobby to one volume.
        screamerVolume         = pct(sv and sv.ScreamerVolume, 100) / 100.0,
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

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
