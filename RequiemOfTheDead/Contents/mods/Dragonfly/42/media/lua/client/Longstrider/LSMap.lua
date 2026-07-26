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
-- Cribbed from PhunZones2's ui_map.lua (UburGeek), reshaped to Dragonfly
-- conventions. We only need: the widget, the mapAPI coord transforms, and
-- a frame-the-bounds helper. All zone/rect interaction lives in LSGridOverlay.

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

    self:initMap()
end

-- ===== LS-DERIVED BEGIN ====================================================
-- SOURCE: PhunZones2 (UburGeek) - ui_map.lua : ISMiniMapInner setup ritual.
-- Mostly required engine boilerplate to bring up an embedded map, but the call
-- sequence was lifted from PhunZones. RE-AUTHOR / make it ours before Workshop.
-- ===========================================================================
-- The one-time world data load + view defaults. Guarded heavily because a
-- single bad lot dir shouldn't kill the whole tab.
function LSMap:initMap()
    if self._initialised then return end

    -- The minimap API depends on the global world map instance existing.
    -- Touch it the way PhunZones does to force-create it, harmlessly.
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

        -- View flags: show the real 300-tile cell grid and player markers so the
        -- admin can orient; hide vanilla map symbols to keep our overlay clean.
        api:setBoolean("HideUnvisited", false)
        api:setBoolean("CellGrid",      true)
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
-- ===== LS-DERIVED END (PhunZones2 ui_map.lua : setup ritual) ================

-- Convenience accessors -----------------------------------------------------

function LSMap:getAPI()
    return self.map and self.map.mapAPI
end

-- ===== LS-DERIVED BEGIN ====================================================
-- SOURCE: PhunZones2 (UburGeek) - ui_map.lua : zoomAndCentreMapToBounds.
-- The zoom-fit search loop (24..10 step -0.5, worldScale vs viewport) is a
-- near-verbatim paraphrase of theirs. RE-AUTHOR before Workshop publish.
-- ===========================================================================
-- Frame the map view on a world-space rectangle, with a small margin.
function LSMap:zoomAndCentreMapToBounds(x1, y1, x2, y2)
    local api = self:getAPI()
    if not api then return end

    local margin = 10
    local wx, wy   = x1 - margin, y1 - margin
    local wx2, wy2 = x2 + margin, y2 + margin
    local width, height = wx2 - wx, wy2 - wy
    local bound  = math.max(width, height)
    local cx, cy = wx + width / 2, wy + height / 2

    local viewport = math.max(self.map:getWidth(), self.map:getHeight())

    api:centerOn(cx, cy)
    for zoom = 24, 10, -0.5 do
        api:setZoom(zoom)
        local scale = api:getWorldScale()
        if bound * scale < viewport then
            api:centerOn(cx, cy)
            return zoom
        end
    end
    api:centerOn(cx, cy)
end
-- ===== LS-DERIVED END (PhunZones2 ui_map.lua : zoomAndCentreMapToBounds) ====

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
-- Session cache: one initialised map per player, reused across tab rebuilds.
-- The caller (LSTab) is responsible for re-parenting it into the live content
-- area. Returns an *initialised, instantiated* LSMap.
-- ---------------------------------------------------------------------------
function LSMap.acquire(player, w, h)
    local pi = player:getPlayerNum()
    local inst = LSMap.instances[pi]
    if inst and inst._initialised then
        inst:setMapSize(w, h)
        return inst
    end

    inst = LSMap:new(0, 0, w, h, player)
    inst:initialise()     -- runs createChildren -> initMap
    inst:instantiate()
    LSMap.instances[pi] = inst
    return inst
end

-- Drop the cached instance (e.g. on player death / disconnect) so it rebuilds.
function LSMap.forget(playerIndex)
    LSMap.instances[playerIndex] = nil
end

-- Dragonfly Longstrider v0.3.0
