-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMZeds.lua - the `zeds` field made real, and the census that proves it (server).
--
-- WHAT THIS ENFORCES. LMCore has declared `zeds` since the import, carrying its
-- own definition in the help text ("'remove' clears zombies standing in the
-- zone; 'none' stops them spawning") and the NOT_YET note admitting nothing read
-- it. This is the module named there. Nothing about the field changes - no new
-- option, no new vocabulary, no second way to say the same thing.
--
--   none     stop them spawning. Removed at birth, before the world sees them.
--   remove   the above, PLUS a standing sweep of anything already inside.
--   (blank)  the zone is left alone.
--
-- `remove` is deliberately a superset rather than a separate behaviour: a zombie
-- that materialises inside the zone IS "standing in the zone" one frame later,
-- so a mode that swept but let births through would need a second sweep to undo
-- what it just permitted. Suppress-at-birth is the cheap half of both modes and
-- the sweep is what distinguishes them.
--
-- WHY REMOVAL IS SILENT, and why that was not the first answer. The design
-- reflex is a visible kill - zombie::die() is the server-side idiom (the engine
-- itself branches that way in IsoZombie.onZombieGrappleEnded: setHealth(0) on
-- the client, die() on the server), and a body dropping is the zone proving
-- itself to anyone watching. That is right for an arena or a gated compound
-- under observation. It is wrong HERE, because the shipped use case is a walled
-- safe zone whose whole point is that zombies never appear inside it: die()
-- runs becomeCorpse() (IsoGameCharacter:13478), so every suppressed spawn would
-- leave an IsoDeadBody in somebody's base, persisted into chunk data, for a
-- zombie that should never have existed. A safehouse that slowly fills with
-- corpses is a worse bug than the one being fixed.
--
-- So removal is silent, and the CENSUS below is what replaces the visual proof.
-- That trade is the whole reason the census exists.
--
-- COEXISTENCE WITH REAPER, verified rather than assumed. Reaper is the suite's
-- zombie deleter and this file deletes zombies, which is a real hazard - except
-- that Reaper's newborn intake queues refs and resolves their OnlineIDs on
-- later ticks, and already handles the ref that never resolves: "A ref that
-- never resolves was removed before it mattered - drop it" (RPCore, processNewborns).
-- A zombie this file removes at birth is exactly that case. Reaper's books stay
-- straight with no coordination and no dependency in either direction.
--
-- The removal itself mirrors RPCore's cullZombie - removeFromSquare, then
-- removeFromWorld, then drop it from the cell's zombie list, each pcall'd
-- separately. It is deliberately the same three steps: removeFromWorld alone
-- leaves the reference in the cell list until the engine next prunes, which is
-- long enough for a census running in the same tick to count a zombie that is
-- already gone.
--
-- NO NEW TIMER, NO WIRE. Births ride OnZombieCreate, which fires anyway. The
-- standing sweep runs on zone lifecycle events (a zone that just gained a mode
-- has to clear what is already inside) and on the census pass, which is
-- off by default. Nothing here broadcasts: enforcement reads a store the server
-- already holds, and the resulting death replicates through the engine's own
-- zombie sync. Limes' wire contract is untouched.
--
-- DELETE THIS FILE and `zeds` goes back to being stored and inert, with no other
-- edit anywhere - the DFPatch removable-file idiom that LMDirge and LMShadow
-- already follow.

if not isServer() then return end

require "LMCore"
require "LMZedsShared"
require "RDNet"

LMZeds = LMZeds or {}

local MODE_NONE   = "none"
local MODE_REMOVE = "remove"

-- Runtime state. Counters are per zone name and survive until reboot, so the
-- census can report "this zone has suppressed 417 spawns since boot" - the
-- number that tells you it is working when you cannot see it working.
local removedByZone = {}    -- name -> count since boot
local removedTotal  = 0
local censusOn      = false -- master switch; census logging is opt-in
local lastCensus    = nil   -- name -> count at the previous census, for deltas

-- ---------------------------------------------------------------------------
-- Mode lookup
-- ---------------------------------------------------------------------------

-- The zone's mode at a point, or nil. Reads the RESOLVED store, so a child zone
-- inherits its parent's setting exactly the way every other field inherits.
local function modeAt(x, y)
    if not x or not y then return nil, nil end
    local zone = Limes.getLocation(x, y)
    if not zone or not zone.fields then return nil, nil end
    local m = zone.fields.zeds
    if m == MODE_NONE or m == MODE_REMOVE then return m, zone.name end
    return nil, nil
end

-- Any zone at all asking for enforcement? Cached off onChanged, because the
-- birth hook runs per zombie and must not pay a store walk to learn that no
-- zone in the layer sets the field - which is the common case on a fresh
-- install and stays the common case on most servers.
local armed = false

local function refreshArmed()
    armed = false
    local raw = Limes.raw()
    for _, rec in pairs(raw or {}) do
        local f = rec and rec.fields
        local m = f and f.zeds
        if m == MODE_NONE or m == MODE_REMOVE then armed = true return end
    end
end

Limes.onChanged(refreshArmed)
refreshArmed()

-- ---------------------------------------------------------------------------
-- Removal
-- ---------------------------------------------------------------------------

-- Removal is shared with the client sweep - see shared/LMZedsShared.lua, which
-- carries the reasoning (and the 2026-08-06 correction that produced it).
local cull = LMZedsShared.cull

local function record(name)
    removedByZone[name] = (removedByZone[name] or 0) + 1
    removedTotal = removedTotal + 1
end

-- ---------------------------------------------------------------------------
-- Births
--
-- OnZombieCreate fires inside createRealZombieAlways, BEFORE the OnlineID is
-- assigned - which does not matter here, because removal needs the reference
-- and not the id. It also means the position read here is the exact spawn tile:
-- the zombie has not moved, so the zone test is against where it was actually
-- placed rather than where it drifted to by the time a sweep noticed.
-- ---------------------------------------------------------------------------

local function onZombieCreate(z)
    if not armed or not z then return end
    local mode, name = modeAt(math.floor(z:getX()), math.floor(z:getY()))
    if not mode then return end
    cull(z)
    record(name)
end

-- No guard: a throw in the birth hook would surface per zombie either way -
-- KahluaThread logs at throw time (:865/:1100), before any Lua pcall sees it -
-- and Event.trigger keeps it off every other listener (Event.java:53-63).
Events.OnZombieCreate.Add(function(z) onZombieCreate(z) end)

-- ---------------------------------------------------------------------------
-- The standing sweep
--
-- Only `remove` zones sweep. A `none` zone has already refused every birth
-- inside it, so anything standing there walked in through a door somebody
-- opened - which is a legitimate zombie in a zone that only promised not to
-- SPAWN them, and killing it would be enforcing a policy nobody set.
-- ---------------------------------------------------------------------------

local function zombieList()
    -- Stepped through IsoWorld.instance rather than getCell(): the global
    -- dereferences the instance unconditionally, so it throws before the
    -- world is up; this form just returns nil then.
    local world = IsoWorld and IsoWorld.instance
    local cell = world and world:getCell()
    return cell and cell:getZombieList() or nil
end

-- Returns how many it removed.
function LMZeds.sweep()
    if not armed then return 0 end
    local list = zombieList()
    if not list then return 0 end
    local hits = {}
    local n = list:size()
    for i = 0, n - 1 do
        local z = list:get(i)
        if z then
            local mode, name = modeAt(math.floor(z:getX()), math.floor(z:getY()))
            if mode == MODE_REMOVE then hits[#hits + 1] = { z = z, name = name } end
        end
    end
    -- Collected first, culled second: cull() mutates the very list being walked
    -- and an index-based walk would skip an entry for every removal.
    for i = 1, #hits do
        cull(hits[i].z)
        record(hits[i].name)
    end
    return #hits
end

-- A zone that just appeared, was edited, or was re-enabled may now be covering
-- ground that already has zombies on it. The other events cannot create work:
-- a deleted or disabled zone stops enforcing, it does not need a pass.
--
-- THE CLIENTS HAVE TO BE TOLD, and this is the one place it matters. The engine
-- deletes a zombie for everyone by calling NetworkZombiePacker.deleteZombie(z)
-- BEFORE removeFromWorld - the order is load-bearing, because removeFromWorld
-- nulls onlineId to -1 (IsoZombie:3569) and the delete record carries that id
-- (NetworkZombiePacker:69). Every engine removal path pairs them exactly that
-- way (ZombieCountOptimiser:49-51, NetworkZombieManager:236-238).
--
-- NetworkZombiePacker is NOT Lua-exposed - it is absent from LuaManager's
-- setExposed list and no vanilla Lua touches it - so no mod can send that
-- packet. The design doc's §7.3 names that idiom as ours to use; it is not
-- reachable, and the doc is wrong on that point.
--
-- The BIRTH path does not care: a zombie removed inside OnZombieCreate was
-- never transmitted, so no client ever had one to keep. The SWEEP does care -
-- it removes zombies that are on screen right now, and without a delete packet
-- those clients keep painting them until the chunk re-streams. An admin drawing
-- a remove-zone over a populated street would watch the zombies stand there and
-- conclude the sweep is broken.
--
-- So the clients sweep too, from their own copy of the store, triggered by this
-- broadcast. No ids on the wire and no per-zombie messages: both halves apply
-- the same rule to the same replicated data at the same moment, which is the
-- same "each machine enforces locally" shape §7.4 uses for stats. One tiny
-- broadcast per admin-driven zone event, not per zombie.
Limes.onZoneEvent(function(event, name)
    if event ~= "added" and event ~= "edited" and event ~= "enabled" then return end
    local removed = LMZeds.sweep()
    if removed > 0 then
        print("[Limes] zeds: " .. name .. " " .. event .. " - swept " .. removed .. " zombie(s)")
    end
    -- Broadcast even when the server removed nothing. The server sweeps only
    -- what IT has loaded; a client can be standing in loaded ground the server
    -- is not simulating in this cell, and that client is exactly the one with a
    -- ghost to clear. pcall: a wire failure must not unwind the sweep's books.
    pcall(RDNet.broadcast, "RFTDLimes", "zedsSweep", { name = name })
end)

-- ---------------------------------------------------------------------------
-- THE CENSUS
--
-- What makes this a test rather than a restatement of the config: every count
-- is taken from the world, by walking the cell's zombie list and asking each
-- zombie where it is. Nothing here reads a number the enforcement path wrote.
-- If the settings and the ground disagree, the report shows the disagreement.
--
-- IT COUNTS REAL ZOMBIES ONLY, and that is the one way this could lie. The
-- cell's zombie list holds materialized zombies; the virtual population is not
-- in it, and neither is any chunk the server has not loaded. A zone nobody is
-- standing near would therefore read a confident, meaningless 0.
--
-- So loaded-ness is MEASURED, not assumed: IsoCell.getGridSquare routes to
-- ServerMap.instance.getGridSquare on the server (IsoCell.java:2791) and
-- returns null for unloaded ground, so sampling each rect answers whether the
-- zone is observable at all right now. An unobservable zone reports "unloaded"
-- and NO count. Never a zero it has not earned.
--
-- AND IT CHECKS ITSELF. Every real zombie is either inside exactly one zone or
-- outside them all, so in-zone + outside must equal the list size. The totals
-- line states all three and flags a mismatch, which turns "do I trust this
-- report" into something the report answers rather than something you assume.
-- ---------------------------------------------------------------------------

-- OBSERVABILITY, cheapest PROOF first.
--
-- The first version probed three tiles per rect - centre and two corners - and
-- nothing else. That is adequate for a motel and worthless for Louisville: a
-- zone 1465 tiles across has players standing well inside it and nowhere near
-- those three tiles, so every probe missed and the row printed "unloaded"
-- while its zombies were being counted into the totals behind it. 1640 of 1699
-- in-zone zombies were invisible in the report that had already counted them -
-- the precise failure this column exists to prevent, committed by the column
-- itself.
--
-- So presence decides first: a zombie standing in the zone is proof the ground
-- is loaded, and no sampling can be more authoritative than that. Then players,
-- for the same reason and nearly as cheap. Only a zone that came up genuinely
-- empty reaches the grid, where the question is honestly "cold, or just quiet?"
-- and a spread of samples beats three fixed corners.

local function anyPlayerInside(rects)
    local players = getOnlinePlayers()
    if not players then return false end
    local n = players:size()
    for i = 0, n - 1 do
        local p = players:get(i)
        if p then
            local px, py = math.floor(p:getX()), math.floor(p:getY())
            for j = 1, #rects do
                local r = rects[j]
                if px >= r[1] and px <= r[3] and py >= r[2] and py <= r[4] then return true end
            end
        end
    end
    return false
end

-- Spread samples over each rect rather than hitting its extremes. Capped so a
-- map-sized zone costs the same as a small one.
local PROBE_SIDE = 6      -- up to 6x6 per rect
local PROBE_CAP  = 96     -- total getGridSquare calls per zone, hard stop

local function gridProbe(rects)
    local world = IsoWorld and IsoWorld.instance
    local cell = world and world:getCell()
    if not cell then return false end
    local budget = PROBE_CAP
    for i = 1, #rects do
        local r = rects[i]
        local w, h = r[3] - r[1], r[4] - r[2]
        local stepX = math.max(1, math.floor(w / PROBE_SIDE))
        local stepY = math.max(1, math.floor(h / PROBE_SIDE))
        local x = r[1]
        while x <= r[3] and budget > 0 do
            local y = r[2]
            while y <= r[4] and budget > 0 do
                budget = budget - 1
                -- pcall stays: the server route walks ServerMap's cell arrays,
                -- whose bounds handling is not verified throw-free. Direct form
                -- because this loop runs up to PROBE_CAP times.
                local okSq, sq = pcall(cell.getGridSquare, cell, x, y, 0)
                if okSq and sq then return true end
                y = y + stepY
            end
            x = x + stepX
        end
        if budget <= 0 then break end
    end
    return false
end

-- Decided AFTER the count, so `zombies` can settle it without a single probe.
local function decideObservable(row)
    if row.template then return false end
    if row.zombies > 0 then return true end          -- proof
    if not row.rects or #row.rects == 0 then return false end
    if anyPlayerInside(row.rects) then return true end
    return gridProbe(row.rects)
end

-- Does any PLACED zone reach `name` through its inherits chain or through a
-- profiles list anywhere on that chain?
--
-- Walks the real parent links rather than matching mode strings, which was the
-- first attempt and is wrong in the case that matters: SunstarMotel sets
-- zeds='remove' directly, so "some other zone also says remove" would have
-- silently vouched for an unrelated template carrying the same word. Reach is a
-- property of the chain, so the chain is what gets walked.
--
-- Profiles joined the walk 2026-08-07: a mode on a template now also reaches
-- the world when any record on a placed zone's chain APPLIES that template as
-- a profile (including `_default` - a profile there reaches everything).
-- Reach is deliberately PHASE-AGNOSTIC: it answers "is this configured to do
-- anything", and a full-moon profile is configured even at new moon - the
-- warning this feeds is about dead config, not sleeping config.
--
-- Depth-capped: LMCore already refuses cyclic inheritance at resolve, and a
-- traversal that trusts that and is wrong once hangs the server rather than
-- printing a bad line.
function LMZeds.hasInheritor(name)
    -- _default sits under every placed zone whether or not a chain names it,
    -- so a profile applied THERE reaches everything - answered once, not per
    -- zone. Guarded on any placed zone existing at all, because "reaches
    -- everything" is vacuous over a store with nowhere to stand.
    local root = Limes.getZone("_default")
    if root and name ~= "_default" then
        for i = 1, #(root.profiles or {}) do
            if root.profiles[i] == name then
                for _, other in ipairs(Limes.zoneNames()) do
                    local z = Limes.getZone(other)
                    if z and not z.template then return true end
                end
            end
        end
    end

    for _, other in ipairs(Limes.zoneNames()) do
        local z = Limes.getZone(other)
        if z and not z.template and other ~= name then
            local cur, guard = other, 0
            while cur and guard < 32 do
                if cur == name and cur ~= other then return true end
                local p = Limes.getZone(cur)
                if not p then break end
                for i = 1, #(p.profiles or {}) do
                    if p.profiles[i] == name then return true end
                end
                cur = p.inherits
                guard = guard + 1
            end
        end
    end
    return false
end

-- Returns a report table; printing is separate so a caller can ship the numbers
-- somewhere else without re-deriving them.
function LMZeds.report()
    local rows, byName = {}, {}
    for _, name in ipairs(Limes.zoneNames()) do
        local z = Limes.getZone(name)
        if z then
            -- TEMPLATE IS NOT UNLOADED, and conflating them was this report's
            -- first real lie: isObservable() answers false for missing geometry
            -- exactly as it does for cold ground, so the ten templates in a
            -- PhunZones-derived layer (_default, Easy, Hard, void...) printed
            -- "unloaded (not counted)" - a claim about observation conditions
            -- for a zone that is not anywhere. Asked and reported separately.
            -- The store's OWN template flag, not a re-derivation from rects.
            -- Resolution sets it, LMEdit and the panel agree with it, and a
            -- second definition here would be a third opinion waiting to drift.
            -- The rects test stays only as a fallback for a record that predates
            -- the flag.
            local isTemplate = z.template or not z.rects or #z.rects == 0
            local row = {
                name       = name,
                zeds       = (z.fields and z.fields.zeds) or "",
                tier       = (z.fields and z.fields.tier) or 0,
                removed    = removedByZone[name] or 0,
                template   = isTemplate,
                rects      = z.rects,
                observable = false,     -- decided after the count; see decideObservable
                zombies    = 0,
                specials   = 0,
                -- The dial this zone RESOLVES to, own or inherited. Every zone
                -- in a PhunZones-derived layer reaches a value because _default
                -- carries the full set, so a blank here means a chain that
                -- terminates without one - itself worth seeing.
                chance     = (z.fields and z.fields.dirgeSpawnChance) or nil,
            }
            rows[#rows + 1] = row
            byName[name] = row
        end
    end

    -- Dirge's live special set, as an object -> type map we can test by identity
    -- while walking the cell. Soft: no Dirge, or a Dirge too old to offer the
    -- window, and the specials columns simply report as unknown rather than zero
    -- - a zero would read as "the dials are not working", which is the exact
    -- wrong conclusion to hand someone.
    local special, tracked = {}, nil
    if RQSvShared and RQSvShared.eachActiveZombie then
        tracked = RQSvShared.eachActiveZombie(function(z, zType) special[z] = zType end)
    end

    local list = zombieList()
    local total, inZone = 0, 0
    if list then
        total = list:size()
        for i = 0, total - 1 do
            local z = list:get(i)
            if z then
                local zone = Limes.getLocation(math.floor(z:getX()), math.floor(z:getY()))
                local row = zone and byName[zone.name]
                if row then
                    row.zombies = row.zombies + 1
                    inZone = inZone + 1
                    if special[z] then row.specials = row.specials + 1 end
                end
            end
        end
    end

    -- Now that every zone knows what is standing in it, settle observability.
    -- Order matters: a zone with zombies never reaches a probe, which is both
    -- correct and the reason a 44-zone census does not cost thousands of
    -- getGridSquare calls on a busy server.
    for _, r in ipairs(rows) do r.observable = decideObservable(r) end

    table.sort(rows, function(a, b) return a.name < b.name end)
    return {
        rows     = rows,
        total    = total,
        inZone   = inZone,
        outside  = total - inZone,
        revision = Limes.revision,
        removed  = removedTotal,
        tracked  = tracked,          -- nil when Dirge is absent, a count otherwise
    }
end

-- The log form. One header, one line per zone, one totals line that proves
-- itself. Zones with nothing to say - no mode, no zombies, no removals, and
-- unloaded - are counted rather than printed, because a 44-line wall that is
-- 40 lines of "nothing here" trains you to skim the four that matter.
function LMZeds.census(verbose)
    local rep = LMZeds.report()
    print(string.format("[Limes] ===== ZONE CENSUS - revision %d, %d zones, %d real zombies in cell =====",
        rep.revision, #rep.rows, rep.total))
    print(string.format("[Limes] %-24s %-7s %5s %8s %9s %16s  %s",
        "ZONE", "ZEDS", "TIER", "ZOMBIES", "REMOVED", "SPECIALS obs/set", "GROUND"))

    local quiet = 0
    for _, r in ipairs(rep.rows) do
        local interesting = verbose or r.zeds ~= "" or r.zombies > 0 or r.removed > 0
        if not interesting then
            quiet = quiet + 1
        else
            local delta = ""
            if lastCensus and lastCensus[r.name] then
                local d = r.removed - lastCensus[r.name]
                if d > 0 then delta = " (+" .. d .. ")" end
            end
            local ground = r.template and "template (no geometry)"
                or (r.observable and "loaded" or "unloaded (not counted)")

            -- OBSERVED share of the standing population against the dial that
            -- produced it - the only column here that tests the Dirge bridge
            -- rather than restating configuration.
            --
            -- Read it as a trend, never as pass/fail on one sample. The dial is
            -- a per-SPAWN probability while this is a STANDING population that
            -- players have been thinning, specials die at different rates to
            -- ordinary zombies, and a zone holding nine zombies cannot express
            -- 15% at all. Agreement over a populated zone across several
            -- censuses is the signal; one row is an anecdote.
            local obs = "-"
            if rep.tracked == nil then
                obs = "no dirge"
            elseif r.observable and r.zombies > 0 then
                obs = string.format("%d %d%%/%s", r.specials,
                    math.floor((r.specials / r.zombies) * 100 + 0.5),
                    r.chance and (tostring(r.chance) .. "%") or "unset")
            elseif r.chance then
                obs = "-/" .. tostring(r.chance) .. "%"
            end

            print(string.format("[Limes] %-24s %-7s %5s %8s %9s %16s  %s",
                r.name:sub(1, 24),
                r.zeds ~= "" and r.zeds or "-",
                tostring(r.tier),
                r.observable and tostring(r.zombies) or "-",
                tostring(r.removed) .. delta,
                obs,
                ground))

            -- A mode on a template only reaches the world through zones that
            -- inherit it, and a template nothing inherits is armed-looking dead
            -- config - it reads as an enforcing zone in the panel and in this
            -- report while being incapable of removing anything. Resolution has
            -- already pushed the mode onto every inheritor, so each of those has
            -- its own row above; if this is the only line carrying that mode,
            -- the setting has no reach. Say so here rather than let the row imply
            -- otherwise.
            if r.template and r.zeds ~= "" and not LMZeds.hasInheritor(r.name) then
                print("[Limes]   ^ WARNING: '" .. r.zeds .. "' on a template that no"
                    .. " placed zone inherits - this setting cannot remove anything")
            end
        end
    end
    if quiet > 0 then
        print("[Limes] " .. quiet .. " zone(s) with no mode, no zombies and no removals - use verbose to list them")
    end

    -- The self-check. These three must reconcile or the census is not measuring
    -- what it claims to measure, and saying so is worth more than a clean report.
    local ok = (rep.inZone + rep.outside) == rep.total
    print(string.format("[Limes] totals: %d in zones + %d outside = %d in cell  [%s]",
        rep.inZone, rep.outside, rep.total,
        ok and "reconciled" or "MISMATCH - census is not trustworthy, report this"))
    print(string.format("[Limes] suppressed since boot: %d across %d zone(s)",
        rep.removed, (function() local n = 0 for _ in pairs(removedByZone) do n = n + 1 end return n end)()))

    -- Dirge's own count next to ours. They measure different things on purpose:
    -- Dirge tracks every special it is holding ANYWHERE, we count only the ones
    -- standing on loaded ground inside a zone. Dirge's number being the larger
    -- is normal; ours being larger is not, and would mean identity matching
    -- against the cell has gone wrong.
    if rep.tracked == nil then
        print("[Limes] specials: Dirge not present (or too old to expose its active set)"
            .. " - the SPECIALS column is unavailable, not zero")
    else
        local seen = 0
        for _, r in ipairs(rep.rows) do seen = seen + r.specials end
        print(string.format("[Limes] specials: %d in loaded zones, %d tracked by Dirge overall%s",
            seen, rep.tracked,
            seen > rep.tracked and "  [IMPOSSIBLE - more seen than tracked, identity match is broken]" or ""))
    end

    lastCensus = {}
    for _, r in ipairs(rep.rows) do lastCensus[r.name] = r.removed end
    return rep
end

-- ---------------------------------------------------------------------------
-- The master switch
--
-- Off by default and runtime-only: this is a diagnostic, and a diagnostic that
-- survives a restart is one somebody forgot to turn off. When on, the census
-- prints every ten GAME minutes - the same cadence LMShadow uses, for the same
-- reason (it is a soak, not a heartbeat).
-- ---------------------------------------------------------------------------

function LMZeds.setCensus(on)
    censusOn = on and true or false
    print("[Limes] zeds census " .. (censusOn and "ON - printing every ten game minutes"
        or "OFF"))
    return censusOn
end

function LMZeds.censusEnabled() return censusOn end

-- pcall: a diagnostic that throws must not take the event loop with it.
Events.EveryTenMinutes.Add(function()
    if censusOn then pcall(LMZeds.census, false) end
end)

if Events.OnServerStarted then
    Events.OnServerStarted.Add(function()
        refreshArmed()
        print("[Limes] LMZeds armed=" .. tostring(armed)
            .. " (zeds enforcement; census off by default)")
    end)
end

return LMZeds

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
