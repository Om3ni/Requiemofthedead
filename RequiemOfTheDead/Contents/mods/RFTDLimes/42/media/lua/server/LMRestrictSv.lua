-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMRestrictSv.lua - the restriction flags, enforced where the engine lets us (server).
--
-- LMCore has declared eight `no*` flags since the import, every one carrying a
-- note admitting nothing read them. This is the module that reads them. No new
-- vocabulary, no new option, no second way to say the same thing.
--
-- HONESTY IS THE DESIGN. Three tiers, and which tier a flag gets is decided by
-- the engine, not by how much we would like it to be enforced:
--
--   S  server-authoritative - a real veto. The action does not happen.
--   R  post-hoc revert      - it happens, the server notices and undoes it.
--   C  client-cooperative   - honest clients comply, hacked clients are logged.
--
-- A flag must never look stronger than it is. `nodestruction` cannot be vetoed
-- by any mod in 42.20.2, and pretending otherwise on a panel is how an admin
-- builds a policy on top of nothing. Each flag's tier is stated in its help
-- text, and LMCore drops the NOT_YET note only for the ones that landed.
--
-- WHAT THE VERIFICATION PASS CHANGED (2026-08-06). §7.2 of the design doc had
-- researched every mechanism, and re-checking it against 42.20.2 before writing
-- - after §7.3 turned out to prescribe an idiom Lua cannot reach - moved three
-- flags UP a tier and confirmed the rest:
--
--   * `nopickup`/`noplacing`/`noscrap` were filed C+R on the grounds that the
--     OnProcessTransaction events are void. They are - but the events are not
--     the execution point. The server's handlers perform the mutation through
--     ISMoveableSpriteProps (a global shared-Lua class), and wrapping ITS
--     methods refuses the action outright. That is a veto, so these are S.
--     (First attempt wrapped vanilla's `Transactions` dispatch table, which
--     turned out to be a file-LOCAL - the install report caught it; see the
--     moveables block below.)
--   * `nobuilding` was already S, and its mechanism is simpler than described:
--     `Actions.build` (shared/ActionManager.lua) is likewise a global Lua
--     function that calls item:create(args.x, args.y, args.z, ...). We never
--     need to touch the packet layer.
--   * `nofire` campfire ignition goes through `SCampfireSystemCommand`, another
--     global server Lua function, with x/y/z in args. S, as documented.
--
-- THE WRAPS LIVE HERE, NEVER AS EDITS TO THE GAME'S FILES - the same idiom
-- LMDirge uses to take over Dirge's rules from this side. Each wrap keeps the
-- original in an upvalue and calls it unless a zone says no, so deleting this
-- file restores vanilla behaviour exactly, with no edit anywhere else.
--
-- INSTALLED DEFERRED AND IDEMPOTENTLY, for the reason LMDirge documents: load
-- order decides whether the game's file has been parsed yet, and the server's
-- mod list is not ours to assume. Wrap at load, retry on boot, and never wrap
-- twice.

if not isServer() then return end

require "LMCore"
require "LMRestrictShared"
require "RDNet"

LMRestrict = LMRestrict or {}

local TOKEN = "RFTDLimes"

-- ---------------------------------------------------------------------------
-- The question every wrap asks
-- ---------------------------------------------------------------------------

-- Is `flag` set on the zone covering this tile? Returns the zone name too, so a
-- refusal can say WHICH zone refused - "you cannot build here" invites an
-- argument, "Sunstar Motel does not allow building" ends it.
--
-- Reads the RESOLVED store, so a child zone inherits its parent's restrictions
-- exactly the way every other field inherits.
-- Shared with LMRestrictCl - see shared/LMRestrictShared.lua.
local denied = LMRestrictShared.denied

-- Every veto below reads coordinates off the TARGET square, never off the
-- acting character. That is deliberate: a player can stand outside a zone and
-- act on a square inside it, so an actor-position test enforces the flag in the
-- wrong place. An actor-position helper sat here unused until 2026-08-27; if a
-- future veto genuinely has no target coordinates, the choice has to be made
-- and stated at that call site rather than reached for silently.

