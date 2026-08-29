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

-- The endurance drop is server-owned (RQSvShared.svApplyEMPEnduranceDrain,
-- committed before the empDebuff packet is even sent). A client-side copy
-- (applyDebuff) survived that move with zero callers and was cut 2026-08-25;
-- reintroducing one would race the authoritative drain.

-- World damage is SERVER-OWNED, in RQSvShared.svDamageWorldElectronics. A
-- client copy of that scan lived here with zero callers until 2026-08-27 and
-- was wrong twice over: it damaged generator condition, which is authoritative
-- state no client may write, and it reached for obj:turnOff() on televisions
-- and radios - a method that exists on IsoBarbecue:244 and nowhere else in the
-- engine, so that half had never once run. Nothing client-side belongs in this
-- lane; what the blast does to devices' AUDIO is a separate concern and lives
-- in RQEMPStatic.

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

    -- getClimateManager returns the owned singleton and its ThunderStorm field;
    -- on multiplayer clients triggerThunderEvent is intentionally a no-op, while
    -- single-player queues the event through initialized climate state.
    -- LuaManager.java:9048-9050; ClimateManager.java:645-647;
    -- ThunderStorm.java:323-334.
    getClimateManager():getThunderStorm():triggerThunderEvent(x, y, false, true, false)

    -- WorldFlares is an explicitly Lua-exposed Java class. launchFlare only
    -- bounds its in-memory list and appends a populated flare, so valid blast
    -- coordinates and radius use the direct client-render contract.
    -- LuaManager.java:2122-2123; WorldFlares.java:23-27, 49-64.
    WorldFlares.launchFlare(60, x, y, radius, 0, 0.8, 0.9, 1.0, 0.5, 0.7, 1.0)

    -- Falloff playback (RQCore.playFalloffSound): each client scales volume
    -- by its own distance to the blast and goes silent past 70 tiles. The old
    -- PlayWorldSound radius/gain args (100/1.0, 80/0.7) were dead in B42 --
    -- the events carried at full FMOD-default volume, which is why people
    -- heard "explosions in their homes" from fights far away. The 0.7 base
    -- for PipeBombExplode now actually applies. Raw coords: playback no
    -- longer depends on the blast square being loaded on this client.
    --
    -- THREE LAYERS, in descending gain, and the order below is the order they
    -- are meant to be heard: the crack, the concussion, then the electrical
    -- wind-down that gives an EMP its signature. GeneratorStopping is the
    -- shutdown whine an IsoGenerator plays when it is switched off
    -- (IsoGenerator.java:473-475 -> playGeneratorSound("Stopping"), whose name
    -- is getSoundPrefix() .. suffix at :700, and getSoundPrefix() is the
    -- literal "Generator" unless the sprite carries a GeneratorSound property
    -- at :667-676). The event is real and shipped, not merely named in Java:
    -- media/scripts/generated/sounds/objects/sounds_object_generator.txt:23
    -- defines it as FMOD event Object/Generator/Shutdown.
    --
    -- Verified rather than assumed BECAUSE a wrong name is silent, not loud:
    -- FMODSoundEmitter.playSound returns 0 for an unknown event instead of
    -- throwing (FMODSoundEmitter.java:484-496), so a typo here would ship as a
    -- layer nobody ever hears and nothing would ever report it. The precedent
    -- is GeneratorBackfire on the line above, which reaches FMOD through the
    -- identical prefix+suffix concatenation and has always worked.
    --
    -- 0.65 puts it UNDER the concussion deliberately. It is a tail, not a hit:
    -- at parity with PipeBombExplode it masked the crack that reads as the
    -- detonation itself. Its clip allows distanceMax 100 while our hand-built
    -- falloff silences everything at 70, so the electrical layer stops with
    -- the rest of the blast instead of trailing past it.
    RQCore.playFalloffSound("GeneratorBackfire", x, y, z, 1.0)
    RQCore.playFalloffSound("PipeBombExplode",   x, y, z, 0.7)
    RQCore.playFalloffSound("GeneratorStopping", x, y, z, 0.65)
    RQDirgeLog.write("EMP", "[INFO] falloff detonation sounds fired at (" .. x .. "," .. y .. "," .. z .. ")")

    -- Zombie-attraction world sound (inaudible to players) is gameplay, not
    -- audio presentation: unchanged.
    -- addSound directly delegates to WorldSoundManager's final singleton; see
    -- the equivalent Screamer path for why retrying a partial sound is unsafe.
    -- LuaManager.java:9227-9229; WorldSoundManager.java:43, 73-82, 107-156.
    addSound(nil, x, y, z, 100, 100)

    -- Radios and televisions in the blast drop to static until power-cycled.
    -- Client-side by nature rather than by choice: device audio is presentation
    -- the server cannot even see (DeviceData.updateEmitter:685-688 returns on
    -- GameServer.server), so every client does this to its own copy off the
    -- broadcast it is already handling. See RQEMPStatic's header.
    RQEMPStatic.scramble(x, y, z, radius)
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

    -- Vanilla clears timed actions directly before forced actions of its own.
    -- If a current action cannot stop cleanly, continuing into a partial EMP
    -- knockback would leave worse state than surfacing the bad action.
    -- ISTimedActionQueue.lua:236-242; IsoGameCharacter.java:5107-5119.
    ISTimedActionQueue.clear(player)

    if dist <= halfRadius then
        -- The empDebuff path passes getPlayer(); IsoPlayer receives a complete BodyDamage
        -- in construction, with all parts populated before Lua can call it.
        -- IsoGameCharacter.java:796, 2803-2805; BodyDamage.java:132-155, 932-943.
        player:getBodyDamage():ReduceGeneralHealth(10)
        player:setBumpType("stagger")
        player:setVariable("BumpDone", false)
        player:setVariable("BumpFall", true)
        player:setVariable("BumpFallType", "pushedFront")
    else
        player:setBumpType("stagger")
        player:setVariable("BumpDone", false)
        player:setVariable("BumpFall", false)
        player:setVariable("BumpFallType", "pushedFront")
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
    -- IsoPlayer installs NetworkPlayerComponent during ECS registration; the
    -- NetworkPlayerAI owns a final NetworkState, whose reportEvent only records
    -- events on existing state packets.
    -- IsoPlayer.java:680-685; NetworkCharacterAI.java:65-72; NetworkState.java:267-279.
    player:reportEvent("wasBumped")
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
    -- UIManager.render initializes black.png before OnPostUIDraw, then the event
    -- manager contains listener failures. Vanilla UI code calls these viewport
    -- helpers directly.
    -- UIManager.java:298-305, 351, 965; LuaManager.java:3433-3449; Event.java:53-63.
    local pn = sensory.playerNum or 0
    UIManager.DrawTexture(UIManager.getBlack(),
        getPlayerScreenLeft(pn), getPlayerScreenTop(pn),
        getPlayerScreenWidth(pn), getPlayerScreenHeight(pn), alpha)
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
        -- 42.20.3: LuaManager.java:1783,2225 exposes CharacterTraits and
        -- CharacterTrait; CharacterTrait.java:33 defines the base Deaf trait;
        -- CharacterTraits.java:82-88 add/remove an already-resolved trait.
        player:getCharacterTraits():remove(CharacterTrait.DEAF)
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
            -- Same verified fixed-trait path as restoreHearing above.
            player:getCharacterTraits():add(CharacterTrait.DEAF)
            sensory.deafUntil = now + deafMs
            -- Persisted seatbelt: traits save with the character, so a crash
            -- mid-effect would otherwise leave this player deaf forever.
            player:getModData().RQEMPDeafUntil = sensory.deafUntil
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
-- casterID: onlineID of the zombie that cast this blast, or nil when there is
-- no live caster (an EMP zombie detonates on death; the admin command has no
-- caster at all). The client half of the caster-immunity rule - see
-- RQSvShared.svApplyEMPBlast for the whole story. Both halves must honour it
-- or the Boss still faceplants whenever a client owns it.
function RQEMP.stumbleZombies(x, y, z, radius, casterID)
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
            and not (casterID and zed:getOnlineID() == casterID)
            and not zed:isReanimatedForGrappleOnly()
            and math.abs(zed:getZ() - z) < 0.5 then
            local dx  = zed:getX() - x
            local dy  = zed:getY() - y
            local dSq = dx * dx + dy * dy
            if dSq <= outerSq then
                -- Unguarded: IsoZombie.knockDown:4094 is six field sets plus
                -- reportEvent, which on a zombie is only ActionContext:219
                -- occurredAnimEvents.add - the getNetworkCharacterAI() branch
                -- there is local-IsoPlayer only.
                if dSq <= innerSq and not zed:isCrawling() and not zed:isOnFloor() then
                    -- Engine's own "shove crit" bundle: flags + wasHit anim event.
                    zed:knockDown(false)
                    downed = downed + 1
                else
                    -- Stagger-only: IsoZombie.knockDown's flag set minus the
                    -- knockdown flag, so the anim graph picks the staggerback
                    -- state instead of staggerback-knockeddown.
                    zed:setStaggerBack(true)
                    zed:setHitForce(0.5)
                    zed:setHitReaction("")
                    zed:reportEvent("wasHit")
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
