-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQEMP - the "oh shit" zombie
-- Dies, starts a countdown, then everything in range has a bad day.
-- Shockwave does more damage the closer you are - 2 zones based on
-- distance from the blast. You get a cast bar and colored rings to
-- warn you, so if you stick around that's on you.
--
-- Architecture: ALL effects (cast bar, rings, debuffs) are driven by
-- server commands (castStart → castDone → empDebuff). RQEMP.onDead
-- is a no-op - the server's zombieKilled handler owns the EMP sequence.
-- This prevents the dual-detonation bug where the client and server
-- both fired their own cast bars and effects.

RQEMP = RQEMP or {}

-- Each moodle level sits in a bracket. We drop the player into the
-- midpoint of the next bracket down so it feels consistent.
local MOODLE_DROP_TARGETS = { 0.65, 0.40, 0.18, 0.05 }

-- Knocks endurance down by one moodle tier.
function RQEMP.applyDebuff(player)
    if not player then return end
    local stats = player:getStats()
    local current = stats:get(CharacterStat.ENDURANCE)
    local level = player:getMoodles():getMoodleLevel(MoodleType.ENDURANCE)

    if level >= 4 then return end -- already bottomed out

    local target = MOODLE_DROP_TARGETS[level + 1]
    if target and target < current then
        stats:set(CharacterStat.ENDURANCE, target)
    end
end

-- Walks through the player's inventory and drains anything battery-powered.
-- Each item wrapped in pcall - B42 item API can throw for some DrainableComboItem
-- subtypes (radio stacks, worn items, etc.).
function RQEMP.drainPlayerElectronics(player, drainPercent)
    if not player then return end
    local inv = player:getInventory()
    if not inv then return end

    local items = inv:getItems()
    if not items then return end

    local drainFraction = (drainPercent or 35) / 100.0
    local totalItems = 0
    local drainedItems = 0

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and instanceof(item, "DrainableComboItem") then
            totalItems = totalItems + 1
            local getFn = item.getUsedDelta
            local setFn = item.setUsedDelta
            if getFn and setFn then
                local ok, current = pcall(getFn, item)
                if ok and type(current) == "number" and current < 1.0 then
                    pcall(setFn, item, math.min(1.0, current + drainFraction))
                    drainedItems = drainedItems + 1
                end
            end
        end
    end
    RQDirgeLog.write("EMP", "[INFO] drainPlayerElectronics drain=" .. tostring(drainPercent) .. "%"
        .. " drainable=" .. totalItems .. " drained=" .. drainedItems)
end

-- Scans tiles around the blast for generators, TVs, radios.
local function damageWorldElectronics(x, y, z, radius, damagePercent)
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
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            if obj then
                                if instanceof(obj, "IsoGenerator") then
                                    local cond = obj:getCondition()
                                    if cond and cond > 0 then
                                        local dmg = math.floor(cond * damagePercent / 100)
                                        obj:setCondition(math.max(0, cond - dmg))
                                    end
                                elseif instanceof(obj, "IsoTelevision") or instanceof(obj, "IsoRadio") then
                                    if obj.turnOff then
                                        pcall(obj.turnOff, obj)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Expanding ring that grows outward from the blast point.
local expandingRings = {}
local EXPAND_DURATION = 500

function RQEMP.startExpandingRing(x, y, z, targetRadius, color)
    local cell = getCell()
    if not cell then return end
    local sq = cell:getGridSquare(x, y, z)
    if not sq then return end
    local marker = getWorldMarkers():addGridSquareMarker(
        sq, color.r, color.g, color.b, true, 0.1)
    if marker then
        marker:setScaleCircleTexture(true)
        -- Pre-multiply by RQRing.TILE_SCALE so the per-tick setSize stays cheap.
        -- Tweak point lives in RQRing.lua; this picks it up automatically.
        expandingRings[#expandingRings + 1] = {
            marker       = marker,
            startTime    = getTimestampMs(),
            duration     = EXPAND_DURATION,
            targetRadius = targetRadius * (RQRing and RQRing.TILE_SCALE or 1.0),
        }
    end
end

