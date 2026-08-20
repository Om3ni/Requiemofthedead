-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDWorldOverlay - the 1x1 click-through element every world HUD in the family
-- is actually built on.
--
-- THE TRICK, stated once instead of three times. Anything drawn over the world
-- needs a UI element to draw from, and a UI element occupies screen space that
-- UIManager will happily let eat a mouse click meant for the game. So the
-- element is made ONE PIXEL square - UIManager only tests the cursor against
-- that footprint - and then suspendStencil() lifts the clipping rectangle so
-- drawing can go anywhere on screen regardless. A full-screen panel with
-- pass-through handlers would be the obvious alternative and is worse: it still
-- takes the hit test first, so every miss depends on remembering to return
-- false from every handler, forever, in every subclass.
--
-- WHY THIS IS IN CORE. Three copies across two mods, written independently and
-- byte-identical in the part that matters: Dirge's cast bar and health bar and
-- Last Rites' danger HUD. Each carried its own :new(), its own empty
-- :prerender(), its own set of return-false handlers and its own four-line boot
-- sequence. That is one idiom, not three - and the failure mode of getting it
-- wrong is a HUD that silently swallows clicks on the world, which reads to a
-- player as the game ignoring them rather than as a mod misbehaving.
-- Promoted 2026-08-19.
--
-- WHAT SUBCLASSES OWN: render(), and nothing else. Derive, write render, call
-- suspendStencil() inside it before drawing off the footprint, and use attach()
-- to put it on screen.
--
--     local MyHUD = RDWorldOverlay:derive("MyHUD")
--     function MyHUD:render()
--         local player = getPlayer()
--         if not player then return end
--         self:suspendStencil()
--         ...
--     end
--     hud = RDWorldOverlay.attach(MyHUD)
--
-- No :new() override is needed or wanted: ISBaseObject.derive points the
-- subclass's metatable at this one (ISBaseObject.lua:9-16), so MyHUD:new()
-- resolves here with self = MyHUD and the instance gets the right chain.

if isServer() then return end

require "ISUI/ISUIElement"

RDWorldOverlay = ISUIElement:derive("RDWorldOverlay")

function RDWorldOverlay:new()
    local o = ISUIElement:new(0, 0, 1, 1)
    setmetatable(o, self)
    self.__index = self
    -- Key events are a keyboard-focus claim, and an overlay that has never been
    -- clicked has no business holding one.
    o:setWantKeyEvents(false)
    return o
end

-- Deliberately empty, and deliberately present. ISUIElement's own prerender
-- paints the element's background, which on a 1x1 element is a stray pixel in
-- the corner of whatever the overlay happens to sit over.
function RDWorldOverlay:prerender() end

-- THESE ARE LOAD-BEARING, not defensive decoration, and the reason was worth
-- reading for. UIElement.consumeMouseEvents DEFAULTS TO TRUE (UIElement.java:73),
-- and the dispatcher treats a nil Lua return as "ask the default": returning
-- nothing from onMouseDown lands on `return this.consumeMouseEvents ?
-- Boolean.TRUE : Boolean.FALSE` (:915-917), i.e. the click is EATEN. Vanilla's
-- own ISUIElement:onMouseUp / onMouseMove return nothing (ISUIElement.lua:1513,
-- :1563) and it has no onMouseDown at all, so inheriting is not neutral here -
-- it is the consuming case. An explicit `false` is the only answer that gets a
-- click through to the world.
--
-- The engine's own switch for this is javaObject:setConsumeMouseEvents(false),
-- which is what ISToolTip and ISSleepingUI use (:14, :79) and which would cover
-- every mouse path at once instead of six named ones. It is NOT used here on
-- purpose: javaObject does not exist until instantiate() (ISUIElement.lua:993),
-- so taking it would mean instantiating inside new() and changing the lifecycle
-- of three shipping HUDs on a path only a live boot can check. The overrides are
-- what those three already run in the field. Worth revisiting at a Mosaic boot,
-- not worth guessing at now.
function RDWorldOverlay:onMouseDown(x, y) return false end
function RDWorldOverlay:onRightMouseDown(x, y) return false end
function RDWorldOverlay:onMouseUp(x, y) return false end
function RDWorldOverlay:onRightMouseUp(x, y) return false end
function RDWorldOverlay:onMouseMove(dx, dy) return false end
function RDWorldOverlay:onMouseMoveOutside(dx, dy) return false end

-- ISUIElement:onFocus calls bringToTop() on any parentless element
-- (ISUIElement.lua:1542-1546). An overlay has no parent, so inheriting that
-- would let a stray click at 0,0 reorder it against every other window on
-- screen. It draws where it draws; z-order is not its to claim.
function RDWorldOverlay:onFocus(x, y) end

-- Create, wire and show, in the order UIManager needs. Separated from new()
-- because the three call sites all did these four lines by hand and one of them
-- doing them in a different order would have been a bug nobody could see.
function RDWorldOverlay.attach(class)
    local o = class:new()
    o:initialise()
    o:addToUIManager()
    o:setVisible(true)
    return o
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