-- ---------------------------------------------------------------------------
-- Refusal
-- ---------------------------------------------------------------------------

local counts = {}   -- flag -> refusals since boot, for the report

-- No guard. "Evidence-writing must never break the refusal it records" was a
-- real concern about ORDER, answered by a guard instead of by order - and it
-- does not arise, because RDLog.forensic cannot throw: envelope() is
-- RDJson.encode (total for any payload, RDJson.lua:103-139) and every write
-- lands on getFileWriter, which returns nil rather than throwing
-- (LuaManager.java:5523-5555), through a PrintWriter that records I/O errors
-- internally (:9850-9868). Core calls the same primitive bare
-- (RDLog.lua:192-198). The presence check stays as an ordinary load-order
-- precondition.
local function forensic(event, data, subject)
    if RDLog and RDLog.forensic then
        RDLog.forensic("limes", event, subject, data, "RFTDLimes")
    end
end

-- Tell the player, and say which zone and which rule. A refusal nobody explains
-- is indistinguishable from the game being broken - the player repeats the
-- action, it fails again, and the server looks unreliable rather than
-- administered.
local function refuse(character, flag, zoneName, what)
    counts[flag] = (counts[flag] or 0) + 1
    -- No guard - there is no wire failure to contain. RDNet.reply is a
    -- one-line delegation to sendServerCommand, which returns silently for a
    -- dropped or unmapped connection (GameServer.java:3264-3274), logs and
    -- skips unserializable payload entries, and catches its own IOException
    -- (:3196-3215). Nothing on this path can throw back into the wrapped
    -- vanilla global.
    RDNet.reply(character, TOKEN, "restricted", {
        flag = flag, zone = zoneName, what = what,
    })
    -- `character` is whatever the wrapped handler was given, so the method is
    -- tested rather than assumed - indexing an absent method is safe, calling
    -- one is not. getUsername itself is a field return (IsoGameCharacter).
    local who = "?"
    if character and character.getUsername then who = character:getUsername() end
    forensic("LM.RESTRICT", { flag = flag, zone = zoneName, user = who, what = what }, character)
end

function LMRestrict.counts() return counts end

-- ---------------------------------------------------------------------------
-- S - the vetoes
--
-- Every one of these takes over a global the GAME defines, so each guards
-- against the global not existing yet (load order) and against being applied
-- twice (boot retry). `installed` is keyed by name rather than by a single
-- boolean, because a server missing one of these files should still get the
-- others.
-- ---------------------------------------------------------------------------

local installed = {}

-- nobuilding. Actions.build creates the object itself and carries the target
-- square in args, so this refuses at the TARGET tile - the correct place, and
-- better than the actor's own position: a player standing outside the boundary
-- building through it is exactly the case a boundary is for.
local function wrapBuild()
    if installed.build or type(Actions) ~= "table" or type(Actions.build) ~= "function" then
        return false
    end
    local original = Actions.build
    Actions.build = function(character, args)
        local x = args and args.x
        local y = args and args.y
        local no, zone = denied(x, y, "nobuilding")
        if no then
            refuse(character, "nobuilding", zone, "build")
            return          -- the object is simply never created
        end
        return original(character, args)
    end
    installed.build = true
    return true
end

