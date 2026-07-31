-- RLServer.lua - Reliquary: the server-authoritative engine.
--
-- Every mutation of the world lives here; the client only asks. Commands
-- arrive through RDNet, which owns the mod's single OnClientCommand listener
-- and has already done three things before a handler runs: confirmed the
-- command is registered at all, held it to its rate limit, and checked the
-- caller's capability. An unregistered or over-rate or under-privileged
-- command never reaches this file, and the rejection is recorded in the
-- "rdnet" forensic stream with the sender's name attached.
--
-- This mod is RDNet's first satellite adoption - before it, the dispatcher
-- protected Core's own token and nothing else. It is also why the handlers
-- below reply for themselves: RDNet is a permission wall, not an RPC
-- framework, so a handler that wants to be heard says so explicitly. The
-- shape is one line per exit, which reads better than the old auto-reply
-- anyway (it is obvious here which failures are silent, because none are).
--
-- Beyond the reply, a Reliquary keeps its OWN file log (RFTDReliquary_Audit
-- .txt) recording every place/fill/in/out/dissolve with quantities. That log
-- answers a question the chronicle cannot: not "did staff spawn items" - that
-- is Guardian's job - but "which of these items reached the player it was
-- meant for, and when did they take them".

if not isServer() then return end

require "RDNet"
require "OEShared"
require "Reliquary/RLShared"

Reliquary = Reliquary or {}
local RL = Reliquary

-- Live registry of loaded Reliquaries, keyed by RL.keyFor(x,y,z):
--   { obj = IsoObject, x,y,z, snap = {fulltype=count}, filled = bool }
-- Repopulated on LoadGridsquare, so it survives restarts (the object itself
-- persists in the chunk; only this index is volatile).
local boxes = {}

-- ---------------------------------------------------------------------------
-- Dedicated file audit log
-- ---------------------------------------------------------------------------

local function stamp()
    return tostring(getTimestampMs and getTimestampMs() or 0)
end

