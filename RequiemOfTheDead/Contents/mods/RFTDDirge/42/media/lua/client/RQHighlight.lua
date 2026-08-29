-- SPDX-License-Identifier: GPL-3.0-or-later
-- RQHighlight - outline glow on special zombies
--
-- PZ does not persist outline highlights between frames, so we reapply them
-- every render tick. That is not a workaround, it is the engine's design:
-- IsoMovingObject.renderlast() draws the outline and then clears the bit in
-- the same call (IsoMovingObject.java:1019-1030). Repainting is the only way
-- an outline stays on, and NOT repainting is the only way one comes off.
--
-- The registry is keyed by onlineID and the object is resolved at render time
-- through RQZombieCache, so a dead or unloaded special is simply a miss - not
-- a stale table entry that poisons the loop.

-- Core's world-focus claim. Explicit rather than riding the alphabetical client
-- walk: this file only reads it inside a render callback, but the dependency is
-- real and CLAUDE.md sect. 4 is about not discovering that the hard way. Dirge
-- hard-requires Core, so it always resolves.
require "RDZombieFocus"

RQHighlight = RQHighlight or {}

-- One special, one frame. Split out of the loop so the focus check can bail
-- with a plain `return` - Lua 5.1 has no `continue`, and the alternative was
-- burying the whole body one level deeper inside an `if`.
local function paintSpecial(onlineID, zType, playerNum)
    -- YIELD TO A PANEL FOCUS. An admin surface that has claimed this zombie is
    -- painting it white so the operator can confirm the row and the body are the
    -- same thing, and the engine holds exactly one outline colour per player
    -- index (IsoObject.java:5122) - so repainting the type colour here does not
    -- blend with the white, it replaces it. Worse, it does so reliably rather
    -- than intermittently: renderInternal() runs before onRender() in
    -- GameWindow.frameStep (:726-737), so a UI prerender writes first and this
    -- listener always wins the frame. Skipping is what makes the claim mean
    -- anything; the type colour returns on the first tick after it is released.
    if RDZombieFocus.isFocused(onlineID) then return end

    -- resolve object at render time; nil = not in loaded chunks, skip.
    -- No isDead() branch here any more: RQZombieCache's liveness rule refuses
    -- to return a dead zombie at all, so the branch that used to un-paint one
    -- could not be reached - and had nothing to do if it were, since
    -- renderlast() clears the bit itself (see the note above remove's grave).
    local zombie = RQCore.findZombieByID(onlineID)
    if not zombie then return end

    local col
    -- Boss aura override: if this zombie is currently being painted by a Boss
    -- buff aura, force boss color regardless of its own type. Boss render tick
    -- rebuilds bossBuffPainted before this loop runs.
    if RQBoss and RQBoss.bossBuffPainted and RQBoss.bossBuffPainted[zombie] then
        col = RQConfig.COLORS.Boss
    elseif zType == "Scavenger" and RQScavenger and RQScavenger.getHighlightColor then
        col = RQScavenger.getHighlightColor(onlineID)
    elseif zType == "EMP" then
        -- Match the EMP inner knockdown ring (orange) so the body glow and that
        -- ring read as one colour - and so EMPs are no longer confused with
        -- Juggernauts (blue).
        col = RQConfig.COLORS.EMPInner
    end
    col = col or RQConfig.COLORS[zType]
    if col then
        zombie:setOutlineHighlight(playerNum, true)
        zombie:setOutlineHighlightCol(playerNum, col.r, col.g, col.b, col.a)
    end
end

local function onRenderTick()
    local player = getPlayer()
    if not player then return end
    local playerNum = player:getPlayerNum()

    for onlineID, zType in pairs(RQRegistry.activeZombies) do
        paintSpecial(onlineID, zType, playerNum)
    end
end

Events.OnRenderTick.Add(onRenderTick)

-- RQHighlight.remove IS GONE, deleted 2026-08-25, and the reason is the same
-- fact this whole file is built on - stated here because the function looked
-- load-bearing and was not.
--
-- IsoMovingObject.renderlast() reads the outline bit for the rendering player
-- and, having drawn it, immediately calls setOutlineHighlight(playerIndex,
-- false) (IsoMovingObject.java:1019-1030). The two-argument setter's false
-- branch clears that player's bit and, once the byte reaches zero, calls
-- FBORenderObjectOutline.unregisterObject (IsoObject.java:5171-5182). So the
-- engine both un-paints and un-registers on its own, every frame, and there is
-- nothing left over at death for a Lua caller to tidy up. That is precisely
-- WHY this file repaints every render tick.
--
-- It had also become unreachable: RQCore's death handler ran it after
-- RQZombieCache had already evicted the row, and the cache refuses to hand
-- back a dead zombie, so the lookup could only miss. Two independent reasons
-- for the same call to do nothing is a good sign it should not exist.
-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
