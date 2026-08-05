-- SPDX-License-Identifier: GPL-3.0-or-later
-- LSMap - embedded interactive world map for the Longstrider tab.
--
-- Wraps an ISMiniMapInner (the same textured map widget the in-game M map
-- uses) inside an ISPanel so it can live inside a Dragonfly tab. The heavy
-- part is the one-time InitPlayer ritual that streams every lot directory's
-- worldmap data/images into the widget; that's why instances are cached
-- module-level per player and re-parented across Dragonfly's tab rebuilds
-- rather than rebuilt each time (see DFPanel:showTab, which recreates the
-- tab content area on every switch).
--
-- PROVENANCE: re-authored 2026-08-04 (LM-EDIT-1). Written from vanilla's own
-- shipped Lua - ISUI/Maps/ISMiniMap.lua and ISMapDefinitions.lua - and from the
-- engine decompile, with the reasoning recorded at each call site. Earlier
-- revisions of this file were shaped by reading PhunZones2's ui_map.lua; no
-- line of it survives here. See docs/limes-design.md §2.
--
-- We need three things and no more: the widget, the mapAPI coordinate
-- transforms, and a frame-the-bounds helper. All zone/rect interaction lives in
-- LSGridOverlay.

if isServer() then return end

require "ISUI/ISPanel"

LSMap = ISPanel:derive("LSMap")
-- Session cache, keyed by player index (split-screen gets one entry each). Not
-- evicted on disconnect: the Lua VM resets on reconnect, clearing this wholesale,
-- and a single admin holds at most one entry - so forget() exists for explicit
-- eviction but isn't wired to a lifecycle hook by design.
LSMap.instances = LSMap.instances or {}

-- Empirical default zoom. PZ map zoom is a logarithmic scale (NOT tiles/pixel);
-- ~11.5 frames a broad regional overview. Higher = closer. Overridden by
-- zoomAndCentreMapToBounds once a tour region is selected.
local DEFAULT_ZOOM = 11.5

function LSMap:new(x, y, w, h, player)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.player          = player
    o.playerIndex     = player:getPlayerNum()
    o.background       = false
    o.borderColor      = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.moveWithMouse    = false
    o.map              = nil   -- the ISMiniMapInner
    o._initialised     = false
    return o
end

function LSMap:createChildren()
    ISPanel.createChildren(self)

    -- Mirror PhunZones: construct, addChild, then run the data ritual. The
    -- inner map sets up self.map.mapAPI during this.
    self.map = ISMiniMapInner:new(0, 0, self.width, self.height, self.playerIndex)
    self:addChild(self.map)

    -- VANILLA CLICK = OPEN THE FULLSCREEN MAP, and that is a trap in an
    -- embedded editor. ISMiniMapInner is the HUD minimap widget: its contract
    -- is "click me to expand", so onMouseUp ends the drag and, if the mouse
    -- moved under 4px, calls ISWorldMap.ToggleWorldMap
    -- (media/lua/client/ISUI/Maps/ISMiniMap.lua:239-245). Every plain click on
    -- our canvas - selecting a region, clicking empty space - threw the admin
    -- into the fullscreen map. LSGridOverlay cannot prevent it: it only
    -- consumes while a handle or body drag is live, so a click always reaches
    -- the original handler.
    --
    -- Replaced per INSTANCE, never on the class: the HUD minimap and any other
    -- mod's ISMiniMapInner keep vanilla behaviour. Clearing the drag flag is
    -- the only other thing the original does, so nothing is lost. Done before
    -- LSGridOverlay:hookNow() captures its `origUp`, so the overlay wraps this
    -- safe version rather than the toggling one.
    --
    -- onMouseUpOutside delegates to onMouseUp in vanilla (:247), so releasing
    -- off-widget reopened the map too - it gets the same treatment.
    local function endDrag(s) s.dragging = false end
    self.map.onMouseUp        = function(s) endDrag(s) end
    self.map.onMouseUpOutside = function(s) endDrag(s) end

    self:initMap()
end