-- nopickup / noplacing / noscrap - the moveables funnel, CORRECTED 2026-08-07.
--
-- The first build wrapped vanilla's `Transactions` dispatch table, and the
-- boot line said what happened: "vetoes installed [build campfire]" - the
-- table is a LOCAL in server/TransactionProcessor.lua, unreachable from any
-- other file, so the wrap never installed and the three flags enforced
-- nothing. (The loud install report exists precisely to catch this class of
-- assumption; it did.)
--
-- The reachable seam is one level down: the handlers do their mutation
-- through ISMoveableSpriteProps - a GLOBAL shared-Lua class - calling
-- :pickUpMoveableViaCursor / :placeMoveableViaCursor / :scrapObjectViaCursor
-- on an instance built via fromObject(). Wrapping the CLASS methods reaches
-- every instance (colon methods live in the class table), and since this
-- file is server-only the wrap exists only where the server executes
-- transactions - client-side cursor previews are untouched.
--
-- The square: fromObject() stores the source object as self.object
-- (ISMoveableSpriteProps.lua:29-35), which covers pickup and scrap - the
-- server handler passes _square = nil for scrap, so the object IS the only
-- source of truth there. Placement acts on the DESTINATION square, which
-- arrives as the _square argument. No square means no opinion: a shape this
-- file cannot locate is allowed through, because a restriction that fires on
-- "I could not tell" blocks ordinary play wherever the engine's shapes
-- drift.
local function coordsOfMove(self, square)
    -- self.object's concrete class is the handler's business, so getSquare is
    -- tested rather than assumed; on the classes that do carry it it is a field
    -- return (IsoObject:1126, IsoMovingObject:534), as are IsoGridSquare's
    -- getX/getY (:6331/:6335). No guard left to buy.
    local sq = square
    if not sq and self and self.object and self.object.getSquare then
        sq = self.object:getSquare()
    end
    if not sq then return nil, nil end
    return sq:getX(), sq:getY()
end

local function wrapMoveable(method, flag, action)
    local key = "mv_" .. action
    if installed[key] or type(ISMoveableSpriteProps) ~= "table"
        or type(ISMoveableSpriteProps[method]) ~= "function" then
        return false
    end
    local original = ISMoveableSpriteProps[method]
    ISMoveableSpriteProps[method] = function(self, character, square, ...)
        local x, y = coordsOfMove(self, square)
        if x then
            local no, zone = denied(x, y, flag)
            if no then
                refuse(character, flag, zone, action)
                return
            end
        end
        return original(self, character, square, ...)
    end
    installed[key] = true
    return true
end

-- nofire, the ignition half. SCampfireSystemCommand is one global function
-- handling every campfire command; only lighting is a fire, so the wrap is
-- surgical - addFuel and removeCampfire are not restricted by a fire flag.
local function wrapCampfire()
    if installed.campfire or type(SCampfireSystemCommand) ~= "function" then return false end
    local original = SCampfireSystemCommand
    SCampfireSystemCommand = function(command, player, args)
        if command == "lightFire" and args then
            local no, zone = denied(args.x, args.y, "nofire")
            if no then
                refuse(player, "nofire", zone, "lightFire")
                return
            end
        end
        return original(command, player, args)
    end
    installed.campfire = true
    return true
end

-- ---------------------------------------------------------------------------
-- R - the reverts
-- ---------------------------------------------------------------------------

-- nofire, the backstop. Everything that is not a campfire - spread, molotovs,
-- cooking gone wrong - has no veto, but OnNewFire fires server-side in the
-- IsoFire constructor (IsoFire:251), and IsoFireManager.Remove is Lua-exposed.
-- So a fire that starts inside a nofire zone is put out on the same tick it
-- appears. That is a revert and not a veto, and the distinction is visible: a
-- player may see a flame for an instant.
local function onNewFire(fire)
    if not fire then return end
    local sq = fire:getSquare()
    if not sq then return end
    local x, y = sq:getX(), sq:getY()
    local no, zone = denied(x, y, "nofire")
    if not no then return end
    -- No guard: IsoFireManager.Remove:166 is a contains-then-remove on a static
    -- final ArrayList (:64) and returns early on an unknown fire.
    IsoFireManager.Remove(fire)
    counts.nofire = (counts.nofire or 0) + 1
    forensic("LM.RESTRICT", { flag = "nofire", zone = zone, what = "extinguish" })
end

