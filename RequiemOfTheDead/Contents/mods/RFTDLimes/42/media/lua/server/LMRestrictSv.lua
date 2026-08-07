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
--     the execution point. `Transactions.pickUpMoveable`, `placeMoveable` and
--     `scrapMoveable` are GLOBAL LUA FUNCTIONS in the game's own
--     server/TransactionProcessor.lua, guarded by `if isClient() then return
--     end`, and they perform the mutation themselves. Taking one over refuses
--     the action outright. That is a veto, so these are S.
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
local function denied(x, y, flag)
    if not x or not y then return false, nil end
    local ok, zone = pcall(Limes.getLocation, math.floor(x), math.floor(y))
    if not ok or not zone or not zone.fields then return false, nil end
    if zone.fields[flag] == true then return true, zone.name end
    return false, nil
end

-- Where a character is standing, when the action carries no coordinates of its
-- own. Second best and always noted as such: a player can stand outside a zone
-- and act on a square inside it, so a flag enforced this way is enforced at the
-- ACTOR rather than at the TARGET.
local function at(character)
    if not character then return nil, nil end
    local x, y
    local ok = pcall(function() x, y = character:getX(), character:getY() end)
    if not ok or not x then return nil, nil end
    return x, y
end

-- ---------------------------------------------------------------------------
-- Refusal
-- ---------------------------------------------------------------------------

local counts = {}   -- flag -> refusals since boot, for the report

local function forensic(event, data)
    if RDLog and RDLog.forensic then pcall(RDLog.forensic, event, data) end
end

-- Tell the player, and say which zone and which rule. A refusal nobody explains
-- is indistinguishable from the game being broken - the player repeats the
-- action, it fails again, and the server looks unreliable rather than
-- administered.
local function refuse(character, flag, zoneName, what)
    counts[flag] = (counts[flag] or 0) + 1
    pcall(function()
        RDNet.reply(character, TOKEN, "restricted", {
            flag = flag, zone = zoneName, what = what,
        })
    end)
    local who = "?"
    pcall(function() who = character:getUsername() end)
    forensic("LM.RESTRICT", { flag = flag, zone = zoneName, user = who, what = what })
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

-- nopickup / noplacing / noscrap. The moveables funnel. Each of these three
-- reads its square from a DIFFERENT place, which is why they are not one loop:
-- pickup and scrap act on the SOURCE object's square, placing acts on the
-- DESTINATION's. Getting that backwards would enforce the flag on the wrong
-- tile and only show up when someone drags furniture across a boundary.
local function squareOfContainer(cont)
    local sq = nil
    pcall(function()
        local obj = cont and cont:getObject()
        sq = obj and obj:getSquare()
    end)
    return sq
end

local function coordsOf(sq)
    if not sq then return nil, nil end
    local x, y
    local ok = pcall(function() x, y = sq:getX(), sq:getY() end)
    if not ok then return nil, nil end
    return x, y
end

local function wrapTransaction(action, flag, pickSquare)
    local key = "tx_" .. action
    if installed[key] or type(Transactions) ~= "table"
        or type(Transactions[action]) ~= "function" then
        return false
    end
    local original = Transactions[action]
    Transactions[action] = function(character, item, source, destination, args)
        local x, y = coordsOf(pickSquare(source, destination))
        -- No square means no opinion. A transaction this file cannot locate is
        -- allowed through rather than refused: a restriction that fires on
        -- "I could not tell" would block ordinary play wherever the shape of a
        -- transaction is not what we expected.
        if x then
            local no, zone = denied(x, y, flag)
            if no then
                refuse(character, flag, zone, action)
                return
            end
        end
        return original(character, item, source, destination, args)
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
    local x, y
    local ok = pcall(function()
        local sq = fire:getSquare()
        if sq then x, y = sq:getX(), sq:getY() end
    end)
    if not ok or not x then return end
    local no, zone = denied(x, y, "nofire")
    if not no then return end
    pcall(function() IsoFireManager.Remove(fire) end)
    counts.nofire = (counts.nofire or 0) + 1
    forensic("LM.RESTRICT", { flag = "nofire", zone = zone, what = "extinguish" })
end

-- nosafehouse. No pre-claim hook exists - SafehouseClaimPacket goes straight to
-- SafeHouse.canBeSafehouse in Java - but OnSafehousesChanged fires server-side
-- after the fact and SafeHouse.removeSafeHouse is Lua-exposed, so a claim
-- landing inside a nosafehouse zone is undone immediately.
--
-- CHECKED BY CORNERS, not by centre. A safehouse is a rectangle and the zone is
-- a rectangle; a claim that overlaps the zone at all is a claim on protected
-- ground, and testing only the middle would let someone claim a building whose
-- back half sits inside the boundary.
local function safehouseDenied(sh)
    local x, y, w, h
    local ok = pcall(function()
        x, y = sh:getX(), sh:getY()
        w, h = sh:getW(), sh:getH()
    end)
    if not ok or not x then return false, nil end
    local corners = {
        { x, y }, { x + w - 1, y }, { x, y + h - 1 }, { x + w - 1, y + h - 1 },
        { x + math.floor(w / 2), y + math.floor(h / 2) },
    }
    for i = 1, #corners do
        local no, zone = denied(corners[i][1], corners[i][2], "nosafehouse")
        if no then return true, zone end
    end
    return false, nil
end

local function onSafehousesChanged()
    local list = nil
    pcall(function() list = SafeHouse.getSafehouseList() end)
    if not list then return end
    local n = 0
    pcall(function() n = list:size() end)
    -- Backwards: removeSafeHouse mutates the very list being walked.
    for i = n - 1, 0, -1 do
        local sh = nil
        pcall(function() sh = list:get(i) end)
        if sh then
            local no, zone = safehouseDenied(sh)
            if no then
                local owner = "?"
                pcall(function() owner = sh:getOwner() end)
                pcall(function() SafeHouse.removeSafeHouse(sh) end)
                counts.nosafehouse = (counts.nosafehouse or 0) + 1
                forensic("LM.RESTRICT",
                    { flag = "nosafehouse", zone = zone, user = owner, what = "unclaim" })
                print("[Limes] restrict: removed a safehouse claim by " .. tostring(owner)
                    .. " inside " .. tostring(zone))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

local function install()
    wrapBuild()
    wrapTransaction("pickUpMoveable", "nopickup",  function(s, d) return squareOfContainer(s) end)
    wrapTransaction("scrapMoveable",  "noscrap",   function(s, d) return squareOfContainer(s) end)
    wrapTransaction("placeMoveable",  "noplacing", function(s, d) return squareOfContainer(d) end)
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

if Events and Events.OnNewFire then
    Events.OnNewFire.Add(function(fire) pcall(onNewFire, fire) end)
end
if Events and Events.OnSafehousesChanged then
    Events.OnSafehousesChanged.Add(function() pcall(onSafehousesChanged) end)
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
