-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQSvBoss - the apex zombie
-- Three things going at once:
--   1) Passive juggernaut-style buff aura, always on, sweeps every 2s.
--      Buffs ALL nearby zombies including specials (juggernauts skip specials).
--      Strength is 1.5x the configured Juggernaut buff percent.
--   2) Coin-flip skill rotation between Scream and EMPulse, 40s cooldown.
--      Each skill uses a cast bar so the client can warn the player before it fires.
--   3) Sprinter movement, set up at spawn via RQSvShared.applyBossSprinter.
if not isServer() then return end

RQSvBoss = RQSvBoss or {}
RQSvBoss.state = {}   -- bossID -> { lastSkillTime, lastBuffTick, castDue, currentSkill, skillX/Y/Z, baseHealth }
-- weak-keyed so dead zombies get GC'd. Tracks which zombies have already taken the boss buff
-- so the aura sweep doesnt stack indefinitely.
RQSvBoss.buffed = setmetatable({}, { __mode = "k" })

-- _activeZombies is kept for setActiveZombies compatibility but the boss buff aura
-- intentionally ignores it - the boss buff applies to specials too, unlike juggernaut.
local _activeZombies = {}
function RQSvBoss.setActiveZombies(tbl)
    _activeZombies = tbl
end

local BOSS_SKILL_COOLDOWN = 40000   -- (ms) hardcoded 40s between Scream/EMPulse casts. Overrides cfg.bossSkillCooldown.
local BOSS_BUFF_INTERVAL  = 2000    -- (ms) buff aura sweep cadence. Same gating idea as Juggernaut tick (every ~2s).
local BOSS_BUFF_MULTIPLIER = 1.5    -- boss buff is 1.5x stronger than Juggernaut. Jugg=10% -> Boss=15%, Jugg=20% -> Boss=30%, etc.

-- Passive buff aura sweep. Walks the radius once, applies the boss buff to any
-- unbuffed zombie (including specials) and marks them in RQSvBoss.buffed so we
-- never stack on the same target. A zombie already inside a Juggernaut aura can
-- still take the boss buff on top - the visual override is what tells the player
-- the boss is the one driving the buff in this area.
local function svDoBossBuff(zombie, cfg)
    local cell = getCell()
    if not cell then return 0 end
    local x = math.floor(zombie:getX())
    local y = math.floor(zombie:getY())
    local z = math.floor(zombie:getZ())
    local radius  = cfg.juggernautBuffRadius
    local buffPct = (cfg.juggernautBuffPercent * BOSS_BUFF_MULTIPLIER) / 100.0
    local rSq = radius * radius
    local count = 0
    for ddx = -radius, radius do
        for ddy = -radius, radius do
            if ddx*ddx + ddy*ddy <= rSq then
                local sq = cell:getGridSquare(x+ddx, y+ddy, z)
                if sq then
                    local movs = sq:getMovingObjects()
                    if movs then
                        for mi = 0, movs:size()-1 do
                            local obj = movs:get(mi)
                            if obj and instanceof(obj, "IsoZombie") and not obj:isDead()
                               and obj ~= zombie
                               and not RQSvBoss.buffed[obj] then
                                -- ownerOnly + latch-on-success: see the matching
                                -- comment in RQSvJuggernaut's aura. A failed
                                -- placement simply retries next pass.
                                if RQSvShared.svSetZombieHP(obj, obj:getHealth() * (1.0 + buffPct), true) then
                                    RQSvBoss.buffed[obj] = true
                                    count = count + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return count
end