-- The one-time world data load + view defaults. Guarded heavily because a
-- single bad lot dir shouldn't kill the whole tab.
--
-- PROVENANCE (LM-EDIT-1, resolved 2026-08-04): this sequence is THE INDIE
-- STONE'S, not another mod's. Vanilla runs the identical ritual in its own
-- shipped Lua - media/lua/client/ISUI/Maps/ISMiniMap.lua:709-723 walks
-- getLotDirectories(), addData()s each existing worldmap.xml, calls
-- endDirectoryData() per directory and addImages() for the folder, then
-- setBoundsFromWorld() - and MapUtils in ISMapDefinitions.lua:22-30 repeats the
-- same walk for map data, streets and annotations. Eight call sites in vanilla
-- use it. The order is not a style choice either: endDirectoryData() marks the
-- boundary after which no later data may claim a cell already covered by this
-- directory, which is why directories are walked highest-priority (mods) to
-- lowest (vanilla) and why the call sits INSIDE the loop. Written here from
-- that vanilla source and the engine's own API, not transcribed from the other
-- mod that also copied it.
function LSMap:initMap()
    if self._initialised then return end

    -- Warm the global world-map screen first. ISMiniMapInner builds its own
    -- UIWorldMap in instantiate(), but the shared map singletons (styles,
    -- symbol defaults) are brought up by the full-screen map, and an embedded
    -- instance created before anything has opened it has been seen to come up
    -- without a usable mapAPI. Show-then-hide is the cheapest way to force that
    -- initialisation using vanilla's own public entry points, and it is a no-op
    -- once the instance exists. pcall'd because it is a convenience, not a
    -- requirement - if it fails we still check the API below.
    if not ISWorldMap_instance then
        pcall(function()
            ISWorldMap.ShowWorldMap(self.playerIndex)
            ISWorldMap.HideWorldMap(self.playerIndex)
        end)
    end

    local api = self.map.mapAPI
    if not api then
        print("[Dragonfly] LSMap: mapAPI missing after construction; map disabled")
        return
    end

    local ok, err = pcall(function()
        local dirs = getLotDirectories()
        for i = 1, dirs:size() do
            local sub  = dirs:get(i - 1)
            local file = "media/maps/" .. sub .. "/worldmap.xml"
            if fileExists(file) then api:addData(file) end
            api:endDirectoryData()
            api:addImages("media/maps/" .. sub)
        end
        api:setBoundsFromWorld()
        api:setZoom(DEFAULT_ZOOM)

        -- View flags. Only the ones every embedded consumer wants: show the whole
        -- world rather than the visited part, draw player markers so the admin can
        -- orient, and hide vanilla map symbols so an overlay is not fighting them.
        --
        -- THE CELL GRID IS NOT SET HERE, deliberately (2026-08-04). This used to
        -- turn "CellGrid" on for everybody, which is a VIEW POLICY and belongs to
        -- whoever is using the map, not to the bring-up. Longstrider wants it -
        -- its whole job is walking 300-tile cells - and LSTab sets it from
        -- LSTours.gridOn immediately after acquiring the map anyway, so nothing is
        -- lost there. Limes' zone editor emphatically does not: a 256-square
        -- lattice over the entire map buries the zone rectangles it exists to
        -- draw. The engine's own default is false (WorldMapRenderer.java:140,
        -- and CellGrid300 at :141 is a separate option, also false), so consumers
        -- that say nothing now get a clean map.
        api:setBoolean("HideUnvisited", false)
        api:setBoolean("Players",       true)
        api:setBoolean("RemotePlayers", true)
        api:setBoolean("PlayerNames",   true)
        api:setBoolean("Symbols",       false)
        api:setBoolean("Isometric",     false)

        -- Centre on the player initially.
        if self.player then api:centerOn(self.player:getX(), self.player:getY()) end

        MapUtils.initDefaultStyleV1(self.map)
    end)

    if not ok then
        print("[Dragonfly] LSMap initMap error: " .. tostring(err))
        return
    end

    self._initialised = true
    print("[Dragonfly] LSMap initialised for player " .. tostring(self.playerIndex))
end

-- Convenience accessors -----------------------------------------------------

function LSMap:getAPI()
    return self.map and self.map.mapAPI
end