local function updateExpandingRings()
    local now = getTimestampMs()
    local i = 1
    while i <= #expandingRings do
        local ring = expandingRings[i]
        local elapsed = now - ring.startTime
        if elapsed >= ring.duration then
            ring.marker:remove()
            expandingRings[i] = expandingRings[#expandingRings]
            expandingRings[#expandingRings] = nil
        else
            local progress = elapsed / ring.duration
            ring.marker:setSize(ring.targetRadius * progress)
            i = i + 1
        end
    end
end

Events.OnTick.Add(updateExpandingRings)

-- VFX only - no debuffs. Called by RQCore when castDone fires for an EMP ring.
function RQEMP.playDetonationVFX(x, y, z, radius)
    RQDirgeLog.write("EMP", "[INFO] playDetonationVFX at (" .. x .. "," .. y .. "," .. z .. ") radius=" .. tostring(radius))
    RQEMP.startExpandingRing(x, y, z, radius, RQConfig.COLORS.EMP)

    local ok1 = pcall(function()
        getClimateManager():getThunderStorm():triggerThunderEvent(x, y, false, true, false)
    end)
    if not ok1 then RQDirgeLog.write("EMP", "[WARN] triggerThunderEvent failed") end

    local ok2 = pcall(function()
        WorldFlares.launchFlare(60, x, y, radius, 0, 0.8, 0.9, 1.0, 0.5, 0.7, 1.0)
    end)
    if not ok2 then RQDirgeLog.write("EMP", "[WARN] WorldFlares.launchFlare failed") end

    -- Falloff playback (RQCore.playFalloffSound): each client scales volume
    -- by its own distance to the blast and goes silent past 70 tiles. The old
    -- PlayWorldSound radius/gain args (100/1.0, 80/0.7) were dead in B42 --
    -- the events carried at full FMOD-default volume, which is why people
    -- heard "explosions in their homes" from fights far away. The 0.7 base
    -- for PipeBombExplode now actually applies. Raw coords: playback no
    -- longer depends on the blast square being loaded on this client.
    RQCore.playFalloffSound("GeneratorBackfire", x, y, z, 1.0)
    RQCore.playFalloffSound("PipeBombExplode",   x, y, z, 0.7)
    RQDirgeLog.write("EMP", "[INFO] falloff detonation sounds fired at (" .. x .. "," .. y .. "," .. z .. ")")

    -- Zombie-attraction world sound (inaudible to players) is gameplay, not
    -- audio presentation: unchanged.
    pcall(addSound, nil, x, y, z, 100, 100)
end

-- Shockwave knockback - called by RQCore from the empDebuff handler.
function RQEMP.applyKnockback(player, distSq, radiusSq)
    if not player then return end
    local dist       = math.sqrt(distSq)
    local radius     = math.sqrt(radiusSq)
    local halfRadius = radius * 0.50
    local zone       = dist <= halfRadius and "inner" or "outer"
    RQDirgeLog.write("EMP", "[INFO] applyKnockback zone=" .. zone
        .. " dist=" .. string.format("%.1f", dist) .. " radius=" .. string.format("%.1f", radius))

    pcall(function() ISTimedActionQueue.clear(player) end)

    if dist <= halfRadius then
        pcall(function() player:getBodyDamage():ReduceGeneralHealth(10) end)
        pcall(function()
            player:setBumpType("stagger")
            player:setVariable("BumpDone", false)
            player:setVariable("BumpFall", true)
            player:setVariable("BumpFallType", "pushedFront")
        end)
    else
        pcall(function()
            player:setBumpType("stagger")
            player:setVariable("BumpDone", false)
            player:setVariable("BumpFall", false)
            player:setVariable("BumpFallType", "pushedFront")
        end)
    end

    -- Fire the state-machine transition that CONSUMES the bump variables set
    -- above. Without it the anim graph never enters BumpedState, so its exit()
    -- - the ONLY code that clears BumpType/BumpFall/BumpStaggered/BumpDone -
    -- never runs, and the player is left permanently flagged "bumped/staggered"
    -- (isBumped() stays true because bumpType is non-empty). That stuck state
    -- later mis-selects the one-handed idle when a two-handed weapon is equipped
    -- - the reported weapon-swap glitch. This mirrors the engine itself:
    -- IsoGameCharacter.attackFromWindowsLunge sets the same variables and then
    -- calls reportEvent("wasBumped"). It also makes the stagger actually play.
    pcall(function() player:reportEvent("wasBumped") end)
end

-- ========================
-- Sensory shock - inner zone blinds + deafens, outer ring deafens only.
-- Both effects are local-player-only, so this all lives client-side:
-- the screen fade and the FMOD mix don't exist anywhere else.
-- ========================

-- One live effect set per client. Repeat blasts extend the timers.
local sensory = {
    blindHoldUntil = nil,  -- fully black until here (instant on: an EMP pop IS a switch)
    blindFadeUntil = nil,  -- then alpha ramps linearly to 0, reaching it here
    deafUntil      = nil,  -- when the Deaf trait comes back off
    playerNum      = 0,
}

-- Blind overlay, drawn by hand. The engine's per-player fade API
-- (UIManager.FadeIn/FadeOut(playerIndex, seconds)) TRUNCATES seconds to a
-- whole int (engine-verified), so the 0.15s/0.4s fades the old code asked
-- for were 0-frame flips -- blind snapped on AND off. And setFadeBeforeUI's
-- name lies: true renders the fade BEFORE the UI, leaving the HUD visible on
-- top. Drawing our own black in OnPostUIDraw fixes both: it fires after UI
-- elements, tooltips, and the engine fades, so the blind genuinely covers
-- everything, and we own the curve -- instant black on the blast, ~500ms
-- linear fade back once the hold expires (the recovery is where a fade sells
-- "sight coming back"). Not a UIElement, so mouse/keyboard input is untouched.
local BLIND_FADE_MS = 500

Events.OnPostUIDraw.Add(function()
    if not sensory.blindHoldUntil then return end
    local player = getPlayer()
    if not player or player:isDead() then
        sensory.blindHoldUntil = nil
        sensory.blindFadeUntil = nil
        return
    end
    local now   = getTimestampMs()
    local alpha = 1.0
    if now >= sensory.blindHoldUntil then
        local fadeEnd = sensory.blindFadeUntil or sensory.blindHoldUntil
        if now >= fadeEnd then
            sensory.blindHoldUntil = nil
            sensory.blindFadeUntil = nil
            return
        end
        alpha = (fadeEnd - now) / BLIND_FADE_MS
    end
    pcall(function()
        local pn = sensory.playerNum or 0
        UIManager.DrawTexture(UIManager.getBlack(),
            getPlayerScreenLeft(pn), getPlayerScreenTop(pn),
            getPlayerScreenWidth(pn), getPlayerScreenHeight(pn), alpha)
    end)
end)
-- Reflection probe (RQReflect): is the blackout overlay armed right now?
-- A live blind at hit time reads exactly as "invisible zombie" to the player.
function RQEMP.isBlindActive()
    return sensory.blindHoldUntil ~= nil
end

local sensoryScrubbed = false  -- one-shot rejoin/crash cleanup, see updateSensoryEffects

-- Lifting deafness is gated on the modData flag, not just the runtime timer:
-- the flag only exists if WE added the trait to this character. A player who
-- took Deaf at creation never gets the flag, so we can never strip their
-- legitimate trait - not even after death/respawn races the timer.
local function restoreHearing(player)
    if not player then return end
    local md = player:getModData()
    if md.RQEMPDeafUntil ~= nil then
        pcall(function() player:getCharacterTraits():remove(CharacterTrait.DEAF) end)
        md.RQEMPDeafUntil = nil
        RQDirgeLog.write("EMP", "[INFO] deafness lifted")
    end
    sensory.deafUntil = nil
end

-- Called by RQCore's empDebuff handler, which the server only sends to
-- players inside the blast radius. Same half-radius inner/outer split as
-- applyKnockback.
function RQEMP.applySensoryEffects(player, distSq, radiusSq)
    if not player or player:isDead() then return end
    if distSq > radiusSq then return end -- server already range-gates; belt and braces
    local cfg   = RQConfig.get()
    local now   = getTimestampMs()
    local inner = distSq <= radiusSq * 0.25

    -- Deafen (both zones): toggling the Deaf trait drives the engine's own
    -- FMOD "Deaf" mix (ParameterDeaf polls hasTrait every frame), so we get
    -- TIS's real deafness sound instead of a volume hack. Durations are
    -- sandbox-tunable; Max = 0 disables deafening entirely, and a Min of 0
    -- means a blast can roll a zero-length (skipped) deafen.
    local deafMs = 0
    if cfg.empDeafMaxMs > 0 then
        deafMs = cfg.empDeafMinMs + ZombRand(cfg.empDeafMaxMs - cfg.empDeafMinMs + 1)
    end
    if deafMs > 0 then
        if sensory.deafUntil then
            sensory.deafUntil = math.max(sensory.deafUntil, now + deafMs)
            player:getModData().RQEMPDeafUntil = sensory.deafUntil
        elseif not player:hasTrait(CharacterTrait.DEAF) then
            local ok = pcall(function() player:getCharacterTraits():add(CharacterTrait.DEAF) end)
            if ok then
                sensory.deafUntil = now + deafMs
                -- Persisted seatbelt: traits save with the character, so a crash
                -- mid-effect would otherwise leave this player deaf forever.
                player:getModData().RQEMPDeafUntil = sensory.deafUntil
            end
        end
    end

    -- Blind (inner zone only): arm the hand-drawn overlay (see OnPostUIDraw
    -- above). Instant black for the rolled duration, then a BLIND_FADE_MS
    -- linear fade back. Repeat blasts extend the hold, never stack. Same
    -- sandbox semantics as deafen: Max = 0 disables blinding.
    local blindMs = 0
    if inner and cfg.empBlindMaxMs > 0 then
        blindMs = cfg.empBlindMinMs + ZombRand(cfg.empBlindMaxMs - cfg.empBlindMinMs + 1)
    end
    if blindMs > 0 then
        sensory.playerNum      = player:getPlayerNum()
        sensory.blindHoldUntil = math.max(sensory.blindHoldUntil or 0, now + blindMs)
        sensory.blindFadeUntil = sensory.blindHoldUntil + BLIND_FADE_MS
    end

    RQDirgeLog.write("EMP", "[INFO] sensory shock zone=" .. (inner and "inner" or "outer")
        .. " deafMs=" .. deafMs .. " blindMs=" .. blindMs)
end

local function updateSensoryEffects()
    local player = getPlayer()
    if not player then return end

    -- One-shot on entering the world: if a previous session crashed or the
    -- player rejoined mid-effect, the modData flag is still set. Resume the
    -- countdown if it's still running, lift it immediately if it expired.
    if not sensoryScrubbed then
        sensoryScrubbed = true
        local md  = player:getModData()
        local due = md.RQEMPDeafUntil
        if due then
            if getTimestampMs() >= due then
                restoreHearing(player)
            else
                sensory.deafUntil = due
            end
        end
    end

    -- Blind is fully self-contained in the OnPostUIDraw overlay; only the
    -- deaf timer needs a tick.
    if sensory.deafUntil and getTimestampMs() >= sensory.deafUntil then
        restoreHearing(player)
    end
end

Events.OnTick.Add(updateSensoryEffects)

-- ========================
-- Zombie stumble - called by RQCore when castDone fires for an EMP ring.
-- Ownership rule (same as the glutton pathing hint in RQCore): only the side
-- that OWNS a zombie may drive its state machine. Each client handles the
-- zeds it owns here; the server handles its remainder in svApplyEMPBlast.
-- ========================
function RQEMP.stumbleZombies(x, y, z, radius)
    local cell = getCell()
    if not cell then return end
    local zombies = cell:getZombieList()
    if not zombies then return end
    local outerSq = radius * radius
    local innerSq = (radius * 0.5) * (radius * 0.5)
    local downed, staggered = 0, 0

    for i = 0, zombies:size() - 1 do
        local zed = zombies:get(i)
        -- Reanimated-corpse guard: dragged corpses are live IsoZombies that
        -- inherit modData; knocking one down desyncs the grapple.
        if zed and not zed:isDead()
            and not (isClient() and zed:isRemoteZombie())
            and not zed:isReanimatedForGrappleOnly()
            and math.abs(zed:getZ() - z) < 0.5 then
            local dx  = zed:getX() - x
            local dy  = zed:getY() - y
            local dSq = dx * dx + dy * dy
            if dSq <= outerSq then
                -- Colon-call inside the pcall closure - see the dispatch note
                -- in RQSvShared.svApplyEMPBlast.
                if dSq <= innerSq and not zed:isCrawling() and not zed:isOnFloor() then
                    -- Engine's own "shove crit" bundle: flags + wasHit anim event.
                    pcall(function() zed:knockDown(false) end)
                    downed = downed + 1
                else
                    -- Stagger-only: IsoZombie.knockDown's flag set minus the
                    -- knockdown flag, so the anim graph picks the staggerback
                    -- state instead of staggerback-knockeddown.
                    pcall(function()
                        zed:setStaggerBack(true)
                        zed:setHitForce(0.5)
                        zed:setHitReaction("")
                        zed:reportEvent("wasHit")
                    end)
                    staggered = staggered + 1
                end
            end
        end
    end
    RQDirgeLog.write("EMP", "[INFO] stumbleZombies (owned here) downed=" .. downed
        .. " staggered=" .. staggered .. " radius=" .. radius)
end

-- No-op: the server's castStart broadcast drives the cast bar and rings.
-- Keeping the function so call sites don't crash.
function RQEMP.onDead(zombie)
end

Events.OnGameStart.Add(function()
    expandingRings = {}
    sensory.blindHoldUntil = nil
    sensory.blindFadeUntil = nil
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
