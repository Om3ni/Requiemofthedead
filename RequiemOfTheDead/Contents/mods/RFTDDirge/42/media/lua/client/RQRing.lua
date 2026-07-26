-- RQRing - ground circles via WorldMarkers
-- Shows range indicators under zombies and at blast sites.
-- Handles create/update/remove so callers don't have to think
-- about marker lifecycle. Also supports flashing mode for
-- things that need attention.

RQRing = RQRing or {}

-- Active range rings: ringId -> { marker, x, y, z, radius }
local activeRings = {}

-- Flash state: ringId -> { visible, lastToggle }
local flashState = {}

-- Flash interval (milliseconds)
local FLASH_INTERVAL = 300

-- Tile-to-marker scale for ring rendering. PZ's addGridSquareMarker takes a
-- "size" param that doesnt render 1:1 with tile distance - the visible circle
-- comes out smaller than the value you pass. We multiply here so callers can
-- keep passing tile distances and the visible ring matches the gameplay area.
--
-- TWEAK THIS if rings dont line up with their effect:
--   too small (stumble/aura extends past the visible ring) -> increase the value
--   too big  (effect ends well inside the visible ring)    -> decrease the value
-- 2.0 is the starting guess. 1.5 is a  reduction after testing 
-- the original 2.0 was a hair too big, especially for smaller rings. 
-- Note that the scale applies to all rings in the mod (stumble, EMP blast, 
-- Juggernaut aura, etc) so it may not be perfect for every use case but should be 
-- close enough across the board with this single tweak.
-- Affects every ring in the mod (range telegraphs, EMP detonation expanding ring,
-- Juggernaut aura, Scavenger rage, Boss buff pulse) so a single tweak fixes everything.
RQRing.TILE_SCALE = 1.5


-- Gate: per-type ring visibility controlled by sandbox toggles. The single
-- global ShowGroundRings option was replaced with per-zombie-type flags so
-- admins can decide which threats get a visible telegraph and which don't.
-- ringId prefix -> sandbox flag:
--   "emp_*"        -> showEMPRing       (default on - every emp_* ring is the
--                                        death-detonation telegraph, a lethal
--                                        AoE warning; EMP has no other rings)
--   "boss_*"       -> showBossRing      (default on - apex tier, skill telegraph)
--   "scav_*"       -> showScavengerRing (default off)
--   "jugg_*"       -> showJuggernautRing(default off)
--   "screamer_*"   -> showScreamerRing  (default off)
--   "glutton_*"    -> showGluttonRing   (default off)
--   anything else  -> allow through (no gate)
local function isRingBlockedByGate(ringId)
    if not ringId then return false end
    local cfg = RQConfig.get()
    if ringId:sub(1, 4) == "emp_"      then return not cfg.showEMPRing        end
    if ringId:sub(1, 5) == "boss_"     then return not cfg.showBossRing       end
    if ringId:sub(1, 5) == "scav_"     then return not cfg.showScavengerRing  end
    if ringId:sub(1, 5) == "jugg_"     then return not cfg.showJuggernautRing end
    if ringId:sub(1, 9) == "screamer_" then return not cfg.showScreamerRing   end
    if ringId:sub(1, 8) == "glutton_"  then return not cfg.showGluttonRing    end
    return false
end

-- Create WorldMarker circular range ring
local function createMarker(x, y, z, radius, color)
    local cell = getCell()
    if not cell then return nil end
    local sq = cell:getGridSquare(x, y, z)
    if not sq then return nil end
    local marker = getWorldMarkers():addGridSquareMarker(
        sq, color.r, color.g, color.b, true, radius * RQRing.TILE_SCALE)
    if marker then
        marker:setScaleCircleTexture(true)
    end
    return marker
end

