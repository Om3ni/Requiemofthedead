-- SPDX-License-Identifier: GPL-3.0-or-later
if not isServer() then return end

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
    local tier
    pcall(function() tier = SandboxVars.RFTDDirge and SandboxVars.RFTDDirge.ConvertAccess end)
    return RDAccess.meetsTier(player, tier)
end

local SCREAMER_SPAWN_RADIUS = 8
local BOSS_TRIGGER_RANGE    = 20
local BOSS_SKILLS           = { "Scream", "EMPulse" }  -- coin-flip pool. Buff is now a passive aura, see RQSvBoss.svDoBossBuff.
local BOSS_SKILL_LABELS     = {
    Scream   = "Screaming...",
    EMPulse  = "EMP Charging...",
    Buff     = "Buffing...",
}

local DEV_PLAYER_TRIGGER  = 20

local SCAV_FOLLOW_RANGE   = 15
local SCAV_CORPSE_RADIUS  = 8
local EATER_SEEK_TIMEOUT  = 90000   -- owner-client has 90s to path to corpse

-- expose constants for other modules
RQSvShared.HEALTH_MULTIPLIER          = HEALTH_MULTIPLIER
RQSvShared.JUGGERNAUT_MIN_BASE_HEALTH = JUGGERNAUT_MIN_BASE_HEALTH
RQSvShared.COLORS                     = COLORS
RQSvShared.SCREAMER_SPAWN_RADIUS      = SCREAMER_SPAWN_RADIUS
RQSvShared.BOSS_TRIGGER_RANGE         = BOSS_TRIGGER_RANGE
RQSvShared.BOSS_SKILLS                = BOSS_SKILLS
RQSvShared.BOSS_SKILL_LABELS          = BOSS_SKILL_LABELS
RQSvShared.DEV_PLAYER_TRIGGER         = DEV_PLAYER_TRIGGER
RQSvShared.SCAV_FOLLOW_RANGE          = SCAV_FOLLOW_RANGE
RQSvShared.SCAV_CORPSE_RADIUS         = SCAV_CORPSE_RADIUS
RQSvShared.EATER_SEEK_TIMEOUT         = EATER_SEEK_TIMEOUT

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
local SE_JUGG_BUFF          = E.JUGG_BUFF
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
        juggernautBuffPercent = sev(SE_JUGG_BUFF,   sv and sv.JuggernautBuffPercent, 2),
        juggernautMitigation  = math.max(0, math.min(100,
            tonumber(sv and sv.JuggernautMitigation) or 0)),

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
-- That is affordable once at conversion; it is not affordable from the buff
-- auras, which call this ONCE PER ZOMBIE IN RADIUS every 2s.
--
-- Returns true when the value reached an authority (the owning client, or the
-- server itself when it owns the zombie), false when we could not place it.
-- Callers that latch a one-shot result must check this -- see the buffed[]
-- guards in RQSvJuggernaut / RQSvScavenger / RQSvBoss.
local function svSetZombieHP(zombie, targetHP, ownerOnly)
    if not zombie or targetHP == nil then return false end
    if targetHP > MAX_NETWORK_HP then
        print(string.format("[Dirge:HP] clamping targetHP=%.2f to %.1f (PZ network short overflows above ~32.7)",
            targetHP, MAX_NETWORK_HP))
        targetHP = MAX_NETWORK_HP
    end
    if targetHP < 0 then targetHP = 0 end
    pcall(function() zombie:setHealth(targetHP) end)
    local oid = zombie:getOnlineID()
    if not oid or oid < 0 then return false end

    local payload = {
        onlineID = oid,
        targetHP = targetHP,
        x = math.floor(zombie:getX()),
        y = math.floor(zombie:getY()),
        z = math.floor(zombie:getZ()),
    }

    if ownerOnly then
        -- Colon-call inside the pcall: grabbing zombie.getOwnerPlayer as a value
        -- can yield nil and pcall would swallow the "call a nil value" error,
        -- making a missing method look like "no owner" -- the same trap
        -- documented for knockDown further down this file.
        local owner
        local okOwner = pcall(function() owner = zombie:getOwnerPlayer() end)
        if okOwner then
            -- nil owner means the SERVER owns this zombie: the setHealth above
            -- is already authoritative and no packet is needed. Do NOT fall
            -- back to a broadcast here or the saving is undone.
            if owner then
                sendServerCommand(owner, RQCommon.MODULE, "applyZombieHP", payload)
            end
            return true
        end
        -- getOwnerPlayer itself is missing (engine change): fall back to the
        -- old broadcast so behaviour degrades rather than breaks.
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
    -- Deliberately NOT ownerOnly. This fires once, when a zombie becomes a
    -- special, and nothing recomputes it afterwards -- so it gets the belt-and-
    -- braces broadcast. The hot repeating callers (buff auras, regen, decay)
    -- are the ones that pass ownerOnly.
    svSetZombieHP(zombie, baseHealth * mult)
