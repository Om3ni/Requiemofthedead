-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDZombieFocus - "this is the one you picked", painted white in the world.
--
-- One claim at a time, held by whichever admin surface last asked for it. A
-- panel row and a body in the street are the same zombie only if the operator
-- can SEE that they are, and an outline is the only affordance that says so.
--
-- WHY THIS IS IN CORE. Two consumers, and they are in different mods that must
-- not learn about each other: RFTDReaper's Necro tab claims a focus when a row
-- resolves to exactly one zombie, and RFTDDirge's RQHighlight yields its own
-- per-type outline for whatever is claimed. Reaper cannot reach into Dirge (it
-- may not be installed) and Dirge must never depend on Reaper. Both hard-require
-- Core, so the claim lives here and neither has to name the other.
--
-- WHY THE PAINTING IS HERE TOO, rather than left with the claimant. The engine
-- gives every IsoObject ONE outline colour per player index
-- (IsoObject.java:274, 5122), so two per-frame painters on the same zombie is
-- not a race - it is a guaranteed loss for whoever runs first. Verified
-- 2026-08-19: GameWindow.frameStep runs renderInternal() BEFORE onRender()
-- (GameWindow.java:726-737), so a UI prerender always writes earlier in the
-- frame than any OnRenderTick listener, and Dirge's type colour overwrote the
-- panel's white every single frame - deterministically, not as flicker. Putting
-- the paint here and making Dirge SKIP a claimed id means exactly one painter
-- touches the zombie, so the answer no longer depends on listener order (which
-- is the alphabetical client walk, i.e. on filenames).
--
-- WHITE IS NOT A DEFAULT WE CAN LEAN ON. IsoObject initialises every
-- outlineHighlightCol entry to -1 (:314), which is ABGR white - so an
-- uncoloured highlight LOOKED right and was never actually asked for. Vanilla
-- combat targeting writes that same field (CombatManager.java:2616-2617), so
-- the accident lasts only until the operator swings at something. The colour is
-- set explicitly here, every frame, for that reason.

if isServer() then return end

RDZombieFocus = RDZombieFocus or {}

-- Full-alpha white. Not a palette entry: DFKit.col is the deck's skin and this
-- is painted on the world, where "the one you picked" has to read against every
-- Dirge type colour at once rather than harmonise with a panel.
local FOCUS_R, FOCUS_G, FOCUS_B, FOCUS_A = 1, 1, 1, 1

-- FULL-ALPHA WHITE WAS NOT ENOUGH, and the alpha above is not why.
--
-- The renderer takes only the R/G/B of what we store and OVERWRITES the alpha:
--   setOutlineColor(r, g, b, isOutlineHlBlink(idx) ? Core.blinkAlpha : 1.0f)
-- (IsoObject.java:3406, and identically at :3426 and :3542). So FOCUS_A is
-- discarded on every path, and fading or pulsing the colour by hand cannot
-- work - the engine owns that channel outright.
--
-- What it hands over instead is a BLINK BIT, and the value behind it is a real
-- pulse: Core.blinkAlpha walks 0.15 to 1.0 and back at 0.07 per 30fps frame
-- (Core.java:944-951), roughly a 0.8s cycle. Motion is what the eye catches in
-- a scene this desaturated, where a static white line competes with concrete,
-- sky and the zombie's own pallor. setOutlineHlBlink(int, boolean) is
-- index-scoped like everything else here (IsoObject.java:5213).
--
-- Thickness is the second half. The shader's step size comes from
-- outlineThickness (:3409), default 1.0 (:275), and setOutlineThickness is a
-- plain public setter (:5227). Unlike the colour and the blink bit it is NOT
-- player-indexed, so on splitscreen a thickened outline is thick for both
-- views - the colour and enable bits still are not, so player 2 sees nothing
-- unless another painter claims the same zombie. Cosmetic, and worth the
-- legibility; the previous value is captured and put back on release so a
-- Dirge special does not inherit our line weight.
--
-- All three are public, non-static and unannotated, so the exposer publishes
-- them like any other method (LuaJavaClassExposer.java:314-318).
local FOCUS_THICKNESS = 2.0

local focusId   = nil   -- claimed onlineID, or nil
local painted   = nil   -- the IsoZombie we last turned an outline ON for
local priorThickness = nil   -- what `painted` had before we thickened it
local lease     = 0     -- render ticks the claim survives without renewal

-- A FOCUS IS A LEASE, NOT A LATCH, and that is the whole lifecycle design.
--
-- The alternative was a close hook on DFRegistry's tab contract, which would
-- have meant changing a Core registration API that five mods implement, to
-- solve a problem only one of them has. It also would not have covered the case
-- that actually bites: the deck being torn down without the tab hearing about
-- it. A tab that is no longer rendering cannot release anything, however good
-- its manners.
--
-- So the claimant renews by continuing to exist: it calls set() from its own
-- per-frame render path, and this counts down every tick. Ordering makes it
-- free rather than tight - a UI prerender runs inside renderInternal(), which
-- GameWindow.frameStep calls BEFORE onRender() (:726-737), so within one frame
-- the renewal always lands before the decrement. Three ticks of slack covers a
-- dropped frame without letting the outline outlive the panel by anything a
-- person would notice.
--
-- The visible consequence, and it is the one we want: close the deck and the
-- white outline goes out on its own. Before this it stayed lit on that zombie
-- for as long as it remained loaded, because nothing was ever going to turn it
-- off.
local LEASE_TICKS = 3