-- Draw circular range ring on the ground
function RQRing.show(ringId, x, y, z, radius, color)
    if isRingBlockedByGate(ringId) then return end

    -- Clear old ring first
    RQRing.clear(ringId)

    local marker = createMarker(x, y, z, radius, color)
    if marker then
        activeRings[ringId] = { marker = marker, x = x, y = y, z = z, radius = radius, lastRefresh = getTimestampMs() }
    end
end

-- Clear specified range ring
function RQRing.clear(ringId)
    local ring = activeRings[ringId]
    if not ring then return end
    if ring.marker then
        ring.marker:remove()
    end
    activeRings[ringId] = nil
    -- Also clean flash state to prevent stale entries
    flashState[ringId] = nil
end

-- Update range ring position (only redraw when position changes)
function RQRing.update(ringId, x, y, z, radius, color)
    if isRingBlockedByGate(ringId) then return end
    local ring = activeRings[ringId]
    if ring and ring.x == x and ring.y == y and ring.z == z and ring.radius == radius then
        -- Position unchanged, but bump lastRefresh so the GC sweep doesn't
        -- nuke us after 10s of stillness. Without this, stationary rings
        -- (raging scav while eating, idle boss/jugg) vanish and only come
        -- back when the zombie moves.
        ring.lastRefresh = getTimestampMs()
        return
    end
    RQRing.show(ringId, x, y, z, radius, color)
end

-- Flash range ring (called each frame, internally controls toggle frequency)
function RQRing.flash(ringId, x, y, z, radius, color)
    if isRingBlockedByGate(ringId) then return end
    local now = getTimestampMs()
    local state = flashState[ringId]

    if not state then
        flashState[ringId] = { visible = true, lastToggle = now }
        RQRing.show(ringId, x, y, z, radius, color)
        return
    end

    if now - state.lastToggle >= FLASH_INTERVAL then
        state.lastToggle = now
        state.visible = not state.visible
        if state.visible then
            RQRing.show(ringId, x, y, z, radius, color)
        else
            -- Remove marker but keep flash state
            local ring = activeRings[ringId]
            if ring and ring.marker then
                ring.marker:remove()
            end
            activeRings[ringId] = nil
        end
    elseif state.visible then
        RQRing.update(ringId, x, y, z, radius, color)
    end
end

-- Stop flashing and clear range ring
function RQRing.stopFlash(ringId)
    flashState[ringId] = nil
    local ring = activeRings[ringId]
    if ring then
        if ring.marker then ring.marker:remove() end
        activeRings[ringId] = nil
    end
end

-- Clear all range rings and flash state (called on game restart)
-- FIX: collect IDs first, then clear, to avoid modifying table during pairs()
function RQRing.clearAll()
    local toRemove = {}
    local count = 0
    for ringId, _ in pairs(activeRings) do
        count = count + 1
        toRemove[count] = ringId
    end
    for i = 1, count do
        local ring = activeRings[toRemove[i]]
        if ring and ring.marker then
            ring.marker:remove()
        end
        activeRings[toRemove[i]] = nil
    end
    flashState = {}
end

Events.OnGameStart.Add(RQRing.clearAll)

-- periodic ghost ring cleanup: any ring not refreshed in 10 seconds
-- is probably orphaned (zombie died and cleanup didn't reach us)
local RING_MAX_AGE = 10000
local ringCleanupTick = 0

Events.OnTick.Add(function()
    ringCleanupTick = ringCleanupTick + 1
    if ringCleanupTick < 600 then return end  -- check every ~10 seconds
    ringCleanupTick = 0

    local now = getTimestampMs()
    local stale = {}
    local count = 0
    for ringId, ring in pairs(activeRings) do
        if ring.lastRefresh and (now - ring.lastRefresh > RING_MAX_AGE) then
            count = count + 1
            stale[count] = ringId
        end
    end
    for i = 1, count do
        local ring = activeRings[stale[i]]
        if ring and ring.marker then ring.marker:remove() end
        activeRings[stale[i]] = nil
    end
end)

-- Copyright Project_Omen
