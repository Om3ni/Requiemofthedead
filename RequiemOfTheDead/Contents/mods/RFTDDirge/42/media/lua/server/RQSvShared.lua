-- SPDX-License-Identifier: GPL-3.0-or-later
if not isServer() then return end

require "RDZombieId"
require "RQChargeLevy"
require "RQZombieCache"

RQSvShared = RQSvShared or {}

-- ========================
-- Constants
-- ========================

-- Single source in RQCommon (was a drifting duplicate of the client's copy).
local HEALTH_MULTIPLIER = RQCommon.HEALTH_MULTIPLIER

local JUGGERNAUT_MIN_BASE_HEALTH = RQCommon.JUGGERNAUT_MIN_BASE_HEALTH

local COLORS = {
    Screamer   = { r = 0.6, g = 0.0,  b = 1.0,  a = 1.0 },  -- Purple
    Juggernaut = { r = 0.1, g = 0.4,  b = 1.0,  a = 1.0 },  -- Blue
    EMP        = { r = 0.2, g = 0.95, b = 0.7,  a = 1.0 },  -- Electric teal
    Glutton    = { r = 0.1, g = 1.0,  b = 0.2,  a = 1.0 },  -- Green
    Scavenger  = { r = 0.1, g = 1.0,  b = 0.2,  a = 1.0 },  -- Green (passive)
    Boss       = { r = 1.0, g = 0.84, b = 0.0,  a = 1.0 },  -- Gold
}

-- Staff gate: RDAccess tier model (RFTDCore adoption). The old four-level
-- access allowlist (admin/moderator/overseer/gm) is retired. Who may
-- convert/inspect is a SANDBOX POLICY (RFTDDirge.ConvertAccess): 1 = Admin
-- only (shipped default - conversion is a lot of power), 2 = all staff (any
-- role holding a capability). Read live so a mid-session sandbox change
-- takes effect without a restart.
function RQSvShared.svIsAdminPlayer(player)
    -- SandboxVars can be nil at load time
    local tier = SandboxVars and SandboxVars.RFTDDirge and SandboxVars.RFTDDirge.ConvertAccess
    return RDAccess.meetsTier(player, tier)
end

local SCREAMER_SPAWN_RADIUS = 8
-- How close a player must be before a Boss will consider casting. Raised from
-- 20 to 25 on 2026-08-24 (owner): a Boss that only reacts inside 20 tiles is
-- comfortably out-ranged by any firearm, so the encounter reads as target
-- practice until the player chooses to close. This is the Boss's awareness for
-- SKILLS only - RQBloodhound has no range limit of its own and never did; it
-- acquires on any ranged hit at any distance.
local BOSS_TRIGGER_RANGE    = 25
local BOSS_SKILLS           = { "Scream", "EMPulse" }  -- coin-flip pool. The Boss's protective aura is not a skill; RQBulwark reads it at hit time.
local BOSS_SKILL_LABELS     = {
    Scream   = "Screaming...",
    EMPulse  = "EMP Charging...",
    Buff     = "Buffing...",
}

local SCAV_CORPSE_RADIUS  = 8

-- expose constants for other modules
RQSvShared.HEALTH_MULTIPLIER          = HEALTH_MULTIPLIER
RQSvShared.JUGGERNAUT_MIN_BASE_HEALTH = JUGGERNAUT_MIN_BASE_HEALTH
RQSvShared.COLORS                     = COLORS
RQSvShared.SCREAMER_SPAWN_RADIUS      = SCREAMER_SPAWN_RADIUS
RQSvShared.BOSS_TRIGGER_RANGE         = BOSS_TRIGGER_RANGE
RQSvShared.BOSS_SKILLS                = BOSS_SKILLS
RQSvShared.BOSS_SKILL_LABELS          = BOSS_SKILL_LABELS
RQSvShared.SCAV_CORPSE_RADIUS         = SCAV_CORPSE_RADIUS

-- ========================
-- Pending queues (RQServer.lua resets these on game start)
-- ========================

RQSvShared.svPending        = {}
RQSvShared.svPendingSummons = {}

-- ========================
-- Config arrays (enum index -> actual value)
-- Single source in RQCommon.ENUMS - these are aliases, not copies. The old
-- duplicated tables had drifted against the client's (DEVOUR_TIME idx 1 was
-- 15 here, 10 there); one table now serves both sides.
-- ========================

local E = RQCommon.ENUMS
local SE_SCREAMER_INTERVAL  = E.SCREAMER_INTERVAL   -- default idx=4 -> 60s
local SE_SCREAMER_CAST      = E.SCREAMER_CAST
local SE_SCREAMER_RANGE     = E.SCREAMER_RANGE
local SE_SCREAMER_SOUND     = E.SCREAMER_SOUND
local SE_SCREAMER_SPAWN_MIN = E.SCREAMER_SPAWN_MIN
local SE_SCREAMER_SPAWN_MAX = E.SCREAMER_SPAWN_MAX
local SE_SCREAMER_THRESHOLD = E.SCREAMER_THRESHOLD
local SE_JUGG_RADIUS        = E.JUGG_RADIUS
local SE_EMP_RANGE          = E.EMP_RANGE
local SE_EMP_CAST           = E.EMP_CAST
local SE_EMP_RADIUS         = E.EMP_RADIUS
local SE_EMP_DRAIN          = E.EMP_DRAIN
local SE_GLUTTON_RADIUS     = E.GLUTTON_RADIUS
local SE_GLUTTON_MULT       = E.GLUTTON_MULT
local SE_BOSS_COOLDOWN      = E.BOSS_COOLDOWN
local SE_CAST_4             = E.CAST_4

local sev  = RQCommon.ev
local spct = RQCommon.pct

local svConfig = nil