-- main tick, called each alive behavior pass for boss zombies
function RQSvBoss.tick(zombie)
    local cfg    = RQSvShared.getSvConfig()
    local bossID = zombie:getOnlineID()
    local state  = RQSvBoss.state[bossID]
    if not state then
        state = {
            lastSkillTime = getTimestampMs(),
            lastBuffTick  = 0,
            castDue       = nil,
            currentSkill  = nil,
            skillX = 0, skillY = 0, skillZ = 0,
            baseHealth = zombie:getHealth(),
        }
        RQSvBoss.state[bossID] = state
    end
    local now = getTimestampMs()

    -- passive buff aura sweep, throttled. runs regardless of whether a cast is active -
    -- the buff doesnt wait its turn, the skills do.
    if now - state.lastBuffTick >= BOSS_BUFF_INTERVAL then
        state.lastBuffTick = now
        local n = svDoBossBuff(zombie, cfg)
        if n > 0 then
            RQDirgeLog.write("Boss", "[INFO] id=" .. tostring(bossID) .. " buff aura buffed=" .. n .. " zombies")
        end
    end

    -- if a cast is already running, check if its done and execute the skill effect
    if state.castDue then
        if now >= state.castDue then
            local skill = state.currentSkill
            local x = math.floor(zombie:getX())
            local y = math.floor(zombie:getY())
            local z = math.floor(zombie:getZ())
            state.castDue      = nil
            state.currentSkill = nil
            state.lastSkillTime = now
            -- EMP gets its own ring ID so the client can size the ring differently
            local completedRingId = (skill == "EMPulse") and ("boss_emp_" .. bossID) or ("boss_" .. bossID)
            -- skill name is what the client uses to pick the right resolve effect:
            -- audible scream, buff pulse, EMP detonation. without it the client cant tell
            -- which boss skill just finished and only EMP gets a visual payoff.
            RQSvShared.broadcast("castDone", { ringId = completedRingId, fixedX = x, fixedY = y, fixedZ = z,
                skill = skill,
                radius = (skill == "EMPulse") and cfg.empRadius or nil })
            if not zombie:isDead() then
                if skill == "Scream" then
                    addSound(zombie, x, y, z, cfg.screamerSoundRadius, cfg.screamerSoundRadius)
                    local nearbyCount = RQSvShared.svCountNearbyAliveZombies(x, y, z, RQSvShared.SCREAMER_SPAWN_RADIUS, zombie)
                    if nearbyCount < cfg.screamerSpawnThreshold then
                        local spawnCount = cfg.screamerSpawnMin + ZombRand(cfg.screamerSpawnMax - cfg.screamerSpawnMin + 1)
                        RQDirgeLog.write("Boss", "[INFO] id=" .. tostring(bossID) .. " Scream executed"
                            .. " nearby=" .. nearbyCount .. " threshold=" .. cfg.screamerSpawnThreshold
                            .. " spawning=" .. spawnCount)
                        RQSvShared.svDoSpawn(x, y, z, spawnCount)
                    else
                        RQDirgeLog.write("Boss", "[INFO] id=" .. tostring(bossID) .. " Scream executed"
                            .. " nearby=" .. nearbyCount .. " >= threshold - no spawn")
                    end
                elseif skill == "EMPulse" then
                    RQDirgeLog.write("Boss", "[INFO] id=" .. tostring(bossID) .. " EMPulse executed"
                        .. " at (" .. x .. "," .. y .. "," .. z .. ") radius=" .. cfg.empRadius)
                    RQSvShared.svApplyEMPBlast(x, y, z, cfg.empRadius, cfg.empBatteryDrain)
                end
            end
        end
        return
    end
    -- nothing casting, check if a player is close enough to trigger a new skill
    if not RQSvShared.isAnyPlayerInRange(zombie, RQSvShared.BOSS_TRIGGER_RANGE) then return end
    -- 40s cooldown is hardcoded here, not pulled from cfg.bossSkillCooldown. Tweak BOSS_SKILL_COOLDOWN above if you need a different cadence.
    if now - state.lastSkillTime < BOSS_SKILL_COOLDOWN then return end
    local skill = RQSvShared.BOSS_SKILLS[ZombRand(#RQSvShared.BOSS_SKILLS) + 1]
    local x = math.floor(zombie:getX())
    local y = math.floor(zombie:getY())
    local z = math.floor(zombie:getZ())
    RQDirgeLog.write("Boss", "[INFO] id=" .. tostring(bossID) .. " skill SELECTED=" .. skill
        .. " at (" .. x .. "," .. y .. "," .. z .. ")"
        .. " sinceLastSkill=" .. (now - state.lastSkillTime) .. "ms")
    local ringRadius = 0
    if skill == "Scream" then ringRadius = math.min(cfg.screamerSoundRadius, 15)
    elseif skill == "EMPulse" then ringRadius = cfg.empRadius
    end
    local bossRingId = (skill == "EMPulse") and ("boss_emp_" .. bossID) or ("boss_" .. bossID)
    -- castStart args carry the skill name so the client can fire skill-specific
    -- effects when the cast begins. Scream needs an audible sound here, otherwise
    -- the player only sees a cast bar with no audio cue.
    local castArgs = RQSvShared.makeCastArgs(bossRingId, x, y, z, cfg.bossCastTime, RQSvShared.COLORS.Boss, RQSvShared.BOSS_SKILL_LABELS[skill], ringRadius, zombie:getOnlineID())
    castArgs.skill = skill
    RQSvShared.broadcast("castStart", castArgs)
    state.currentSkill = skill
    state.skillX, state.skillY, state.skillZ = x, y, z
    state.castDue = now + cfg.bossCastTime
end

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