-- nosafehouse. No pre-claim hook exists - SafehouseClaimPacket.processServer
-- goes straight to SafeHouse.canBeSafehouse in Java (:72-83) - so this is a
-- post-hoc revert: SafeHouse.removeSafeHouse is Lua-exposed, and a claim
-- landing inside a nosafehouse zone is taken back.
--
-- IT IS DRIVEN BY THE CLOCK, NOT BY THE EVENT. OnSafehousesChanged looked
-- like the trigger and is not: BOTH of its trigger sites in SafeHouse.java
-- are wrapped in `if (GameClient.client)` (:82-84 add, :301-303 remove), and
-- the third (SafehouseSyncPacket:95) is inside processClient. GameClient.client
-- is false on a dedicated server, so the event NEVER fires there and this
-- whole veto silently did nothing on the only kind of server that matters -
-- shipped that way until a claim went through on live ground, 2026-08-29.
-- OnPlayerSetSafehouse is not an escape either: LuaEventManager registers it
-- (:708) and no engine code ever triggers it.
--
-- So EveryOneMinute drives the sweep. It is triggered unconditionally in
-- GameTime.update (GameTime.java:589), on the same path that syncs the server
-- clock two lines later, so it runs on a dedicated server. The event
-- registration stays for the client-hosted and single-player cases, where it
-- does fire and makes the revert immediate.
--
-- CHECKED AS A RECTANGLE, not as a square, and the five-point test now lives
-- in LMRestrictShared.rectDenied. It moved there when the client learned to
-- refuse a claim before sending it: that half tests the rect a claim WOULD
-- create and this one tests the rect a claim DID create, and the two must be
-- the same test or a player gets refused on ground the server would have
-- allowed, or vice versa.
local function safehouseDenied(sh)
    return LMRestrictShared.rectDenied(sh:getX(), sh:getY(), sh:getW(), sh:getH(),
        "nosafehouse")
end