local function getSvConfig()
    if svConfig then return svConfig end
    local sv = SandboxVars and SandboxVars.RFTDDirge

    local screamMin = sev(SE_SCREAMER_SPAWN_MIN, sv and sv.ScreamerSpawnMin, 1)
    local screamMax = sev(SE_SCREAMER_SPAWN_MAX, sv and sv.ScreamerSpawnMax, 3)
    svConfig = {
        enabled              = not (sv and sv.Enabled == false),
        debugMode            = (sv and sv.DebugMode == true),
        -- Raw percent, 1% steps (0-100). 0 = no zombie ever converts, 100 =
        -- every one does; the roll is ZombRand(100) >= spawnChance.
        spawnChance          = spct(sv and sv.SpawnChance, 10),

        -- Per-type spacing (integer sandbox options, 0-150 tiles).
        -- Each type only checks distance against OTHER zombies of the
        -- same type. 0 disables the check entirely for that type.
        screamerSpacing      = tonumber(sv and sv.ScreamerSpacing)   or 150,
        juggernautSpacing    = tonumber(sv and sv.JuggernautSpacing) or 150,
        empSpacing           = tonumber(sv and sv.EMPSpacing)        or 150,
        gluttonSpacing       = tonumber(sv and sv.GluttonSpacing)    or 150,
        scavengerSpacing     = tonumber(sv and sv.ScavengerSpacing)  or 150,

        -- Per-type enable
        screamerEnabled      = not (sv and sv.ScreamerEnabled   == false),
        juggernautEnabled    = not (sv and sv.JuggernautEnabled == false),
        empEnabled           = not (sv and sv.EMPEnabled        == false),
        gluttonEnabled       = not (sv and sv.GluttonEnabled    == false),
        scavengerEnabled     = not (sv and sv.ScavengerEnabled  == false),

        -- Screamer
        screamerRepeatInterval = sev(SE_SCREAMER_INTERVAL, sv and sv.ScreamerRepeatInterval, 4) * 1000,
        screamerCastTime       = sev(SE_SCREAMER_CAST,     sv and sv.ScreamerCastTime,     3) * 1000,
        screamerTriggerRange   = sev(SE_SCREAMER_RANGE,    sv and sv.ScreamerTriggerRange,  3),
        screamerSoundRadius    = sev(SE_SCREAMER_SOUND,    sv and sv.ScreamerSoundRadius,   3),
        screamerSpawnMin       = screamMin,
        screamerSpawnMax       = math.max(screamMin, screamMax),
        screamerSpawnThreshold = sev(SE_SCREAMER_THRESHOLD, sv and sv.ScreamerSpawnThreshold, 2),

        -- Juggernaut
        juggernautHealthMultiplier = math.max(1, math.min(50,
            tonumber(sv and sv.JuggernautHealthMultiplier) or HEALTH_MULTIPLIER.Juggernaut)),
        juggernautBuffRadius  = sev(SE_JUGG_RADIUS, sv and sv.JuggernautBuffRadius,  3),

        -- EMP
        empTriggerRange  = sev(SE_EMP_RANGE,   sv and sv.EMPTriggerRange,  3),
        empCastTime      = sev(SE_EMP_CAST,    sv and sv.EMPCastTime,      3) * 1000,
        empRadius        = sev(SE_EMP_RADIUS,  sv and sv.EMPRadius,        3),
        empBatteryDrain  = sev(SE_EMP_DRAIN,   sv and sv.EMPBatteryDrain,  2),

        -- Glutton / Scavenger (devourTime shared)
        gluttonRadius  = sev(SE_GLUTTON_RADIUS, sv and sv.GluttonRadius,  7),
        gluttonMaxMult = sev(SE_GLUTTON_MULT,   sv and sv.GluttonMaxMult, 3),
        devourTime     = sev(E.DEVOUR_TIME, sv and sv.DevourTime, 1) * 1000,

        -- Boss
        bossCastTime      = sev(SE_CAST_4,        sv and sv.BossCastTime,      3) * 1000,
        bossSkillCooldown = sev(SE_BOSS_COOLDOWN, sv and sv.BossSkillCooldown, 3) * 1000,

        -- Per-type spawn weights, raw percent (0-100, 1% steps). 0 takes the
        -- type out of the lottery exactly like its Enabled toggle would.
        screamerWeight    = spct(sv and sv.ScreamerWeight,    5),
        juggernautWeight  = spct(sv and sv.JuggernautWeight,  15),
        empWeight         = spct(sv and sv.EMPWeight,         20),
        gluttonWeight     = spct(sv and sv.GluttonWeight,     30),
        scavengerWeight   = spct(sv and sv.ScavengerWeight,   5),
    }

    -- The operator's DebugMode drives RQDirgeLog's master switch. The switch
    -- ships false so a release server is quiet, and until 2026-08-24 nothing
    -- ever flipped it - every debug-gated diagnostic, the Slice 1 hit probe
    -- included, called write() into a no-op even with DebugMode on. A whole
    -- Mosaic session produced zero [Dirge:*] lines before that was noticed.
    -- Wired here because this is the one place the server reads the sandbox
    -- flag; the cache clears on the refresh interval, so a live flip
    -- propagates without a restart.
    RQDirgeLog.ENABLED = svConfig.debugMode

    return svConfig
end

RQSvShared.getSvConfig = getSvConfig

-- lets RQServer reset the cached config on game start / sandbox refresh
function RQSvShared.clearSvConfig()
    svConfig = nil
end

-- ========================
-- Health helpers
-- ========================

local function svGetHealthMultiplier(cfg, zType)
    if zType == "Juggernaut" then
        return cfg.juggernautHealthMultiplier or HEALTH_MULTIPLIER.Juggernaut
    end
    return HEALTH_MULTIPLIER[zType]
end

-- PZ MP uses client-authoritative zombie ownership: the client that "owns"
-- a zombie (via NetworkZombieManager) sends sync packets every ~2s, and the
-- server's NetworkZombiePacker.applyZombie calls setHealth from the packet's
-- cached value. So pure server-side setHealth gets clobbered on the next
-- inbound client sync. The fix is to broadcast a command and let the owning
-- client call setHealth authoritatively. We still set HP server-side here
-- for immediate read consistency (snapshot builder, other tick code), but
-- the persistent value comes from the client owner's round-trip sync.
--
-- Engine network HP cap: ZombiePacket.health is a `short` (16-bit signed,
-- max 32767) and NetworkZombieAI packs it as `(short)(zombie.health * 1000)`.
-- Any HP above 32.767 overflows the cast and wraps to a negative value on
-- the next sync, which the engine treats as death (zombie drops dead from
-- a single light hit because its true HP is already negative). We clamp
-- well below the hard ceiling to leave float-precision margin and keep
-- damage subtraction from racing the cap.
local MAX_NETWORK_HP = 30.0

