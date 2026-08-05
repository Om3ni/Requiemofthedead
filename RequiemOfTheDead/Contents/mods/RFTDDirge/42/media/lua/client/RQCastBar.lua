-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQCastBar - progress bars above zombies or at world positions
-- Two modes: follow a living zombie, or hover at a fixed spot
-- (like the EMP death location). Uses a 1x1 pixel ISUIElement
-- trick to avoid blocking mouse clicks on the game world.
-- suspendStencil lets us draw anywhere on screen despite the
-- tiny element size.

RQCastBar = RQCastBar or {}

-- Active cast bars table: barId -> barData
local activeBars = {}
local nextBarId = 1

-- Active cast bar count
-- Note: B42 Kahlua doesn't support next(), can't use next(activeBars)==nil to check empty
local activeBarCount = 0

-- Progress bar size constants
local BAR_W = 60
local BAR_H = 6
local BAR_Y_OFFSET = -10   -- Vertical offset above head position

-- Detect if zombie is in stagger/knockdown state
-- Cast bar should be interrupted when staggered or knocked down
local function isZombieStaggered(zombie)
    if not zombie then return false end
    if zombie.isKnockedDown then
        local ok, val = pcall(zombie.isKnockedDown, zombie)
        if ok and val then return true end
    end
    if zombie.isOnFloor then
        local ok, val = pcall(zombie.isOnFloor, zombie)
        if ok and val then return true end
    end
    if zombie.isFallingDown then
        local ok, val = pcall(zombie.isFallingDown, zombie)
        if ok and val then return true end
    end
    return false
end

-- HUD panel reference and state
local hudPanel = nil
local hudActive = false

-- Key design: element size is 1x1 pixel, Java UIManager only checks mouse hit
-- within that 1 pixel, won't block mouse clicks on the game world.
-- Uses suspendStencil() to remove clipping limits, allowing drawing anywhere on screen.

local RQCastBarHUD = ISUIElement:derive("RQCastBarHUD")

function RQCastBarHUD:new()
    local o = ISUIElement:new(0, 0, 1, 1)
    setmetatable(o, self)
    self.__index = self
    o:setWantKeyEvents(false)
    return o
end

function RQCastBarHUD:prerender() end

-- Defensive override: don't consume events even if mouse is at (0,0)
function RQCastBarHUD:onMouseDown(x, y) return false end
function RQCastBarHUD:onRightMouseDown(x, y) return false end
function RQCastBarHUD:onMouseUp(x, y) return false end
function RQCastBarHUD:onRightMouseUp(x, y) return false end
function RQCastBarHUD:onMouseMove(dx, dy) return false end
function RQCastBarHUD:onMouseMoveOutside(dx, dy) return false end
function RQCastBarHUD:onMouseWheel(del) return false end
function RQCastBarHUD:onFocus(x, y) end

-- Render all active cast bars
function RQCastBarHUD:render()
    local player = getPlayer()
    if not player then return end
    local playerNum = player:getPlayerNum()
    local now = getTimestampMs()

    -- Remove 1x1 clipping limit, allow drawing at any screen position
    self:suspendStencil()

    for _, bar in pairs(activeBars) do
        repeat
            -- Get world coordinates
            local wx, wy, wz
            local zombieAlive = false
            if bar.zombie then
                local ok, dead = pcall(bar.zombie.isDead, bar.zombie)
                zombieAlive = ok and not dead
                -- Double check: HP <= 0 means zombie is dying, treat as dead
                if zombieAlive then
                    local ok2, hp = pcall(bar.zombie.getHealth, bar.zombie)
                    if not ok2 or (hp and hp <= 0) then
                        zombieAlive = false
                    end
                end
            end
            if zombieAlive then
                local ok, x = pcall(bar.zombie.getX, bar.zombie)
                if ok then
                    local ok2, y = pcall(bar.zombie.getY, bar.zombie)
                    local ok3, z = pcall(bar.zombie.getZ, bar.zombie)
                    if ok2 and ok3 then
                        wx, wy, wz = x, y, z
                    end
                end
            elseif bar.fixedX then
                wx = bar.fixedX
                wy = bar.fixedY
                wz = bar.fixedZ
            else
                break
            end

            if not wx then break end

            -- World coords -> screen coords (+0.6 = head height, ref official TensionUI.lua)
            local sx = isoToScreenX(playerNum, wx, wy, wz + 0.6)
            local sy = isoToScreenY(playerNum, wx, wy, wz + 0.6)

            -- Calculate progress 0.0 -> 1.0
            local elapsed = now - bar.startTime
            local progress = math.min(1.0, elapsed / bar.duration)

            local bx = sx - BAR_W / 2
            local by = sy + BAR_Y_OFFSET

            -- Background (dark gray semi-transparent)
            self:drawRect(bx, by, BAR_W, BAR_H, 0.7, 0.1, 0.1, 0.1)
            -- Progress fill (type color)
            if progress > 0 then
                self:drawRect(bx, by, BAR_W * progress, BAR_H, 0.9,
                    bar.color.r, bar.color.g, bar.color.b)
            end
            -- Border
            self:drawRectBorder(bx, by, BAR_W, BAR_H, 0.8, 0.8, 0.8, 0.8)

            -- Label text (above progress bar). Gated on the
            -- ShowCastBarText sandbox option (default off) so servers
            -- run with clean visuals by default. EMP-family labels
            -- ("EMP Detonating...", "EMP Charging...") bypass the
            -- gate because the EMP blast is critical danger telegraph.
            -- Empty string is still treated as "no label" for callers
            -- that deliberately pass "".
            if bar.label and bar.label ~= "" then
                local cfg = RQConfig.get()
                local isEmpLabel = bar.label:sub(1, 3) == "EMP"
                if cfg.showCastBarText or isEmpLabel then
                    local textW = getTextManager():MeasureStringX(UIFont.Small, bar.label)
                    self:drawText(bar.label, sx - textW / 2, by - 14,
                        1.0, 1.0, 1.0, 0.9, UIFont.Small)
                end
            end
        until true
    end

    self:resumeStencil()