-- Tell every client to drop the row too.
--
-- SafeHouse.removeSafeHouse takes the claim out of the SERVER's list and
-- notifies nobody: its only trigger is a LuaEventManager call behind
-- `if (GameClient.client)`, false here (SafeHouse.java:297-303). Vanilla never
-- removes server-side without a packet beside it - hitPoint pairs removal with
-- sendToAll(SafehouseRelease) (:742-743) and the expiry sweep does the same
-- (:801-802) - but that layer is unreachable from Lua: neither INetworkPacket
-- nor PacketTypes has a setExposed entry, and every sendSafehouse* global is
-- wrapped in `if (GameClient.client)` (LuaManager.java:4311-4372), so all of
-- them are no-ops on a dedicated server.
--
-- Without this the reverted claim survives on every connected client: the
-- owner still sees it, the admin panel still lists it, and client-side
-- safehouse logic (Core's own destroy patch among it) still reads the ground
-- as claimed - until a relog rebuilds the list from MetaDataPacket (:36-37).
-- That is a desync, not a cosmetic one: the client refuses actions the server
-- would allow.
--
-- The id is safe to send because it is DERIVED, not allocated: the constructor
-- sets onlineId from the rectangle's coordinates (SafeHouse.java:519), so the
-- same claim carries the same id on every machine and each client can resolve
-- its own copy. Read it before the removal - the row is what names it.
local function dropOnClients(onlineId)
    if not onlineId then return end
    RDNet.broadcast(TOKEN, "safehouseGone", { id = onlineId })
end

-- The owner as an online player object, or nil. getPlayerFromUsername is NOT
-- the way: its body is GameClient.instance.getPlayerFromUsername
-- (LuaManager.java:7370-7372) and GameClient.instance is null on a dedicated
-- server, so it answers nil there for every name. getOnlinePlayers branches on
-- GameServer.server and returns GameServer.getPlayers() (:3823-3832).
local function tellOwner(owner, zoneName)
    if not owner or owner == "" or owner == "null" then return end
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p.getUsername and p:getUsername() == owner then
            RDNet.reply(p, TOKEN, "restricted",
                { flag = "nosafehouse", zone = zoneName, what = "claim" })
            return
        end
    end
end

local function onSafehousesChanged()
    local list = SafeHouse.getSafehouseList()
    if not list then return end
    local n = list:size()
    -- Backwards: removeSafeHouse mutates the very list being walked.
    for i = n - 1, 0, -1 do
        local sh = list:get(i)
        if sh then
            local no, zone = safehouseDenied(sh)
            if no then
                local owner = sh:getOwner() or "?"
                -- Read before the removal: this is the only handle the clients
                -- have on the row, and it is a plain field return (:702-704).
                local onlineId = sh:getOnlineID()
                -- No guard - the old comment was wrong on both halves.
                -- The debug line reads four plain fields (a null owner formats
                -- as "null", never .equals - SafeHouse.java:297-303, :586-588)
                -- and the OnSafehousesChanged re-trigger is inside
                -- if (GameClient.client), which is false on a dedicated
                -- server (:300-302). Server-side there is no throw path at
                -- all. The backwards index walk stays load-bearing:
                -- getSafehouseList returns the LIVE list (:582-584) and
                -- removal shifts every index above the removed row.
                SafeHouse.removeSafeHouse(sh)
                counts.nosafehouse = (counts.nosafehouse or 0) + 1
                forensic("LM.RESTRICT",
                    { flag = "nosafehouse", zone = zone, user = owner, what = "unclaim" }, owner)
                print("[Limes] restrict: removed a safehouse claim by " .. tostring(owner)
                    .. " inside " .. tostring(zone))
                -- Every client, then the owner: the first is cache
                -- invalidation the engine will not do for us, the second is
                -- the explanation. A claim that vanishes with no explanation
                -- reads as the server eating your safehouse, so the owner
                -- gets the same "restricted" reply every other veto uses.
                dropOnClients(onlineId)
                tellOwner(owner, zone)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

local function install()
    wrapBuild()
    wrapMoveable("pickUpMoveableViaCursor", "nopickup",  "pickup")
    wrapMoveable("scrapObjectViaCursor",    "noscrap",   "scrap")
    wrapMoveable("placeMoveableViaCursor",  "noplacing", "place")
    wrapCampfire()
end

install()

if Events and Events.OnServerStarted then
    Events.OnServerStarted.Add(function()
        install()
        local names = {}
        for k in pairs(installed) do names[#names + 1] = k end
        table.sort(names)
        print("[Limes] LMRestrictSv: vetoes installed [" .. table.concat(names, " ") .. "]"
            .. " - nodestruction and noplayers are client-cooperative, see the panel")
    end)
end

-- No guard on either: Event.trigger runs every listener through
-- protectedCallVoid inside a per-listener try/catch (Event.java:53-63), so a
-- throw in one handler cannot break another listener on the event.
if Events and Events.OnNewFire then
    Events.OnNewFire.Add(function(fire) onNewFire(fire) end)
end
if Events and Events.OnSafehousesChanged then
    Events.OnSafehousesChanged.Add(function() onSafehousesChanged() end)
end
-- The dedicated server's only trigger - see the block above nosafehouse for
-- why the event alone left this veto dead there. One list walk per game
-- minute over getSafehouseList, which holds one row per claim on the whole
-- server: cheaper than the zone lookups it performs, and it runs whether or
-- not anyone claimed, which is the point.
if Events and Events.EveryOneMinute then
    Events.EveryOneMinute.Add(function() onSafehousesChanged() end)
end

-- ---------------------------------------------------------------------------
-- C - what the server can only watch
--
-- nodestruction and noplayers have no server veto in 42.20.2. The client half
-- gates the UI for honest clients; this end records what got through, so an
-- admin can see that a rule is being ignored rather than assuming it holds.
-- The report is the honest surface for a rule we cannot enforce.
-- ---------------------------------------------------------------------------

RDNet.register(TOKEN, "restrictReport", { capability = "any", rate = 4 }, function(player)
    local lines = {}
    for flag, n in pairs(counts) do lines[#lines + 1] = flag .. "=" .. n end
    table.sort(lines)
    RDNet.reply(player, TOKEN, "notice", {
        ok = true,
        msg = #lines > 0 and ("restrictions since boot: " .. table.concat(lines, " "))
              or "no restriction has fired since boot",
    })
end)

return LMRestrict

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