-- ownerOnly: send to the zombie's owning client instead of broadcasting.
-- Only the owner's setHealth survives anyway -- every other client's write is
-- overwritten by the owner's next NetworkZombieManager sync -- so broadcasting
-- to N clients spends N-1 packets on writes that are immediately clobbered.
-- That was affordable once at conversion; it was NOT affordable from the buff
-- auras, which called this once per zombie in radius every 2s. Those auras are
-- gone (RQBulwark answers per hit instead), which is why that cost argument
-- reads in the past tense now - the remaining callers are conversion and
-- McCoy's per-injured-special cadence.
--
-- Returns true when the value reached an authority (the owning client, or the
-- server itself when it owns the zombie), false when we could not place it. A
-- caller that latches a one-shot result must check it. This used to point at
-- "the buffed[] guards in RQSvJuggernaut / RQSvScavenger / RQSvBoss" as the
-- example; all three latches were deleted on 2026-08-24 and all three files
-- carry tombstones, so the pointer was sending readers after code that is not
-- there. There is no latching caller left today.
local function svSetZombieHP(zombie, targetHP, ownerOnly)
    if not zombie or targetHP == nil then return false end
    if targetHP > MAX_NETWORK_HP then
        print(string.format("[Dirge:HP] clamping targetHP=%.2f to %.1f (PZ network short overflows above ~32.7)",
            targetHP, MAX_NETWORK_HP))
        targetHP = MAX_NETWORK_HP
    end
    if targetHP < 0 then targetHP = 0 end
    zombie:setHealth(targetHP)
    -- `oid < 0` here until 2026-08-25. onlineId is a short and wraps negative,
    -- so that test silently refused delivery to about half the population on a
    -- long-running server. RDZombieId carries the decompile evidence.
    local oid = RDZombieId.of(zombie)
    if not oid then return false end

    -- x/y/z came off this payload 2026-08-25 (owner-approved wire change):
    -- the client resolves by id through RQZombieCache and never read them.
    -- Both mod halves ship atomically, so no live client still expects them.
    local payload = {
        onlineID = oid,
        targetHP = targetHP,
    }

    if ownerOnly then
        -- The owner read is nullable by design: no owner means this server already
        -- owns the zombie, so its direct setHealth above is authoritative. Do not
        -- broadcast in that case or the saved network traffic is undone.
        -- IsoZombie.java:453-456.
        local owner = zombie:getOwnerPlayer()
        if owner then
            sendServerCommand(owner, RQCommon.MODULE, "applyZombieHP", payload)
        end
        return true
    end

    sendServerCommand(RQCommon.MODULE, "applyZombieHP", payload)
    return true
end