local function flog(action, actor, key, detail)
    pcall(function()
        local w = getFileWriter(RL.LOGFILE, true, true) -- createIfNull, append (never truncate)
        if w then
            w:write("[" .. stamp() .. "] " .. action ..
                    " actor=" .. tostring(actor or "?") ..
                    " box=" .. tostring(key) ..
                    "  " .. tostring(detail or "") .. "\r\n")
            w:close()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function contains(t, v)
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end

-- Snapshot a container's contents as {fulltype = count}.
local function snapshot(cont)
    local snap, items = {}, cont:getItems()
    for i = 0, items:size() - 1 do
        local ft = items:get(i):getFullType()
        snap[ft] = (snap[ft] or 0) + 1
    end
    return snap
end

-- Best-effort actor for a manual in/out: nearest online player within 3 tiles
-- on the same level. A guess, and labelled as one in the log by never being
-- the sole record - admin fills are logged exactly, from the command.
local function nearestPlayer(x, y, z)
    local players = getOnlinePlayers and getOnlinePlayers() or nil
    if not players then return nil end
    local best, bestD = nil, 9.0
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and math.floor(p:getZ()) == z then
            local dx, dy = p:getX() - (x + 0.5), p:getY() - (y + 0.5)
            local d = dx * dx + dy * dy
            if d < bestD then best, bestD = p, d end
        end
    end
    return best and best:getUsername() or nil
end

-- Find the Reliquary IsoObject (and its modData) on a square, or nil.
local function findBox(sq)
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local d = RL.getData(o)
        if d then return o, d end
    end
    return nil
end

local function squareFor(args)
    return getCell() and getCell():getGridSquare(args.x, args.y, args.z) or nil
end

-- World clock in hours. getGameTime():getWorldAgeHours() is GameTime.java:829
-- and is what vanilla itself uses from Lua (ISButtonPrompt.lua:520). Stored
-- absolute rather than as a countdown so it survives restarts without anyone
-- having to tick it down.
local function nowHours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    return ok and h or 0
end

local function expired(d)
    return d and d.expiresAt and nowHours() >= d.expiresAt
end

-- A Reliquary is bound to the tile it was placed on. Anything that relocates
-- it destroys it, contents and all.
--
-- This is the AUTHORITATIVE half of "the player cannot move it" - the client
-- also refuses to offer the pickup, but that is a courtesy and this is the
-- rule. Deliberately destroy-on-move rather than block-every-move: blocking
-- means enumerating every route by which an object can be relocated, now and
-- in every future build, and missing one silently grants what the whole design
-- forbids. Destroying needs only to notice that the tile changed.
local function moved(obj, d)
    if not d or not d.origin then return false end
    local ok, differs = pcall(function()
        local sq = obj:getSquare()
        if not sq then return false end
        return sq:getX() ~= d.origin.x or sq:getY() ~= d.origin.y or sq:getZ() ~= d.origin.z
    end)
    return ok and differs == true
end

local function register(obj, x, y, z)
    if not RL.getData(obj) then return end
    local key = RL.keyFor(x, y, z)
    local cont = obj:getContainer()
    local d = RL.getData(obj)
    boxes[key] = {
        obj = obj, x = x, y = y, z = z,
        filled = d.filled and true or false,
        snap = cont and snapshot(cont) or {},
    }
end

-- ---------------------------------------------------------------------------
-- Replies. Same {ok, action, message/reason} shape Dragonfly's Result events
-- use, so the client half is a five-line listener rather than a protocol.
-- ---------------------------------------------------------------------------

local function ok(player, action, message)
    RDNet.reply(player, OEShared.MODULE, "Result", { ok = true, action = action, message = message })
end

local function deny(player, action, reason)
    RDNet.reply(player, OEShared.MODULE, "Result", { ok = false, action = action, reason = reason })
end

-- ---------------------------------------------------------------------------
-- Commands
--
-- Registered at file scope, unconditionally. The old build deferred this to
-- OnServerStarted and skipped registration entirely when the sandbox switch
-- was off; both are gone. Deferral existed because Dragonfly's dispatcher
-- might not have loaded yet, which RDNet - a shared/ file, loaded before every
-- server/ file on both the dedi and the client - cannot be. And a command
-- registered-but-disabled says "off" to the caller, where an unregistered one
-- says nothing and lands in the forensic stream as an injection attempt.
--
-- Capability is given as the STRING "AddItem", not Capability.AddItem: the
-- engine enum is not reliably populated this early, and RDAccess resolves the
-- name at check time, which is well after boot.
-- ---------------------------------------------------------------------------

local CAP  = "AddItem"     -- the gate Dragonfly uses for its item-spawn handlers
local DOWN = "Reliquary is switched off on this server."

-- NOT DEAD CODE, despite having no caller since 2026-07-30. The client's
-- "Place Reliquary here" option was removed before the first Workshop push -
-- placement is to become a spawned item placed deliberately, and this handler
-- is what that item will call. Registered and gated exactly as before, so the
-- item is a client-side change only. Deleting it would mean rebuilding it.
RDNet.register(OEShared.MODULE, "reliquaryPlace", { capability = CAP, rate = 5 }, function(player, args)
    if not RL.isEnabled() then return deny(player, "reliquaryPlace", DOWN) end
    args = args or {}
    local sq = squareFor(args)
    if not sq then return deny(player, "reliquaryPlace", "Invalid square.") end
    if findBox(sq) then return deny(player, "reliquaryPlace", "A Reliquary is already here.") end

    local obj = IsoObject.new(sq, RL.SPRITE)
    sq:AddSpecialObject(obj)
    sq:RecalcAllWithNeighbours(true)

    local cont = ItemContainer.new(RL.CONTAINER_TYPE, sq, obj)
    cont:setExplored(true)          -- engine never rolls loot into it
    cont:setCapacity(RL.CAPACITY)   -- bottomless
    obj:setContainer(cont)

    local whitelist = tostring(args.whitelist or "")
    local hours = tonumber(args.hours) or RL.defaultHours()
    obj:getModData()[RL.MODKEY] = {
        whitelist = whitelist,
        filled = false,
        owner = player:getUsername(),
        -- The tile it belongs to. Any later disagreement with this is a move,
        -- and a move is fatal.
        origin = { x = args.x, y = args.y, z = args.z },
        -- 0 or less means "no expiry" - a Reliquary that waits indefinitely.
        expiresAt = (hours > 0) and (nowHours() + hours) or nil,
    }
    obj:transmitModData()
    obj:transmitCompleteItemToClients() -- mirrors vanilla build: push the new object to clients

    register(obj, args.x, args.y, args.z)
    flog("PLACE", player:getUsername(), RL.keyFor(args.x, args.y, args.z),
         "whitelist=" .. (whitelist ~= "" and whitelist or "<staff-only>"))
    ok(player, "reliquaryPlace", "Reliquary placed" ..
       (whitelist ~= "" and (" (access: " .. whitelist .. " + staff).") or " (staff only)."))
end)

RDNet.register(OEShared.MODULE, "reliquarySetPlayer", { capability = CAP, rate = 5 }, function(player, args)
    if not RL.isEnabled() then return deny(player, "reliquarySetPlayer", DOWN) end
    args = args or {}
    local sq = squareFor(args)
    if not sq then return deny(player, "reliquarySetPlayer", "Invalid square.") end
    local obj, data = findBox(sq)
    if not obj then return deny(player, "reliquarySetPlayer", "No Reliquary on that tile.") end

    data.whitelist = tostring(args.whitelist or "")
    obj:transmitModData()
    flog("ADDRESS", player:getUsername(), RL.keyFor(args.x, args.y, args.z),
         "whitelist=" .. (data.whitelist == "" and "<staff-only>" or data.whitelist))
    ok(player, "reliquarySetPlayer", data.whitelist == "" and "Access set to staff-only."
        or ("Access granted to: " .. data.whitelist .. " (+ staff)."))
end)

RDNet.register(OEShared.MODULE, "reliquarySetTimer", { capability = CAP, rate = 5 }, function(player, args)
    if not RL.isEnabled() then return deny(player, "reliquarySetTimer", DOWN) end
    args = args or {}
    local sq = squareFor(args)
    if not sq then return deny(player, "reliquarySetTimer", "Invalid square.") end
    local obj, data = findBox(sq)
    if not obj then return deny(player, "reliquarySetTimer", "No Reliquary on that tile.") end

    local hours = tonumber(args.hours) or 0
    data.expiresAt = (hours > 0) and (nowHours() + hours) or nil
    obj:transmitModData()
    flog("TIMER", player:getUsername(), RL.keyFor(args.x, args.y, args.z),
         hours > 0 and (hours .. "h") or "never")
    ok(player, "reliquarySetTimer", hours > 0
        and ("Reliquary expires in " .. hours .. " hour(s).")
        or "Reliquary will not expire.")
end)

RDNet.register(OEShared.MODULE, "reliquaryFill", { capability = CAP, rate = 2 }, function(player, args)
    if not RL.isEnabled() then return deny(player, "reliquaryFill", DOWN) end
    args = args or {}
    local sq = squareFor(args)
    if not sq then return deny(player, "reliquaryFill", "Invalid square.") end
    local obj, data = findBox(sq)
    if not obj then return deny(player, "reliquaryFill", "No Reliquary on that tile.") end
    local cont = obj:getContainer()
    if not cont then return deny(player, "reliquaryFill", "That Reliquary has no container.") end

    local added = ArrayList.new()
    local bad, total, capped = {}, 0, false
    for _, e in ipairs(args.entries or {}) do
        if total >= RL.MAX_PER_FILL then capped = true; break end
        local first = cont:AddItem(e.type) -- nil for unknown fulltypes
        if not first then
            table.insert(bad, e.type)
        else
            added:add(first); total = total + 1
            for _ = 2, e.qty do
                if total >= RL.MAX_PER_FILL then capped = true; break end
                local it = cont:AddItem(e.type)
                if it then added:add(it); total = total + 1 end
            end
        end
    end

    if added:size() > 0 then
        sendAddItemsToContainer(cont, added) -- engine MP add-sync path
        data.filled = true
        obj:transmitModData()
        local key = RL.keyFor(args.x, args.y, args.z)
        if boxes[key] then boxes[key].filled = true; boxes[key].snap = snapshot(cont) end
        -- Exact provenance: each accepted line logged with the known actor.
        for _, e in ipairs(args.entries or {}) do
            if not contains(bad, e.type) then
                flog("FILL", player:getUsername(), key, e.qty .. "x " .. e.type)
            end
        end
    end

    local msg = "Added " .. total .. " item(s)."
    if capped then msg = msg .. " (hit " .. RL.MAX_PER_FILL .. " cap)" end
    if #bad > 0 then msg = msg .. " Unknown: " .. table.concat(bad, ", ") end
    ok(player, "reliquaryFill", msg)
end)

-- ---------------------------------------------------------------------------
-- Discovery: re-register Reliquaries as their chunks load (survives restarts)
-- ---------------------------------------------------------------------------

local function onLoadGridsquare(sq)
    if not sq or not RL.isEnabled() then return end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        if RL.getData(obj) then register(obj, sq:getX(), sq:getY(), sq:getZ()) end
    end
end
Events.LoadGridsquare.Add(onLoadGridsquare)

-- ---------------------------------------------------------------------------
-- Throttled poll: log manual in/out, and dissolve a Reliquary once emptied
-- ---------------------------------------------------------------------------

local POLL_TICKS = 20 -- ~1/3s; responsive for audit + dissolve, cheap for a handful of boxes
local tick = 0

local function poll()
    if not RL.isEnabled() then return end
    tick = tick + 1
    if tick < POLL_TICKS then return end
    tick = 0

    for key, box in pairs(boxes) do
        local obj = box.obj
        local cont = obj and obj:getContainer()
        local d = obj and RL.getData(obj)
        if not obj or not cont or not obj:getSquare() then
            boxes[key] = nil -- gone/unloaded; LoadGridsquare re-registers if it returns
        elseif moved(obj, d) or expired(d) then
            -- Both are terminal and both take the contents with them: a moved
            -- Reliquary was tampered with, an expired one was not collected in
            -- time. Logged distinctly so the audit says which.
            flog(moved(obj, d) and "MOVED" or "EXPIRED",
                 nearestPlayer(box.x, box.y, box.z), key,
                 "destroyed with " .. tostring(cont:getItems():size()) .. " item(s)")
            pcall(function() cont:removeAllItems() end)
            obj:getSquare():transmitRemoveItemFromSquare(obj)
            boxes[key] = nil
        else
            local now = snapshot(cont)
            local actor
            -- Diff vs last snapshot: positive => IN, negative => OUT. Captures
            -- manual transfers by any authorized player (admin fills are
            -- already logged exactly, above).
            for ft, n in pairs(now) do
                local was = box.snap[ft] or 0
                if n > was then
                    actor = actor or nearestPlayer(box.x, box.y, box.z)
                    flog("IN", actor, key, (n - was) .. "x " .. ft)
                end
            end
            for ft, was in pairs(box.snap) do
                local n = now[ft] or 0
                if was > n then
                    actor = actor or nearestPlayer(box.x, box.y, box.z)
                    flog("OUT", actor, key, (was - n) .. "x " .. ft)
                end
            end
            box.snap = now

            if cont:getItems():size() > 0 then
                if not box.filled then
                    box.filled = true
                    local d = RL.getData(obj); if d then d.filled = true; obj:transmitModData() end
                end
            elseif box.filled then
                -- Dissolves when it is AGAIN empty: only after it has held
                -- something, so a freshly placed and not-yet-filled Reliquary
                -- survives the walk back to the admin panel.
                flog("DISSOLVE", actor, key, "emptied -> removed")
                obj:getSquare():transmitRemoveItemFromSquare(obj)
                boxes[key] = nil
            end
        end
    end
end
Events.OnTick.Add(poll)

Events.OnServerStarted.Add(function()
    if not RL.isEnabled() then
        print("[RFTDOddsAndEnds] Reliquary disabled via sandbox (ReliquaryEnable); commands will answer 'switched off'")
    end
end)

print("[RFTDOddsAndEnds] Reliquary server loaded.")