-- getPlayerNum is carried as @Deprecated in 42.20.3 but is also the method
-- carrying @UsedFromLua (IsoPlayer.java:968-972); it delegates straight to
-- getIndex(). The deprecation is Java-side housekeeping, not a Lua surface
-- being withdrawn, and this is the call the rest of the suite already makes.
local function localIndex()
    local p = getPlayer()
    if not p then return nil end
    return p:getPlayerNum()
end

-- Resolve an onlineID against the local cell's zombie list.
--
-- Here there are no coordinates to trust - the whole point of a focus is that
-- the panel row may be stale - so the id is the only key, and the cell's own
-- list is the authoritative set of zombies this client has loaded. Its cost is
-- one pass over the loaded population per frame WHILE A FOCUS IS HELD, which
-- is a panel-open, one-row-selected state, not a background one.
--
-- This used to say "deliberately NOT the bounded-box walk in
-- RQCore.findZombieByID", and that contrast is dead: as of 2026-08-25 that
-- function is an id-keyed map lookup with no box and no coordinates, which is
-- the same shape as this. Core must not depend back on Dirge (CLAUDE.md sect.
-- 12), so this stays its own pass rather than borrowing Dirge's cache - but if
-- a second Core consumer ever appears, promoting RQZombieCache is the answer,
-- not a third copy of this loop.
local function resolve(onlineID)
    local p = getPlayer()
    if not p then return nil end
    local cell = p:getCell()
    if not cell then return nil end
    local list = cell:getZombieList()
    if not list then return nil end
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and z:getOnlineID() == onlineID then return z end
    end
    return nil
end

-- Turn our own outline back off. The index-scoped overload is the one that
-- matters: setOutlineHighlight(boolean) writes the whole 4-bit player mask
-- (IsoObject.java:5140), so on a splitscreen client the untyped call would
-- highlight - and then un-highlight - for every local player at once.
--
-- A zombie another module also paints (a Dirge special) goes dark for at most
-- one frame: its owning painter reasserts on the next tick. That is why this
-- clears rather than trying to restore a previous colour it has no way to know.
local function unpaint()
    if not painted then return end
    local idx = localIndex()
    if idx then
        painted:setOutlineHighlight(idx, false)
        -- The blink bit is index-scoped and STICKS. Left set, the next painter
        -- to claim this zombie - a Dirge special - would inherit a pulse it
        -- never asked for and has no idea how to turn off.
        painted:setOutlineHlBlink(idx, false)
    end
    -- Thickness is per-object, not per-player, so it is restored rather than
    -- zeroed: putting back what was there keeps this honest even if something
    -- else starts setting it.
    if priorThickness then
        painted:setOutlineThickness(priorThickness)
        priorThickness = nil
    end
    painted = nil
end

-- Claim the focus. Pass nil, 0, or a non-number to release it - 0 is how the
-- engine reports "no network id assigned", so it can never name a zombie.
function RDZombieFocus.set(onlineID)
    local id = tonumber(onlineID)
    if not id or id == 0 then
        RDZombieFocus.clear()
        return
    end
    if focusId ~= id then unpaint() end
    focusId = id
    lease   = LEASE_TICKS
end

function RDZombieFocus.clear()
    unpaint()
    focusId = nil
    lease   = 0
end

function RDZombieFocus.id()
    return focusId
end

-- The yield check other painters call. Cheap by construction: a comparison
-- against one upvalue, no engine call, so RQHighlight pays it per special per
-- frame without noticing.
function RDZombieFocus.isFocused(onlineID)
    return focusId ~= nil and focusId == onlineID
end

-- Repainted every frame rather than latched, because the outline flag is not
-- ours alone: vanilla combat targeting and Dirge both write the same field, and
-- a zombie that walks out of the loaded cell and back in returns with the flag
-- cleared. Re-resolving also means a focus on something that has since died or
-- unloaded simply stops drawing instead of holding a stale reference.
local function onRenderTick()
    if not focusId then return end

    lease = lease - 1
    if lease <= 0 then
        RDZombieFocus.clear()
        return
    end

    local z = resolve(focusId)
    if not z then
        -- Not loaded HERE, which is not the same as gone: the operator may have
        -- walked out of range of a row that is still perfectly real. Drop the
        -- paint, keep the claim, and pick it up again if it comes back.
        unpaint()
        return
    end
    if z:isDead() then
        -- Gone for good. A corpse is not the zombie the operator picked, so the
        -- claim is released outright rather than left for the lease to drain -
        -- otherwise Dirge would go on yielding its own outline to a body that
        -- nothing is painting.
        RDZombieFocus.clear()
        return
    end

    local idx = localIndex()
    if not idx then return end

    if painted and painted ~= z then unpaint() end
    if painted ~= z then priorThickness = z:getOutlineThickness() end
    painted = z
    z:setOutlineHighlight(idx, true)
    z:setOutlineHighlightCol(idx, FOCUS_R, FOCUS_G, FOCUS_B, FOCUS_A)
    z:setOutlineHlBlink(idx, true)
    z:setOutlineThickness(FOCUS_THICKNESS)
end

Events.OnRenderTick.Add(onRenderTick)

-- A focus is a live-world claim, so it cannot outlive the world. Without this
-- an id set in one session survives into the next and paints whatever zombie
-- the server happens to hand that number to. Claimants release their own focus
-- when their panel closes; this is the backstop for the case where there is no
-- panel left to do it.
Events.OnGameStart.Add(function()
    focusId = nil
    painted = nil
    lease   = 0
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