end


-- Add panel to UIManager (if not already added)
local function attachHUD()
    if hudPanel and not hudActive then
        hudPanel:addToUIManager()
        hudPanel:setVisible(true)
        hudActive = true
    end
end

-- Remove panel from UIManager (if added and no active cast bars)
-- Reset flag first to prevent residual panel if removeFromUIManager throws
local function detachHUDIfEmpty()
    if hudPanel and hudActive and activeBarCount == 0 then
        hudActive = false
        if hudPanel.javaObject then
            pcall(hudPanel.removeFromUIManager, hudPanel)
        end
    end
end


-- Create a new cast bar
function RQCastBar.create(params)
    local id = nextBarId
    nextBarId = nextBarId + 1
    activeBarCount = activeBarCount + 1

    activeBars[id] = {
        zombie    = params.zombie,       -- Living zombie to follow (follow mode)
        fixedX    = params.fixedX,       -- Fixed world coordinate X (fixed mode)
        fixedY    = params.fixedY,
        fixedZ    = params.fixedZ,
        startTime = params.startTime or getTimestampMs(),
        duration  = params.duration,     -- Cast duration (milliseconds)
        color     = params.color,        -- Progress bar color {r, g, b}
        label     = params.label,        -- Display text
        onComplete = params.onComplete,  -- Completion callback
        onCancel  = params.onCancel,     -- Cancel callback (zombie death etc.)
        interruptOnStagger = params.interruptOnStagger,
    }

    -- Attach to UIManager when first cast bar appears
    attachHUD()

    return id
end

-- Cancel a cast bar
function RQCastBar.cancel(id)
    local bar = activeBars[id]
    if bar then
        activeBars[id] = nil
        activeBarCount = math.max(0, activeBarCount - 1)
        if bar.onCancel then pcall(bar.onCancel) end
        detachHUDIfEmpty()
    end
end

-- Check if a cast bar is still active
function RQCastBar.isActive(id)
    return activeBars[id] ~= nil
end


-- OnTick: detect cast bar completion and zombie death
-- Safe removal buffer (cannot nil-delete during pairs iteration in Lua 5.1)
local toRemoveBuffer = {}

local function onTick()
    local now = getTimestampMs()
    local removeCount = 0

    for id, bar in pairs(activeBars) do
        -- Follow mode: zombie died -> cancel cast bar
        local zombieDied = false
        if bar.zombie then
            local ok, dead = pcall(bar.zombie.isDead, bar.zombie)
            zombieDied = not ok or dead
            -- Double check: HP <= 0 also treated as dead
            if not zombieDied then
                local ok2, hp = pcall(bar.zombie.getHealth, bar.zombie)
                if not ok2 or (hp and hp <= 0) then
                    zombieDied = true
                end
            end
        end
        if zombieDied then
            if bar.onCancel then pcall(bar.onCancel) end
            removeCount = removeCount + 1
            toRemoveBuffer[removeCount] = id
        -- Stagger/knockdown interrupt
        elseif bar.interruptOnStagger and bar.zombie and isZombieStaggered(bar.zombie) then
            if bar.onCancel then pcall(bar.onCancel) end
            removeCount = removeCount + 1
            toRemoveBuffer[removeCount] = id
        -- Cast bar complete
        elseif now >= bar.startTime + bar.duration then
            if bar.onComplete then pcall(bar.onComplete) end
            removeCount = removeCount + 1
            toRemoveBuffer[removeCount] = id
        end
    end

    -- Safe deletion after iteration ends
    for i = 1, removeCount do
        activeBars[toRemoveBuffer[i]] = nil
        toRemoveBuffer[i] = nil
    end

    -- Sync counter, remove from UIManager after all cast bars end
    if removeCount > 0 then
        activeBarCount = math.max(0, activeBarCount - removeCount)
        detachHUDIfEmpty()
    end
end

-- Initialize HUD panel on game start and clean up residual cast bar data
local function onGameStart()
    activeBars = {}
    nextBarId = 1
    activeBarCount = 0

    -- If panel from previous session is still in UIManager, remove it first
    hudActive = false
    if hudPanel and hudPanel.javaObject then
        pcall(hudPanel.removeFromUIManager, hudPanel)
    end

    hudPanel = RQCastBarHUD:new()
    hudPanel:initialise()
    -- Don't add to UIManager here, wait until first cast bar is created
end

Events.OnTick.Add(onTick)
Events.OnGameStart.Add(onGameStart)

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