end

RQSvShared.svGetHealthMultiplier = svGetHealthMultiplier
RQSvShared.svApplyTypeHealth     = svApplyTypeHealth
RQSvShared.svSetZombieHP         = svSetZombieHP
-- Exported so anything persisting HP (RQSvDormant) clamps with the SAME
-- constant the network path enforces, instead of a drifting copy.
RQSvShared.MAX_NETWORK_HP        = MAX_NETWORK_HP

-- Boss sprinter recipe. setVariable("bSprinter", true) alone is just a hint
-- to the AI - the zombie keeps shambling unless WalkType and MovementSpeed
-- come along too. resetModelNextFrame is what actually swaps the run animation in.
local function applyBossSprinter(zombie)
    if not zombie then return end
    pcall(function()
        zombie:setWalkType("Run")
        zombie:setVariable("bSprinter", true)
        zombie:setVariable("MovementSpeed", 1.2)
        zombie:resetModelNextFrame()
    end)
end
RQSvShared.applyBossSprinter = applyBossSprinter

-- ========================
-- Common utility functions
-- ========================

local function broadcast(cmd, args)
    sendServerCommand(RQCommon.MODULE, cmd, args)
end

local function sendToPlayer(player, cmd, args)
    sendServerCommand(player, RQCommon.MODULE, cmd, args)
end