local function svApplyTypeHealth(zombie, cfg, zType, sourceHealth)
    if not zombie or zombie:getHealth() <= 0 then return end

    local mult = svGetHealthMultiplier(cfg, zType)
    if not mult or mult <= 1 then return end

    local baseHealth = sourceHealth or zombie:getHealth()
    if zType == "Juggernaut" then
        baseHealth = math.max(baseHealth, JUGGERNAUT_MIN_BASE_HEALTH)
    end
    -- RQBaseHP: the PRE-conversion health, stamped here because this is the one
    -- place that still knows it. Everything downstream that needs to ask "how
    -- healthy is this special supposed to be" derives it as base * multiplier
    -- rather than storing the answer - see RQCeiling.
    --
    -- The two older keys are not this. RQJuggMaxHP and RQGluttonBaseHealth are
    -- both stamped AFTER conversion, so they hold base * multiplier already.
    -- They stay, they are still written, and RQCeiling still reads them as a
    -- fallback for zombies converted before this field existed; removing them in
    -- the same slice that introduces the replacement would strand every special
    -- in every existing save.
    zombie:getModData()["RQBaseHP"] = baseHealth
    -- Deliberately NOT ownerOnly. This fires once, when a zombie becomes a
    -- special, and nothing recomputes it afterwards -- so it gets the belt-and-
    -- braces broadcast. The hot repeating callers (McCoy's heal cadence, the
    -- Scavenger's rage decay) are the ones that pass ownerOnly.
    svSetZombieHP(zombie, baseHealth * mult)
end

RQSvShared.svGetHealthMultiplier = svGetHealthMultiplier
RQSvShared.svApplyTypeHealth     = svApplyTypeHealth
RQSvShared.svSetZombieHP         = svSetZombieHP
-- Exported so anything persisting HP (RQSvDormant) clamps with the SAME
-- constant the network path enforces, instead of a drifting copy.
RQSvShared.MAX_NETWORK_HP        = MAX_NETWORK_HP

-- ---------------------------------------------------------------------------
-- Movement profile
-- ---------------------------------------------------------------------------
-- CORRECTED 2026-08-24, and the correction is a live behaviour change the owner
-- authorised: Bosses were almost certainly never sprinting.
--
-- The recipe here used to be setWalkType("Run") + setVariable("bSprinter", true)
-- + setVariable("MovementSpeed", 1.2) + resetModelNextFrame(). Only the last of
-- those does anything in 42.20.3:
--
--   * "Run" is not a walk type. The engine's vocabulary is slow1-3 and
--     sprint1-5 - see the zombiewalktype animation variable and its own
--     description at IsoZombie.java:794, and the engine writing them itself at
--     :4807-4814. getSpeedTypeFromWalkType falls through to 2 for anything it
--     does not recognise (:3211-3222), and NetworkVariables.WalkType.fromString
--     returns WT1 for an unknown string - so remote clients were being told the
--     Boss walks normally.
--   * Neither "bSprinter" nor "MovementSpeed" appears anywhere in the decompile.
--
-- doZombieSpeed(1) is NOT the fix either: doZombieSpeedInternal routes to
-- doFakeShambler whenever Rand.Next(3) ~= 0, and to doShambler outright on a
-- Shamblers server (:4726-4738), so it sprints about one call in three.
--
-- What the engine actually does for a sprinter, in doSprinter and
-- doZombieSpeedInternal2 (:4748-4757, :4804-4816): a randomised sprint1-5 walk
-- type, speedType 1, turnDelta 1.0, and a speedMod of 0.85 plus a small jitter.
-- setSpeedType does not exist on the Lua surface, so speedType is reached the
-- only way available - by deriving it from the walk type.
local SPRINT_SPEED_MOD  = 0.85
local SPRINT_TURN_DELTA = 1.0

-- THE ONE DELIVERY PATH FOR EVERY MOVEMENT WRITE, and the reason it exists.
--
-- A server-side movement write on a client-owned zombie DOES NOT SURVIVE.
-- NetworkZombiePacker.applyZombie (:215-252) runs on every inbound sync from
-- the owning client and unconditionally re-applies that client's values:
--
--     zombie.setSpeedMod(packet.speedMod / 1000f);
--     zombie.setWalkType(packet.walkType.toString());
--     zombie.setSpeedTypeFromWalkType();
--
-- The client's model of a Juggernaut does not include "sprinter", so its next
-- packet stamps the shamble straight back over us. Proven in the 2026-08-24
-- Mosaic session: Bloodhound logged `sprint=true` while the owner watched the
-- zombie walk, on a run where the hit probe reported owner=client for 90 of 90
-- hits. Client ownership is the NORM for anything a player is shooting, not an
-- edge case.
--
-- So the write is delivered the way health already is (svSetZombieHP's
-- ownerOnly branch): write locally for the server-owned case, and hand the
-- owning client the same values so ITS next outgoing packet carries them.
-- ZombiePacket.java:222 builds walkType from the zombie's live state, which is
-- exactly what makes that work.
--
-- Nothing else may call setWalkType/setSpeedMod/setTurnDelta on a zombie. A
-- direct write is a write that silently disappears a second later.
local function svDeliverMovement(zombie, walkType, speedMod, turnDelta)
    if not zombie or not walkType then return false end
    zombie:setWalkType(walkType)
    zombie:setSpeedTypeFromWalkType()
    zombie:setSpeedMod(speedMod)
    zombie:setTurnDelta(turnDelta)
    zombie:resetModelNextFrame()

    -- `oid < 0` here until 2026-08-25. onlineId is a short and wraps negative,
    -- so that test silently refused delivery to about half the population on a
    -- long-running server. RDZombieId carries the decompile evidence.
    local oid = RDZombieId.of(zombie)
    if not oid then return false end

    -- Nullable BY DESIGN: no owner means this server already owns the zombie,
    -- so the direct write above is authoritative and a packet would be waste.
    -- IsoZombie.java:454-456.
    local owner = zombie:getOwnerPlayer()
    if not owner then return true end

    -- The raw global, not the sendToPlayer wrapper: that local is declared
    -- further down this file, so a reference here would compile to a GLOBAL
    -- lookup and be nil at call time. svSetZombieHP above calls the global
    -- directly for the same reason.
    -- x/y/z came off this payload 2026-08-25, same reason as svSetZombieHP's.
    sendServerCommand(owner, RQCommon.MODULE, "applyZombieMovement", {
        onlineID  = oid,
        walkType  = walkType,
        speedMod  = speedMod,
        turnDelta = turnDelta,
    })
    return true
end
RQSvShared.svDeliverMovement = svDeliverMovement

local function applySprintProfile(zombie)
    if not zombie then return false end
    -- sprint1-5 are animation variants, not speed tiers; the engine picks one at
    -- random and so do we. All five are real NetworkVariables.WalkType values
    -- (WTSprint1-5), so they survive the wire intact - unlike the "Run" the
    -- pre-Bulwark code used, which fromString mapped to WT1.
    return svDeliverMovement(zombie,
        "sprint" .. tostring(ZombRand(5) + 1),
        SPRINT_SPEED_MOD + ZombRand(1500) / 10000.0,
        SPRINT_TURN_DELTA)
end
RQSvShared.applySprintProfile = applySprintProfile

-- Everything restoreMovementProfile needs to put a zombie back exactly as it
-- was. Taken ONCE per pursuit - re-snapshotting a zombie that is already
-- sprinting would record the sprint as its native state and strand it there.
local function captureMovementProfile(zombie)
    if not zombie then return nil end
    return {
        walkType  = zombie:getWalkType(),
        speedType = zombie:getSpeedType(),
        speedMod  = zombie:getSpeedMod(),
        turnDelta = zombie:getTurnDelta(),
    }
end
RQSvShared.captureMovementProfile = captureMovementProfile

-- speedType is restored by re-deriving it from the restored walk type rather
-- than written back directly, because there is no setSpeedType on the Lua
-- surface. For every walk type the engine itself produces the two agree by
-- construction; the captured speedType is kept in the snapshot anyway so a
-- disagreement is visible to a caller that wants to check.
local function restoreMovementProfile(zombie, snap)
    if not zombie or not snap then return false end
    -- Through svDeliverMovement for the same reason the sprint is: a restore
    -- that only lands server-side would be reverted by the owning client's next
    -- packet just like the sprint was, and a zombie left sprinting forever is
    -- the failure this whole restore path exists to prevent.
    return svDeliverMovement(zombie, snap.walkType, snap.speedMod, snap.turnDelta)
end
RQSvShared.restoreMovementProfile = restoreMovementProfile

-- The Boss is a PERMANENT sprinter - it is applied at conversion and on reload
-- and nothing restores it. Bloodhound must therefore never put a Boss back to a
-- slower profile at the end of a pursuit.
local function applyBossSprinter(zombie)
    applySprintProfile(zombie)
end
RQSvShared.applyBossSprinter = applyBossSprinter

-- ---------------------------------------------------------------------------
-- Zone-risk sprinters (S8 of the Limes redesign)
-- ---------------------------------------------------------------------------
-- The zone dial: `sprinterShare` arrives on the per-zone cfg overlay - the
-- same getEffectiveRules flip that already carries the weights and spacings -
-- so Dirge stays free of any Limes dependency. The base config deliberately
-- has NO such key: without a zone layer the share reads nil, coerces to 0,
-- and the mechanic is inert. The global dial, when someone wants one, is the
-- zone layer's own _default record, not a sandbox option.
--
-- THE CONTRACT, chosen for predictability over cleverness:
--   * A zombie rolls ONCE, the first time it is scanned standing on ground
--     whose share is above zero. Win -> a permanent sprinter (for its loaded
--     lifetime); lose -> a walker for the same span.
--   * Ground with no share burns nothing, so a walker that wanders INTO a
--     risk zone still rolls there. A loser never re-rolls, even if the share
--     is raised - population churn is what turns a dial change into streets
--     that feel different (verdicts live in modData, which dies at
--     virtualization - see the RQRolled commentary in RQServer - so churn is
--     measured in chunk reloads, not server restarts).
--   * Specials are excluded on both sides: a converted zombie never rolls
--     (Juggernauts do not sprint), and the roll waits until the special
--     lottery has settled as a LOSS (RQRolled burned, nothing parked) so one
--     zombie can never win both in the same visit and leave a sprint profile
--     on a type that owns its own movement.
--
-- The re-apply branch is the same self-heal svDeliverMovement's commentary
-- demands: the owning client's zombie packets re-stamp movement continuously,
-- and an ownership handoff can put a walk back on a committed sprinter. Read
-- the live walk type and re-deliver only when it has reverted - sprint1-5 are
-- the engine's own sprint vocabulary (IsoZombie.java:4807-4814), so a
-- "sprint" prefix is the exact test, not a heuristic.
local function svCheckZoneSprinter(zombie, md)
    if md["RQConverted"] then return end
    if md["RQSprinter"] then
        local wt = zombie:getWalkType()
        if not wt or wt:sub(1, 6) ~= "sprint" then
            applySprintProfile(zombie)
        end
        return
    end
    if md["RQSprintRolled"] then return end
    if not md["RQRolled"] or md["RQPendingType"] then return end
    local cfg = getSvConfig()
    if not cfg.enabled then return end
    cfg = RQPhunZones.getEffectiveRules(zombie, nil, cfg)
    local share = tonumber(cfg.sprinterShare) or 0
    if share <= 0 then return end
    md["RQSprintRolled"] = true
    if ZombRand(100) >= share then return end
    md["RQSprinter"] = true
    applySprintProfile(zombie)
    if cfg.debugMode then
        RQDirgeLog.write("Sprint", string.format(
            "[INFO] zone sprinter minted at %d,%d share=%d",
            math.floor(zombie:getX()), math.floor(zombie:getY()),
            math.floor(share)))
    end
end
RQSvShared.svCheckZoneSprinter = svCheckZoneSprinter

-- ========================
-- Common utility functions
-- ========================

local function broadcast(cmd, args)
    sendServerCommand(RQCommon.MODULE, cmd, args)
end

local function sendToPlayer(player, cmd, args)
    sendServerCommand(player, RQCommon.MODULE, cmd, args)
end

-- ---------------------------------------------------------------------------
-- Cadence gate
-- ---------------------------------------------------------------------------
-- Returns true when `key` is due, stamping the next deadline as a side effect.
-- `state` is any table the caller already owns (a per-zombie state row, or a
-- module-level pass table); `now` is a getTimestampMs() value the caller has
-- already read, so one tick's worth of work shares one clock read.
--
-- WALL CLOCK, NOT TICK COUNTS, and that distinction is the point. The
-- Juggernaut aura used to gate on `svJuggBuffTick >= 120` while RQSvBoss gated
-- on getTimestampMs against a 2000 ms interval - two spellings of "every ~2
-- seconds" that agree only while the server is holding 60 Hz. OnTick sags
-- under load, so the tick-count version silently stretched exactly when the
-- server was busiest, and the two auras drifted apart from each other. Every
-- cadence in this mod reads the same clock now.
--
-- A first call (no stamp yet) is always due, so a fresh state row acts
-- immediately instead of waiting out one interval before it does anything.
local function due(state, key, intervalMs, now)
    if not state then return true end
    local last = state[key]
    if last and (now - last) < intervalMs then return false end
    state[key] = now
    return true
end

-- writes to RQSvShared.svPending so RQServer.lua can drain it in OnTick
local function scheduleAction(delayMs, fn)
    local q = RQSvShared.svPending
    q[#q + 1] = { due = getTimestampMs() + delayMs, fn = fn }
end

-- invisible or ghost admins shouldn't trigger zombie behaviors
local function isPlayerVisible(p)
    if p:isInvisible() or p:isGhostMode() then return false end
    return true
end

local function isAnyPlayerInRange(zombie, range)
    local zx, zy = zombie:getX(), zombie:getY()
    local rangeSq = range * range
    local players = getOnlinePlayers()
    if players and players:size() > 0 then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p and isPlayerVisible(p) then
                local dx = p:getX() - zx
                local dy = p:getY() - zy
                if dx * dx + dy * dy <= rangeSq then return true end
            end
        end
        return false
    end
    local p = getPlayer()
    if p and isPlayerVisible(p) then
        local dx = p:getX() - zx
        local dy = p:getY() - zy
        return dx * dx + dy * dy <= rangeSq
    end
    return false
end

-- build castStart parameter package
local function makeCastArgs(ringId, x, y, z, duration, col, label, ringRadius, onlineID)
    return {
        ringId     = ringId,
        fixedX     = x + 0.5,
        fixedY     = y + 0.5,
        fixedZ     = z,
        duration   = duration,
        rR         = col.r,
        rG         = col.g,
        rB         = col.b,
        rA         = col.a,
        label      = label,
        ringRadius = ringRadius or 0,
        onlineID   = onlineID,
    }
end

local function svCountNearbyAliveZombies(x, y, z, radius, ignoreZombie)
    local cell = getCell()
    if not cell then return 0 end

    local nearbyCount = 0
    local rSq = radius * radius
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= rSq then
                local sq = cell:getGridSquare(x + dx, y + dy, z)
                if sq then
                    local movs = sq:getMovingObjects()
                    if movs then
                        for mi = 0, movs:size() - 1 do
                            local obj = movs:get(mi)
                            if obj and obj ~= ignoreZombie and instanceof(obj, "IsoZombie") and not obj:isDead() then
                                nearbyCount = nearbyCount + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return nearbyCount
end

-- TWO LANES, split 2026-08-25, because they were never one question.
--
-- AN ID NAMES A ZOMBIE; COORDINATES SELECT ONE. The old body answered both
-- with a box sweep from whatever coordinates arrived, which made the id lane
-- only as good as the position sent beside it: a zombie that had wandered
-- past the box was a MISS, and - worse - an id of -1 (multiple unassigned
-- zombies can carry it at once) would have returned whichever -1 body the
-- walk met first. The id lane now goes through RQZombieCache, the same
-- id-keyed map the client adopted, promoted to shared for exactly this
-- caller; x/y/z and radius are IGNORED there, and RDZombieId owns validity
-- so -1 is a miss, never a wrong body.
--
-- The coordinate lane (onlineID nil, 0, or -1) is inherently spatial and
-- keeps its sweep: it is the context-menu convert's "the thing I am pointing
-- at" affordance, whose reach hAdminConvert anchors to 48 tiles of the
-- caller. onlineID == 0 stays meaningful for that path (a zombie the engine
-- has not networked yet reports 0 client-side).
-- WHICH LANE AN ID TAKES, exported so a CALLER'S GATE CANNOT DRIFT FROM THE
-- RESOLVER'S CHOICE. That drift was a real authority bug, found in review the
-- same day the lanes were split (2026-08-25): hAdminConvert anchored its
-- 48-tile proximity check on `onlineID == 0`, the only coordinate-selected
-- value the OLD resolver had - while this rewrite widened the coordinate lane
-- to nil, 0 and -1. A staff-tier caller could send onlineID = -1 with any
-- loaded coordinates and convert the nearest ordinary zombie there, entirely
-- outside the anchor. The lesson is not "add -1 to the gate": it is that a
-- second copy of this test is what allowed the two to disagree at all.
function RQSvShared.usesCoordinateLane(onlineID)
    return not (RDZombieId.isValid(onlineID) and onlineID ~= 0)
end

local function svFindZombieByOnlineID(onlineID, x, y, z, radius)
    if not RQSvShared.usesCoordinateLane(onlineID) then
        local zombie = RQZombieCache.get(onlineID)
        -- No positional fallback on an id miss: the id names a zombie, and
        -- "some other zombie near the point" is the wrong-body hazard the
        -- 2026-08-19 certainty work exists to prevent. A miss means it is
        -- not loaded (or just dead), and every caller already handles nil.
        return zombie
    end

    local cell = getCell()
    if not cell then return nil end

    local searchRadius = radius or 5
    local bestObj   = nil
    local bestDistSq = searchRadius * searchRadius + 1

    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local movs = sq:getMovingObjects()
                if movs then
                    for i = 0, movs:size() - 1 do
                        local obj = movs:get(i)
                        if obj and instanceof(obj, "IsoZombie") and not obj:isDead() then
                            -- nearest zombie to the named point
                            local ddx = obj:getX() - x
                            local ddy = obj:getY() - y
                            local dSq = ddx*ddx + ddy*ddy
                            if dSq < bestDistSq then
                                bestDistSq = dSq
                                bestObj = obj
                            end
                        end
                    end
                end
            end
        end
    end

    return bestObj
end

-- _activeZombies gets injected by RQServer.lua after it creates the table
local _activeZombies = nil

function RQSvShared.setActiveZombies(tbl)
    _activeZombies = tbl
end

-- READ-ONLY WINDOW onto the live special-infected set, for observers.
--
-- Added for Limes' zone census, which needs to answer "what fraction of this
-- zone's standing population is actually special" - the only empirical check
-- that the per-zone spawn dials are reaching the world rather than merely being
-- stored. Nothing in Dirge needs it.
--
-- A CALLBACK, not the table. svActiveZombies is weak-keyed and four modules
-- share the one reference (RQServer:95-98); handing it out would let any caller
-- hold a strong reference to a zombie the collector is trying to release, or
-- write into a structure Dirge's own bookkeeping depends on. The callback sees
-- each pair and can keep whatever it wants.
--
-- Returns the number of entries visited, so a caller can distinguish "no
-- specials alive" from "Dirge is not tracking anything".
-- A truthy return from `fn` STOPS the walk. Added for RQBulwark's aura lookup,
-- which asks "is anything protecting this target" and has no use for a second
-- answer - without a break it was walking the whole registry to discard every
-- source after the first match. Existing callers return nothing and are
-- unaffected. Returns how many entries were visited, which is the number worth
-- watching when the registry grows.
function RQSvShared.eachActiveZombie(fn)
    if not _activeZombies or type(fn) ~= "function" then return 0 end
    local n = 0
    for zombie, zType in pairs(_activeZombies) do
        n = n + 1
        if fn(zombie, zType) then break end
    end
    return n
end

-- "What kind of special is this, if any?" - the registry first, the zombie's own
-- modData second. The fallback is not belt-and-braces: a special that has been
-- reloaded from a save, or has fallen out of the live registry during cell
-- churn, still carries RQType and is still a special. Returns nil for an
-- ordinary zombie.
function RQSvShared.typeOf(zombie)
    if not zombie then return nil end
    local fromRegistry = _activeZombies and _activeZombies[zombie]
    if fromRegistry then return fromRegistry end
    return zombie:getModData()["RQType"]
end

local function svFindActiveZombieByOnlineID(onlineID)
    if not _activeZombies then return nil, nil end
    for zombie, zType in pairs(_activeZombies) do
        if zombie:getOnlineID() == onlineID then
            return zombie, zType
        end
    end
    return nil, nil
end

-- svRecordSummon uses RQSvShared.svPendingSummons directly so RQServer.lua
-- can reset the table on game start without breaking the reference
local function svRecordSummon(x, y, r)
    local ps = RQSvShared.svPendingSummons
    if ps[51] then
        table.remove(ps, 1)
    end
    ps[#ps + 1] = {
        x = x, y = y, r = r + 20, t = getTimestampMs()
    }
end

-- RQServer.lua installs RQSvShared.onSummonSpawned at load: it marks each
-- newborn's spawn roll consumed in modData (so the positional summon window
-- is only a fallback) and gives it the same one-shot special roll as any
-- organic zombie. addZombiesInOutfit returns ArrayList<IsoZombie>
-- (engine-verified, LuaManager.GlobalObject), which is what makes direct
-- marking possible.
-- onSpawned (optional) replaces the default per-newborn handler. Omit it and
-- newborns get the organic treatment: roll consumed, one random shot at the
-- special funnel. Pass one and you decide what each newborn becomes -- which is
-- what makes a DETERMINISTIC admin spawn possible, since onSummonSpawned would
-- otherwise burn the roll and hand out a random type.
-- Returns the number actually spawned.
local function svDoSpawn(x, y, z, count, onSpawned)
    local r = SCREAMER_SPAWN_RADIUS
    -- Recorded even for admin spawns: it's the fallback that stops the
    -- conversion scan re-rolling these newborns if the returned list is empty.
    svRecordSummon(x, y, r)
    local cell = getCell()
    if not cell then return 0 end
    local handler  = onSpawned or RQSvShared.onSummonSpawned
    local spawned  = 0
    local attempts = 0
    local handlerFailures = 0
    local firstHandlerError = nil
    local rSq = r * r
    while spawned < count and attempts < count * 3 do
        attempts = attempts + 1
        local dx = ZombRand(-r, r + 1)
        local dy = ZombRand(-r, r + 1)
        if dx * dx + dy * dy <= rSq then
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq and not sq:isSolid() then
                -- The Java global returns an empty ArrayList for a missing
                -- square, disabled zombies, or failed allocation. It does not
                -- use exceptions to report an unsuccessful spawn.
                -- LuaManager.java:8343-8345, 8368-8423.
                local added = addZombiesInOutfit(x + dx, y + dy, z, 1, nil, 50)
                local addedCount = added:size()
                spawned = spawned + addedCount
                if handler then
                    for i = 0, addedCount - 1 do
                        local zed = added:get(i)
                        if zed then
                            -- Retained independent-member boundary: a newborn
                            -- handler can mutate conversion state before failing;
                            -- later newborns remain valid work in the summon.
                            local okHandler, handlerError = pcall(handler, zed)
                            if not okHandler then
                                handlerFailures = handlerFailures + 1
                                if not firstHandlerError then firstHandlerError = handlerError end
                            end
                        end
                    end
                end
            end
        end
    end
    if handlerFailures > 0 then
        print("[RFTDDirge] summon newborn handler failed for " .. handlerFailures
            .. " of " .. spawned .. " spawned zombie(s); first error: "
            .. tostring(firstHandlerError))
    end
    return spawned
end

-- ========================
-- EMP helpers - shared because Boss uses EMP blast too
-- ========================

local function svApplyEMPEnduranceDrain(player)
    if not player then return end
    -- 42.20.3: LuaManager.java:1756,1765-1766,2228 exposes Moodles, Stats,
    -- CharacterStat, and MoodleType; IsoGameCharacter.java:3472-3478 returns
    -- initialized moodles/stats; Stats.java:76-84 clamps get/set directly.
    local level = player:getMoodles():getMoodleLevel(MoodleType.ENDURANCE)
    if level < 4 then
        local targets = { 0.65, 0.40, 0.18, 0.05 }
        local target  = targets[level + 1]
        local stats   = player:getStats()
        local current = stats:get(CharacterStat.ENDURANCE)
        if target and target < current then
            stats:set(CharacterStat.ENDURANCE, target)
        end
    end
end

local function svDamageWorldElectronics(x, y, z, radius, drainPercent)
    local cell = getCell()
    if not cell then return end

    local rSq = radius * radius
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= rSq then
                local sq = cell:getGridSquare(x + dx, y + dy, z)
                if sq then
                    local objects = sq:getObjects()
                    if objects then
                        for oi = 0, objects:size() - 1 do
                            local obj = objects:get(oi)
                            if obj and instanceof(obj, "IsoGenerator") then
                                local cond = obj:getCondition()
                                if cond and cond > 0 then
                                    obj:setCondition(math.max(0, cond - math.floor(cond * drainPercent / 100)))
                                end
                            -- NO TV/RADIO BRANCH, and it is not an oversight -
                            -- one stood here until 2026-08-27 and did nothing a
                            -- player could ever perceive.
                            --
                            -- It called dd:setIsTurnedOn(false), which is the
                            -- CORRECT api (IsoWaveSignal.getDeviceData:142 ->
                            -- DeviceData.setIsTurnedOn:455; the turnOff() the
                            -- old client copy called exists on IsoBarbecue:244
                            -- and nowhere else). The api is right and the
                            -- REPLICATION is not: setIsTurnedOn ends in
                            -- transmitDeviceDataState, whose entire body is
                            -- `if (GameClient.client)` (DeviceData.java:932-942).
                            -- This file is `if not isServer() then return end`,
                            -- so that branch is never taken here. The device
                            -- switched off in the server's model and every
                            -- client kept playing it.
                            --
                            -- There is no server-side substitute to reach for.
                            -- Only packet type 0 carries isTurnedOn (:1011-1015),
                            -- transmitDeviceDataStateServer is private (:944),
                            -- and the one server path that emits type 0 is inside
                            -- DeviceData.update at :773-780 - the branch that
                            -- fires when a device can no longer be powered.
                            -- transmitBatteryChangeServer is public but sends
                            -- type 2, which carries hasBattery and powerDelta
                            -- only. setPower does not transmit at all (:572-580),
                            -- so battery devices have no lever either.
                            --
                            -- So the engine hands us exactly one honest way to
                            -- darken a mains device, and we take it: CUT THE
                            -- POWER. A generator damaged to 0 above calls
                            -- setActivated(false) (IsoGenerator.java:205-207),
                            -- its squares stop reporting hasGridPower, and each
                            -- device turns ITSELF off on its next update and
                            -- transmits that server-side. Free, authoritative,
                            -- and no new wire traffic. The blackout trails the
                            -- blast instead of landing with it, which is also
                            -- what a generator dying actually looks like.
                            elseif obj and instanceof(obj, "IsoWindow") then
                                -- The window implementation requires its square
                                -- throughout sound, attachment, path, and polygon
                                -- updates. Skip a pane detached during this scan;
                                -- live windows follow vanilla's direct call.
                                -- IsoWindow.java:275-318.
                                if obj:getSquare() == sq and not obj:isSmashed() then
                                    obj:smashWindow()
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- THE SERVER DOES NOT DAMAGE PLAYERS IN THE BLAST, and it used to - wrongly,
-- twice over (deleted 2026-08-25, owner call). This block cut 10-15% via
-- p:setHealth(), which on a PLAYER writes IsoGameCharacter's protected 0-1
-- field (IsoGameCharacter.java:547, setter :2892-2897) - the zombie/animal
-- scale the health panel NEVER reads. Not harmless: isDead() ORs that field
-- (:4630) and applyDamage() subtracts from it with a floor of 0
-- (:14410-14415, the vehicle-hit path), so an EMP-eroded player could be
-- tipped into a server-side death by an unrelated engine hit later - with an
-- empty wounds panel, the exact "phantom wounds" shape the 2026-08-20 hunt
-- chased. The damage players actually FEEL is the client's inner-zone
-- BodyDamage hit (RQEMP.lua ReduceGeneralHealth(10)), which the panel reads;
-- that lane is the design and is untouched. Residual exposure from the old
-- writes is a session at most: the field constructs at 1.0f (:547) and
-- nothing persists our erosion across a relog.

-- casterID: the onlineID of the zombie that produced this blast, or nil for a
-- sourceless one (the admin command). THE CASTER IS IMMUNE, nothing else is.
-- A Boss stands at its own epicentre - dSq = 0, as deep inside the inner zone
-- as it is possible to be - so without this it knocks itself flat every single
-- EMPulse. Owner decision 2026-08-24: caster-only, because specials shrugging
-- off each other's blasts would read as coordination, and zombies do not
-- coordinate. A Boss flattening a nearby Juggernaut is working as intended.
local function svApplyEMPBlast(x, y, z, radius, drainPercent, casterID)
    local innerSq = (radius * 0.5) * (radius * 0.5)
    local outerSq = radius * radius
    local players = getOnlinePlayers()
    local playersHit = 0
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p then
                local dx = p:getX() - x
                local dy = p:getY() - y
                local dSq = dx * dx + dy * dy
                if dSq <= outerSq then
                    local zone = dSq <= innerSq and "inner" or "outer"
                    -- The server's real effects: endurance drain and battery
                    -- levy. HEALTH damage is the client's, inner zone only,
                    -- through BodyDamage - see the block comment above. The
                    -- log no longer claims hp for outer-zone players who
                    -- never took any; that line lied for the whole hunt.
                    svApplyEMPEnduranceDrain(p)
                    local itemsHit = RQChargeLevy.drain(p, drainPercent)
                    sendToPlayer(p, "empDebuff", {
                        x      = x,
                        y      = y,
                        radius = radius,
                        drain  = drainPercent,
                    })
                    playersHit = playersHit + 1
                    RQDirgeLog.write("EMP", "[INFO] blast hit player zone=" .. zone
                        .. " (hp damage is client-side, inner zone only)"
                        .. " drain=" .. tostring(drainPercent) .. "%"
                        .. " itemsHit=" .. itemsHit)
                end
            end
        end
    end
    -- Zombies caught in the blast stumble; inner-zone zeds go down hard
    -- (mirrors the player inner/outer split). Ownership rule: only the side
    -- that OWNS a zombie may drive its state machine. Client-owned zeds are
    -- stumbled by their owning client off the castDone broadcast
    -- (RQEMP.stumbleZombies); we handle only the server-owned remainder.
    --
    -- THE TEST IS getOwnerPlayer(), NOT isRemoteZombie(), and that correction
    -- is the point. This filter used to read `not obj:isRemoteZombie()`, with a
    -- comment claiming that skipped client-owned zeds. It did the exact
    -- opposite. NetworkZombieComponent.java:23 is `isRemote() { return
    -- authOwner == null; }` - so server-side, isRemoteZombie() FALSE means a
    -- client owns it. The old filter kept precisely the zombies it meant to
    -- skip and skipped the only ones the server can actually drive, so
    -- client-owned zeds were stumbled twice (here and again by their owner)
    -- and server-owned zeds never at all. The 2026-08-24 probe caught it:
    -- owner=client with remote=false on 90 of 90 hits.
    --
    -- getOwnerPlayer() is used instead because its meaning does not flip
    -- between sides and it needs no explanation: an owner or nil. It is the
    -- same predicate svSetZombieHP's ownerOnly branch already relies on.
    local zombiesHit = 0
    local cell = getCell()
    if cell then
        local rInt = math.ceil(radius)
        for dx = -rInt, rInt do
            for dy = -rInt, rInt do
                local sq = cell:getGridSquare(x + dx, y + dy, z)
                if sq then
                    local movs = sq:getMovingObjects()
                    if movs then
                        for mi = 0, movs:size() - 1 do
                            local obj = movs:get(mi)
                            if obj and instanceof(obj, "IsoZombie") and not obj:isDead()
                                and not obj:getOwnerPlayer()
                                and not (casterID and obj:getOnlineID() == casterID)
                                and not obj:isReanimatedForGrappleOnly() then
                                local zdx = obj:getX() - x
                                local zdy = obj:getY() - y
                                local zdSq = zdx * zdx + zdy * zdy
                                if zdSq <= outerSq then
                                    -- Unguarded: IsoZombie.knockDown:4094 is six field
                                    -- sets plus reportEvent, which on a zombie is only
                                    -- ActionContext:219 occurredAnimEvents.add (the
                                    -- IsoPlayer branch there is client-local-player only),
                                    -- and getActionContext:1460 reads the
                                    -- StateMachineComponent every IsoGameCharacter
                                    -- registers in its constructor.
                                    if zdSq <= innerSq and not obj:isCrawling() and not obj:isOnFloor() then
                                        obj:knockDown(false)
                                    else
                                        -- Stagger-only: knockDown's flag set minus the
                                        -- knockdown flag, so the anim graph picks plain
                                        -- staggerback instead of staggerback-knockeddown.
                                        obj:setStaggerBack(true)
                                        obj:setHitForce(0.5)
                                        obj:setHitReaction("")
                                        obj:reportEvent("wasHit")
                                    end
                                    zombiesHit = zombiesHit + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    RQDirgeLog.write("EMP", "[INFO] svApplyEMPBlast at (" .. x .. "," .. y .. "," .. z .. ")"
        .. " radius=" .. radius .. " playersHit=" .. playersHit .. " zombiesHit=" .. zombiesHit)
    svDamageWorldElectronics(x, y, z, radius, drainPercent)
end

-- ========================
-- processPending - called by RQServer.lua in its OnTick
-- ========================

function RQSvShared.processPending()
    local q = RQSvShared.svPending
    if not q then RQSvShared.svPending = {}; return end

    local now        = getTimestampMs()
    local newPending = {}
    local newCount   = 0
    for _, entry in ipairs(q) do
        if now >= entry.due then
            entry.fn()
        else
            newCount = newCount + 1
            newPending[newCount] = entry
        end
    end
    RQSvShared.svPending = newPending
end

-- ========================
-- Public API
-- ========================

RQSvShared.broadcast                    = broadcast
RQSvShared.sendToPlayer                 = sendToPlayer
RQSvShared.due                          = due
RQSvShared.scheduleAction               = scheduleAction
RQSvShared.isPlayerVisible              = isPlayerVisible
RQSvShared.isAnyPlayerInRange           = isAnyPlayerInRange
RQSvShared.makeCastArgs                 = makeCastArgs
RQSvShared.svFindZombieByOnlineID       = svFindZombieByOnlineID
RQSvShared.svFindActiveZombieByOnlineID = svFindActiveZombieByOnlineID
RQSvShared.svCountNearbyAliveZombies    = svCountNearbyAliveZombies
RQSvShared.svDoSpawn                    = svDoSpawn
RQSvShared.svApplyEMPEnduranceDrain     = svApplyEMPEnduranceDrain
RQSvShared.svDamageWorldElectronics     = svDamageWorldElectronics
RQSvShared.svApplyEMPBlast              = svApplyEMPBlast

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