-- Frame the map view on a world-space rectangle, with a small margin.
--
-- SOLVED, NOT SEARCHED (LM-EDIT-1, re-authored 2026-08-04). The engine's zoom
-- is logarithmic and the relationship is published in the decompile:
--
--   metersPerPixel = 40075016.686 / (2^zoom * tileSize)   MapProjection.java:26-28
--   worldScale     = 1 / metersPerPixel                   WorldMapRenderer.java:373-377
--
-- so worldScale - the pixels-per-world-tile the API reports - is proportional
-- to 2^zoom for a given widget. Everything else in those formulae is constant
-- here, which means the constant never has to be written down:
--
--   worldScale(z2) / worldScale(z1) = 2 ^ (z2 - z1)
--   z2 = z1 + log2( needed / have )
--
-- Ask the API what scale we have at the zoom we are on, work out the scale that
-- would make the rectangle fit, and the answer is one logarithm. One setZoom,
-- no stepping, and it lands on the exact fractional zoom instead of the nearest
-- half-step - so a small region frames tightly rather than being rounded out to
-- the next rung. math.log is registered by Kahlua (MathLib.names[14]), checked
-- rather than assumed.
local LOG2 = math.log(2)

function LSMap:zoomAndCentreMapToBounds(x1, y1, x2, y2)
    local api = self:getAPI()
    if not api then return end

    local margin = 10
    local wx1, wy1 = x1 - margin, y1 - margin
    local wx2, wy2 = x2 + margin, y2 + margin
    local ww = math.max(1, wx2 - wx1)
    local wh = math.max(1, wy2 - wy1)
    local cx, cy = wx1 + ww / 2, wy1 + wh / 2

    api:centerOn(cx, cy)

    local vw, vh = self.map:getWidth(), self.map:getHeight()
    if vw <= 0 or vh <= 0 then return end

    -- The tighter axis decides, so the whole rectangle fits rather than the
    -- larger dimension merely fitting its own axis.
    local need = math.min(vw / ww, vh / wh)
    local have = api:getWorldScale()
    if not have or have <= 0 or need <= 0 then return end

    -- setZoom clamps into [baseZoom, maxZoom] itself
    -- (WorldMapRenderer.java:439-443), so an out-of-range answer for a huge or
    -- microscopic region resolves to the nearest legal zoom rather than needing
    -- its own guard here.
    local zoom = api:getZoomF() + math.log(need / have) / LOG2
    api:setZoom(zoom)

    -- Re-centre after zooming: the zoom is applied about the current view, so
    -- the centre drifts if it is only set beforehand.
    api:centerOn(cx, cy)
    return zoom
end

-- Resize both the wrapper and the inner map together.
function LSMap:setMapSize(w, h)
    self:setWidth(w)
    self:setHeight(h)
    if self.map then
        self.map:setWidth(w)
        self.map:setHeight(h)
    end
end

-- ---------------------------------------------------------------------------
-- Session cache: one initialised map per player PER CONSUMER, reused across tab
-- rebuilds. The caller is responsible for re-parenting it into the live content
-- area. Returns an *initialised, instantiated* LSMap.
--
-- WHY `key`, added 2026-08-04 for Limes' M4 editor: an overlay takes the map
-- over by wrapping its render and mouse handlers permanently (see
-- LSGridOverlay:hookNow). Two tabs sharing one widget would therefore stack two
-- overlays on it, and both would draw - Longstrider's tour rectangles would
-- appear over the zone editor and vice versa, with the mouse going to whichever
-- wrapper happened to be outermost. Nothing about that is fixable from inside
-- either overlay, so each consumer that wants a map asks for its own by name.
--
-- The cost is a second bring-up, which is local: getLotDirectories, fileExists,
-- addData/addImages against media/maps on this machine, zero packets. Callers
-- that genuinely want to share a view can pass the same key on purpose.
-- ---------------------------------------------------------------------------
function LSMap.acquire(player, w, h, key)
    local ck = player:getPlayerNum() .. "/" .. tostring(key or "longstrider")
    local inst = LSMap.instances[ck]
    if inst and inst._initialised then
        inst:setMapSize(w, h)
        return inst
    end

    inst = LSMap:new(0, 0, w, h, player)
    inst:initialise()     -- runs createChildren -> initMap
    inst:instantiate()
    LSMap.instances[ck] = inst
    return inst
end

-- Drop cached instances for a player (e.g. on death / disconnect) so they
-- rebuild. Every key for that player goes, since the caller is talking about
-- the player and not about one tab's copy.
function LSMap.forget(playerIndex)
    local prefix = tostring(playerIndex) .. "/"
    for ck in pairs(LSMap.instances) do
        if type(ck) == "string" and ck:sub(1, #prefix) == prefix then
            LSMap.instances[ck] = nil
        end
    end
end

-- Dragonfly Longstrider v0.3.0

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