-- writes to RQSvShared.svPending so RQServer.lua can drain it in OnTick
local function scheduleAction(delayMs, fn)
    local q = RQSvShared.svPending
    q[#q + 1] = { due = getTimestampMs() + delayMs, fn = fn }
end

-- invisible or ghost admins shouldn't trigger zombie behaviors
local function isPlayerVisible(p)
    local ok1, inv  = pcall(p.isInvisible, p)
    local ok2, gst  = pcall(p.isGhostMode, p)
    if (ok1 and inv) or (ok2 and gst) then return false end
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
    local ok, p = pcall(getPlayer)
    if ok and p and isPlayerVisible(p) then
        local dx = p:getX() - zx
        local dy = p:getY() - zy
        return dx * dx + dy * dy <= rangeSq
    end
    return false
end

-- get all players within range of a world position
local function getPlayersInRange(x, y, range)
    local result = {}
    local rangeSq = range * range
    local players = getOnlinePlayers()
    if players and players:size() > 0 then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p then
                local dx = p:getX() - x
                local dy = p:getY() - y
                if dx * dx + dy * dy <= rangeSq then
                    result[#result + 1] = p
                end
            end
        end
    else
        local ok, p = pcall(getPlayer)
        if ok and p then
            local dx = p:getX() - x
            local dy = p:getY() - y
            if dx * dx + dy * dy <= rangeSq then
                result[1] = p
            end
        end
    end
    return result
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

local function svFindZombieByOnlineID(onlineID, x, y, z, radius)
    local cell = getCell()
    if not cell then return nil end

    local searchRadius = radius or 5
    local bestObj   = nil
    local bestDistSq = searchRadius * searchRadius + 1
    local useID = onlineID and onlineID ~= 0

    for dx = -searchRadius, searchRadius do
        for dy = -searchRadius, searchRadius do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local movs = sq:getMovingObjects()
                if movs then
                    for i = 0, movs:size() - 1 do
                        local obj = movs:get(i)
                        if obj and instanceof(obj, "IsoZombie") and not obj:isDead() then
                            if useID then
                                if obj:getOnlineID() == onlineID then return obj end
                            else
                                -- position fallback: return nearest zombie at this spot
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
    end

    return bestObj  -- nil when useID=true and not found; nearest when useID=false
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
function RQSvShared.eachActiveZombie(fn)
    if not _activeZombies or type(fn) ~= "function" then return 0 end
    local n = 0
    for zombie, zType in pairs(_activeZombies) do
        n = n + 1
        fn(zombie, zType)
    end
    return n
end

local function svFindActiveZombieByOnlineID(onlineID)
    if not _activeZombies then return nil, nil end
    for zombie, zType in pairs(_activeZombies) do
        local ok, oid = pcall(zombie.getOnlineID, zombie)
        if ok and oid == onlineID then
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
    local rSq = r * r
    while spawned < count and attempts < count * 3 do
        attempts = attempts + 1
        local dx = ZombRand(-r, r + 1)
        local dy = ZombRand(-r, r + 1)
        if dx * dx + dy * dy <= rSq then
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq and not sq:isSolid() then
                local okAdd, added = pcall(addZombiesInOutfit, x + dx, y + dy, z, 1, nil, 50)
                if okAdd then
                    spawned = spawned + 1
                    if added and handler then
                        pcall(function()
                            for i = 0, added:size() - 1 do
                                local zed = added:get(i)
                                if zed then handler(zed) end
                            end
                        end)
                    end
                end
            end
        end
    end
    return spawned
end

-- ========================
-- EMP helpers - shared because Boss uses EMP blast too
-- ========================

local function svApplyEMPEnduranceDrain(player)
    if not player then return end
    pcall(function()
        local level = player:getMoodles():getMoodleLevel(MoodleType.ENDURANCE)
        if level < 4 then
            local targets = { 0.65, 0.40, 0.18, 0.05 }
            local target  = targets[level + 1]
            local current = player:getStats():get(CharacterStat.ENDURANCE)
            if target and target < current then
                player:getStats():set(CharacterStat.ENDURANCE, target)
            end
        end
    end)
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
                            elseif obj and (instanceof(obj, "IsoTelevision") or instanceof(obj, "IsoRadio")) then
                                -- WaveSignalDevice API: getDeviceData():setIsTurnedOn(false).
                                -- Earlier code called obj:turnOff() which silently no-op'd
                                -- (that method doesn't exist on radios/TVs in vanilla - confirmed
                                -- by grep against the Steam install). Pattern below mirrors
                                -- ISMoveablesAction.lua and ISVehicleDashboard.lua.
                                local dd = obj.getDeviceData and obj:getDeviceData()
                                if dd and dd.getIsTurnedOn and dd:getIsTurnedOn() then
                                    pcall(dd.setIsTurnedOn, dd, false)
                                end
                            elseif obj and instanceof(obj, "IsoWindow") then
                                -- Shockwave shatters intact panes in the blast radius.
                                -- pcall around smashWindow because the engine call can
                                -- throw if the window is in a half-state mid-smash.
                                local okSm, smashed = pcall(obj.isSmashed, obj)
                                if okSm and not smashed then
                                    pcall(obj.smashWindow, obj)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- inner half of blast radius hits harder than outer ring
local EMP_INNER_DMG = 0.15
local EMP_OUTER_DMG = 0.10

-- Switch off + partially drain a player's handheld electronics. Filter is
-- "currently activated OR has a Battery tag OR type is Battery" so we hit
-- flashlights, lanterns, walkies, watches, plus loose battery stockpiles,
-- without accidentally consuming "uses" on unrelated drainables (food, water,
-- books, page-read trackers). Everything pcall-wrapped because inventory item
-- subclasses vary on which methods they actually expose.
--
-- Drainable semantics: setUsedDelta(x) treats x as REMAINING fullness, not
-- "amount consumed" - 1.0 = full, 0.0 = depleted. Naming is misleading but
-- the getCurrentUsesFloat/setUsedDelta pairing in vanilla (ISItemEditPanel,
-- RecipeTests, ClientCommands) confirms this. To drain, we subtract.
local function svDrainPlayerElectronics(player, drainPercent)
    local inv = player and player:getInventory()
    if not inv then return 0 end
    local items = inv:getItems()
    if not items then return 0 end
    local drainFrac = drainPercent / 100.0
    local hit = 0
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it then
            local wasActive = false
            local okA, isAct = pcall(it.isActivated, it)
            if okA and isAct then
                wasActive = true
                pcall(it.setActivated, it, false)
            end

            local isBattery = false
            if it.hasTag then
                local okTag, hasBat = pcall(it.hasTag, it, "Battery")
                if okTag and hasBat then isBattery = true end
            end
            if not isBattery and it.getType then
                local okT, t = pcall(it.getType, it)
                if okT and t == "Battery" then isBattery = true end
            end

            if (wasActive or isBattery) and it.getCurrentUsesFloat and it.setUsedDelta then
                local okD = pcall(function()
                    local cur = it:getCurrentUsesFloat() or 0
                    it:setUsedDelta(math.max(0.0, cur - drainFrac))
                end)
                if okD then hit = hit + 1 end
            end
        end
    end
    return hit
end

local function svApplyEMPBlast(x, y, z, radius, drainPercent)
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
                    local dmgPct = dSq <= innerSq and EMP_INNER_DMG or EMP_OUTER_DMG
                    local zone   = dSq <= innerSq and "inner" or "outer"
                    local hp     = p:getHealth()
                    local newHP  = math.max(0.01, hp - hp * dmgPct)
                    p:setHealth(newHP)
                    svApplyEMPEnduranceDrain(p)
                    local itemsHit = svDrainPlayerElectronics(p, drainPercent)
                    sendToPlayer(p, "empDebuff", {
                        x      = x,
                        y      = y,
                        radius = radius,
                        drain  = drainPercent,
                    })
                    playersHit = playersHit + 1
                    RQDirgeLog.write("EMP", "[INFO] blast hit player zone=" .. zone
                        .. " hp=" .. string.format("%.2f", hp) .. "->" .. string.format("%.2f", newHP)
                        .. " drain=" .. tostring(drainPercent) .. "%"
                        .. " itemsHit=" .. itemsHit)
                end
            end
        end
    end
    -- Zombies caught in the blast stumble; inner-zone zeds go down hard
    -- (mirrors the player inner/outer split). Ownership rule: only the side
    -- that OWNS a zombie may drive its state machine - and zeds near players
    -- (i.e. exactly the ones in a blast) are usually client-owned, which is
    -- why the old unconditional server-side knockDown looked like a no-op in
    -- dedicated MP. isRemoteZombie() is true here for client-owned zeds: skip
    -- them, their owning client stumbles them from the castDone broadcast
    -- (RQEMP.stumbleZombies). We handle only the server-owned remainder.
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
                                and not obj:isRemoteZombie()
                                and not obj:isReanimatedForGrappleOnly() then
                                local zdx = obj:getX() - x
                                local zdy = obj:getY() - y
                                local zdSq = zdx * zdx + zdy * zdy
                                if zdSq <= outerSq then
                                    -- IsoZombie methods must be dispatched via colon-call
                                    -- syntax (`obj:knockDown(...)`) for the Java bridge to
                                    -- resolve them. Grabbing `obj.knockDown` as a value can
                                    -- yield nil, and pcall would silently swallow the
                                    -- "attempt to call a nil value" error - the original
                                    -- pcall(obj.knockDown, obj, false) form looked correct
                                    -- but quietly no-op'd in dedicated MP. Wrap in a
                                    -- function so the dispatch happens inside the pcall.
                                    if zdSq <= innerSq and not obj:isCrawling() and not obj:isOnFloor() then
                                        pcall(function() obj:knockDown(false) end)
                                    else
                                        -- Stagger-only: knockDown's flag set minus the
                                        -- knockdown flag, so the anim graph picks plain
                                        -- staggerback instead of staggerback-knockeddown.
                                        pcall(function()
                                            obj:setStaggerBack(true)
                                            obj:setHitForce(0.5)
                                            obj:setHitReaction("")
                                            obj:reportEvent("wasHit")
                                        end)
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
RQSvShared.scheduleAction               = scheduleAction
RQSvShared.isPlayerVisible              = isPlayerVisible
RQSvShared.isAnyPlayerInRange           = isAnyPlayerInRange
RQSvShared.getPlayersInRange            = getPlayersInRange
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
