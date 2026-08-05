-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQHealthBar - floating health bars over zombies
-- Mostly for testing/admin use to verify HP multipliers and
-- Glutton growth are working correctly. Shows current/max HP
-- and the zombie type name if it's a special. Toggle it on
-- in sandbox options, leave it off for normal play.

RQHealthBar = RQHealthBar or {}

local BAR_W = 56
local BAR_H = 8
local BAR_Y_OFFSET = -10
local TEXT_Y_OFFSET = -22  -- distance above the bar to draw the numeric overlay
local VIEW_RANGE_SQ = 900 -- don't bother rendering past 30 tiles

local hudPanel = nil
local hudActive = false

-- 1x1 pixel element trick - keeps the HUD overlay from eating
-- mouse clicks on the actual game world. Same approach as the
-- cast bar system (see RQCastBar.lua).
local RQHealthBarHUD = ISUIElement:derive("RQHealthBarHUD")

function RQHealthBarHUD:new()
    local o = ISUIElement:new(0, 0, 1, 1)
    setmetatable(o, self)
    self.__index = self
    o:setWantKeyEvents(false)
    return o
end

function RQHealthBarHUD:prerender() end

-- block nothing, pass everything through
function RQHealthBarHUD:onMouseDown(x, y) return false end
function RQHealthBarHUD:onRightMouseDown(x, y) return false end
function RQHealthBarHUD:onMouseUp(x, y) return false end
function RQHealthBarHUD:onRightMouseUp(x, y) return false end
function RQHealthBarHUD:onMouseMove(dx, dy) return false end
function RQHealthBarHUD:onMouseMoveOutside(dx, dy) return false end
function RQHealthBarHUD:onMouseWheel(del) return false end
function RQHealthBarHUD:onFocus(x, y) end

function RQHealthBarHUD:render()
    local player = getPlayer()
    if not player then return end

    local cfg = RQConfig.get()
    if not cfg.showHealthBars then return end

    local playerNum = player:getPlayerNum()
    local px = player:getX()
    local py = player:getY()
    local pz = math.floor(player:getZ())
    local cell = getCell()
    if not cell then return end

    self:suspendStencil()

    -- Full step=1 scan of a 60-tile-square window. Earlier code stepped by 2
    -- to halve the iteration cost, but that visits only tiles of one parity:
    -- as the player walks, the scanned parity flips and every zombie's bar
    -- flickers in and out from frame to frame. ~3700 tile lookups at step=1
    -- is still trivially cheap and produces a stable overlay.
    local scanRange = 30
    local ix = math.floor(px)
    local iy = math.floor(py)

    for dx = -scanRange, scanRange do
        for dy = -scanRange, scanRange do
            local sq = cell:getGridSquare(ix + dx, iy + dy, pz)
            if sq then
                local movObjs = sq:getMovingObjects()
                if movObjs then
                    for i = 0, movObjs:size() - 1 do
                        local obj = movObjs:get(i)
                        if obj and instanceof(obj, "IsoZombie") then
                            local ok, dead = pcall(obj.isDead, obj)
                            if ok and not dead then
                                local zx = obj:getX()
                                local zy = obj:getY()
                                local zz = obj:getZ()

                                local ddx = zx - px
                                local ddy = zy - py
                                if ddx * ddx + ddy * ddy <= VIEW_RANGE_SQ then
                                    local hp = obj:getHealth()

                                    -- Authoritative max-HP source per type. Server-stamped values
                                    -- win where they exist. Priority:
                                    --   1. RQJuggMaxHP (Juggernaut) - stamped at conversion
                                    --   2. scavClientState.peakHP (Scavenger, post-snapshot)
                                    --   3. RQGluttonBaseHealth * gluttonMaxMult (Glutton + pre-rage
                                    --      Scav) - the theoretical eating-cap so the bar reads
                                    --      progressive fill instead of always 100%
                                    --   4. fall back to current HP (Screamer/EMP/Boss, no growth)
                                    local md = obj:getModData()
                                    local maxHP = md["RQJuggMaxHP"]
                                    if not maxHP then
                                        local sok, oid = pcall(obj.getOnlineID, obj)
                                        if sok and oid and RQReconcile and RQReconcile.scavClientState then
                                            local sc = RQReconcile.scavClientState[oid]
                                            if sc and sc.peakHP and sc.peakHP > 0 then
                                                maxHP = sc.peakHP
                                            end
                                        end
                                    end
                                    if not maxHP then
                                        local baseHP = md["RQGluttonBaseHealth"]
                                        if baseHP and baseHP > 0 then
                                            local maxMult = (cfg.gluttonMaxMult or 5)
                                            maxHP = baseHP * maxMult
                                        end
                                    end
                                    maxHP = maxHP or hp
                                    local pct = math.min(1.0, hp / math.max(maxHP, 0.0001))

                                    local sx = isoToScreenX(playerNum, zx, zy, zz + 0.6)
                                    local sy = isoToScreenY(playerNum, zx, zy, zz + 0.6)
                                    local bx = sx - BAR_W / 2
                                    local by = sy + BAR_Y_OFFSET

                                    -- smooth green-yellow-red gradient
                                    local r, g
                                    if pct > 0.5 then
                                        r = (1.0 - pct) * 2.0
                                        g = 1.0
                                    else
                                        r = 1.0
                                        g = pct * 2.0
                                    end

                                    self:drawRect(bx, by, BAR_W, BAR_H, 0.5, 0.1, 0.1, 0.1)
                                    if pct > 0 then
                                        self:drawRect(bx, by, BAR_W * pct, BAR_H, 0.8, r, g, 0.0)
                                    end

                                    -- colored border on specials so they pop
                                    local ok2, zoid = pcall(obj.getOnlineID, obj)
                                    local zType = ok2 and zoid and RQRegistry.activeZombies[zoid]
                                    if zType then
                                        local col = RQConfig.COLORS[zType]
                                        if col then
                                            self:drawRectBorder(bx, by, BAR_W, BAR_H, 0.8, col.r, col.g, col.b)
                                        end
                                    end

                                    -- text overlay with actual numbers
                                    local hpStr = string.format("%.1f / %.1f", hp, maxHP)
                                    if zType then
                                        hpStr = hpStr .. " (" .. zType .. ")"
                                    end
                                    local textW = getTextManager():MeasureStringX(UIFont.Small, hpStr)
                                    self:drawText(hpStr, sx - textW / 2, by + TEXT_Y_OFFSET,
                                        1.0, 1.0, 1.0, 0.9, UIFont.Small)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    self:resumeStencil()
end

local function onGameStart()
    hudActive = false
    if hudPanel and hudPanel.javaObject then
        pcall(hudPanel.removeFromUIManager, hudPanel)
    end
    hudPanel = RQHealthBarHUD:new()
    hudPanel:initialise()
    hudPanel:addToUIManager()
    hudPanel:setVisible(true)
    hudActive = true
end

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
