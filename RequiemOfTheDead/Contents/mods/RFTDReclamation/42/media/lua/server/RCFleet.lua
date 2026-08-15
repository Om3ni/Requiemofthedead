-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCFleet - the admin fleet snapshot, paged and budgeted (server only).
--
-- Answers ONE question for the Dragonfly vehicles tab: what vehicles exist,
-- and what does the Janitor think of each? The tab used to read
-- getCell():getVehicles() on the CLIENT, which cost zero network but could
-- only ever show cars the admin was personally standing near - useless for
-- triage, and blind to every lifecycle field, because those live in
-- server-only modData that is deliberately never transmitted (RCJanitor).
--
-- WHY THIS IS PAGED AND BUDGETED, not one call that returns a list:
--   * the SCAN is the expensive half, not the packet. Per vehicle we read
--     modData, resolve the keeper's presence, test PhunZones, and call
--     SafeHouse.getSafeHouse(square). On a busy server that is hundreds of
--     cars, and doing it all inside one tick is precisely the shape of stall
--     documented in the chunk-transition work - the whole tick blocks and
--     every player feels it.
--   * so: ONE cheap pass collects vehicle refs (no per-vehicle work), then a
--     bounded slice of that array is enriched per tick, emitting a page each
--     time enough rows accumulate. Server work per tick is capped no matter
--     how big the fleet is.
--   * the client fills progressively and is useful from page one.
--
-- The Java vehicle Set is NOT held across ticks. It is iterated once into a
-- plain Lua array, because the Set mutates as chunks stream and a half-walked
-- iterator would throw somewhere in the middle of an admin's snapshot. Each
-- ref is re-validated when its turn comes; anything that unloaded meanwhile is
-- skipped rather than guessed at.
--
-- Every verdict comes from RCJanitor.assess - never recomputed here. See the
-- header on that function for why a second implementation of the Presence Law
-- is not allowed to exist.
--
-- Dispatch is RCServer's (the single-dispatcher house rule); this file owns
-- only the scan. Admin-gated at the handler, and again here.

if not isServer() then return end

RCFleet = RCFleet or {}

local M = RCShared.MODULE

-- Tuning. SCAN_PER_TICK is a GLOBAL budget shared by every concurrent scan, so
-- three admins refreshing at once cost the same per tick as one. ROWS_PER_PAGE
-- keeps a single packet modest; MAX_ROWS is the honesty ceiling - past it we
-- stop and SAY we stopped, because a silently truncated fleet list reads as
-- "that is all of them", which is the one thing it must never mean.
local SCAN_PER_TICK = 20
local ROWS_PER_PAGE = 60
local MAX_ROWS      = 600

local scans   = {}      -- username -> scan state
local ticking = false
local seqNext = 0

-- ---------------------------------------------------------------------------
-- Row construction
-- ---------------------------------------------------------------------------

local function occupantCount(v)
    local n = 0
    local script = v:getScript()
    local seats = script and script:getPassengerCount() or 0
    for s = 0, seats - 1 do
        if v:isSeatOccupied(s) then n = n + 1 end
    end
    return n
end

-- REMOVED: "defined by" (the list of mods contributing a script body).
--
-- getLoadedScriptBodies() looked like free conflict-detection - one entry per
-- mod that redefines a vehicle - and it was wrong twice over:
--
--   1. Despite the name and its ArrayList<String> return, addLoadedScriptBody
--      pushes BOTH of its arguments (BaseScriptObject.java:129), so the flat
--      list is [modId, body, modId, body, ...]. Reading it whole dumped raw
--      script SOURCE across the detail pane ("vehicle Van { mechanicType = 2,
--      ... }") and reported double the real contributor count.
--   2. Even reading alternate entries, probing the object for the method threw
--      "attempted index: loadedScriptBodies of non-table: null" - caught by the
--      surrounding pcall, but PZ logs a caught pcall anyway, so it was one
--      exception per vehicle per scan.
--
-- Not patched a third time, because it was never worth much: getScriptName()
-- already carries the defining module as its prefix ("Base.Van"), which answers
-- "where did this come from" for every case except a mod overriding another
-- mod's script - the rare case this was for. If that case ever needs solving,
-- solve it from mod.info on disk, not from this API.

-- No distance here on purpose: we send x/y/z and the client measures against
-- its own player every frame, so the column stays true while the admin walks
-- instead of freezing at whatever it was when the snapshot was taken.
local function buildRow(v)
    local row = {}
    row.vid    = v:getId()
    row.script = v:getScriptName() or "?"
    row.loaded = true

    row.x = math.floor(v:getX())
    row.y = math.floor(v:getY())
    row.z = math.floor(v:getZ())

    row.kind = RCShared.isWreck(v) and "wreck"
        or (RCShared.isTrailer(v) and "trailer" or "car")

    local eng = v:getPartById("Engine")
    if eng then row.engine = math.floor(eng:getCondition()) end

    row.occupied = occupantCount(v)
    row.owner    = RCClaim.getOwner(v)
    row.claimId  = RCClaim.getClaimId(v)

    -- The overlay family the parts diagram should draw, when the script declares
    -- one (this is how a modded vehicle opts in; the client falls back if absent).
    -- getScript and getCarMechanicsOverlay are both field returns
    -- (BaseVehicle.java:1403, VehicleScript.java:2224); only the script can be nil.
    local vscript = v:getScript()
    local overlay = vscript and vscript:getCarMechanicsOverlay()
    if overlay and overlay ~= "" then row.overlay = tostring(overlay) end

    local a = RCJanitor and RCJanitor.assess(v) or nil
    if a then
        row.verdict  = a.verdict
        row.lastUser = a.lastUser
        row.idle     = a.idle
        row.dueIn    = a.dueIn
        row.userIdle = a.userIdle
        row.window   = a.window
        row.shields  = a.shields
    end

    return row
end

-- ---------------------------------------------------------------------------
-- Paging
-- ---------------------------------------------------------------------------

-- BYTE-SPLIT, ADDED 2026-08-09. A 2026-08-08 wire capture caught this key at
-- 12.6 KB in a single message, four chunks over budget, and reported as "paging
-- implied, no declared budget" - which is the probe correctly saying "this thing
-- pages but will not tell me what it is paging TO, so I am judging it against my
-- general ceiling."
--
-- The scan was already paged, and paged on the RIGHT axis for its UX: it emits
-- what it has found so far so the panel fills while the admin reads. What it
-- never did was bound a page by SIZE. A page held however many rows the scan
-- happened to accumulate before the pump ran, and a fleet of heavy rows - a
-- vehicle with a long parts list, a verdict block, an overlay name - put all of
-- them in one message.
--
-- So the page is now split against RDChunk's size model (the same model the wire
-- probe judges the result by, which is the point) and the budget is DECLARED, so
-- a future breach reports as "this constant is wrong" rather than "go write a
-- chunker". The scan's own seq/page/done protocol is untouched: RDChunk.send
-- supersedes by key, which is right for a complete snapshot and would delete
-- every page but the last of a progressive stream like this one. Core exposes the
-- splitter separately for exactly this case.
local FLEET_CHUNK_BYTES = 3072

if RDChunk then
    RDChunk.declare(M, "Fleet", { budget = FLEET_CHUNK_BYTES, envelope = 260, maxRows = 120 })
    -- Parts rows are fatter and fewer than fleet rows (each carries an item-type
    -- list), so the row cap is lower against the same byte budget.
    RDChunk.declare(M, "VehicleParts", { budget = FLEET_CHUNK_BYTES, envelope = 200, maxRows = 60 })
end

local function emit(scan, done)
    local rows = scan.rows
    scan.rows = {}
    -- A page with no rows is still worth sending when it is the LAST one: it
    -- carries done/total/capped, and without it a fleet whose final slice
    -- happened to land empty would leave the panel spinning forever.
    if #rows == 0 and not done then return end

    -- One send per slice. `done` rides ONLY the final message, or the client
    -- stops assembling while pages are still in flight and renders a short fleet
    -- as a complete one - which looks like data loss and is not.
    local slices = (RDChunk and RDChunk.slice(M, "Fleet", rows)) or { rows }
    if #slices == 0 then slices = { {} } end

    for i = 1, #slices do
        local last = (i == #slices)
        scan.page = scan.page + 1
        local page = scan.page
        local slice = slices[i]
        -- sendServerCommand returns early for an unmapped player or closed
        -- connection (GameServer.java:3256), so no guard for a mid-page quit.
        sendServerCommand(scan.player, M, "Fleet", {
            seq    = scan.seq,
            scope  = scan.scope,
            page   = page,
            rows   = slice,
            done   = (done and last) and true or false,
            total  = scan.emitted,
            capped = scan.capped and true or false,
            seen   = scan.seen,
        })
    end
end

local function finish(scan)
    emit(scan, true)
    scans[scan.key] = nil
    RCShared.dbg("fleet: scan %d for %s finished - %d row(s) of %d seen%s",
        scan.seq, tostring(scan.key), scan.emitted, scan.seen,
        scan.capped and " (CAPPED)" or "")
end

local function stillOnline(player)
    if not player then return false end
    return player:getUsername() ~= nil
end

-- THE DUE SCOPE (2026-08-03). "Which cars is the Janitor coming for?" is the
-- same scan as Loaded with one predicate applied, because every row already
-- carries RCJanitor.assess's verdict and dueIn (see buildRow) - the question
-- was always answerable, it just had no door.
--
-- Only the two verdicts that actually LEAD somewhere are kept:
--   clock - counting down; dueIn says how long
--   due   - past every gate, eligible on the next sweep with budget
-- claimed / wreck / held / shielded are deliberately excluded. They are not
-- "not due yet", they are not on the path at all, and padding the list with
-- cars that will never be reclaimed is how a triage view stops being read.
--
-- FILTERED HERE, SORTED ON THE CLIENT. A progressive scan cannot sort - rows
-- leave in the order they were found, across many pages - so ordering by dueIn
-- belongs where the whole set exists at once. Filtering still belongs here:
-- it is what keeps a due list on a big server down to a handful of packets,
-- and it means MAX_ROWS bounds the cars that MATTER rather than being spent on
-- the first 600 vehicles found in arbitrary order.
local DUE_VERDICTS = { clock = true, due = true }

local function step(scan, budget)
    local used = 0
    while used < budget and scan.i <= #scan.refs do
        local v = scan.refs[scan.i]
        scan.i = scan.i + 1
        used = used + 1
        scan.seen = scan.seen + 1

        -- re-validate: this ref was collected up to several ticks ago and the
        -- car may have streamed out or been removed since
        local alive = v:getId() ~= nil
        if alive then
            -- guarded: buildRow reads claim modData and Janitor state off a ref
            -- that can stream out between the id check and here
            local ok, row = pcall(buildRow, v)
            if ok and row and not (scan.dueOnly and not DUE_VERDICTS[row.verdict or ""]) then
                scan.rows[#scan.rows + 1] = row
                scan.emitted = scan.emitted + 1
                if scan.emitted >= MAX_ROWS then
                    scan.capped = true
                    break
                end
            end
        end

        if #scan.rows >= ROWS_PER_PAGE then emit(scan, false) end
    end
    return used
end

local function tick()
    local budget = SCAN_PER_TICK

    for key, scan in pairs(scans) do
        if not stillOnline(scan.player) then
            scans[key] = nil
        elseif scan.capped or scan.i > (scan.count or 0) then
            -- exhausted or capped: ONE exit path owns the final page, so a scan
            -- can never be finished twice or dropped without a done marker
            finish(scan)
        elseif budget > 0 then
            budget = budget - (scan.step or step)(scan, budget)
        end
    end

    local empty = true
    for _ in pairs(scans) do empty = false; break end
    if empty then
        ticking = false
        Events.OnTick.Remove(tick)
    end
end

local function ensureTicking()
    if ticking then return end
    ticking = true
    Events.OnTick.Add(tick)
end

-- ---------------------------------------------------------------------------
-- Collect refs. ONE iterator pass, no per-vehicle work - the Set is walked with
-- :iterator() because get(i) on it crashes (the RCSession idiom), and it is
-- turned straight into a Lua array so nothing holds the Java iterator open.
-- ---------------------------------------------------------------------------
local function collectLoaded()
    local refs = {}
    local cell = getCell and getCell()
    if not cell then return refs end
    local vs = cell:getVehicles()
    if not vs then return refs end
    local it = vs:iterator()
    if not it then return refs end
    while it:hasNext() do
        local v = it:next()
        if v then refs[#refs + 1] = v end
    end
    return refs
end

-- ---------------------------------------------------------------------------
-- The CLAIMED scope: every claim in the index, loaded or not. This is the only
-- way to see a car nobody has streamed in, and there is no engine call that
-- enumerates unloaded vehicles - the index is all we have.
--
-- On the registry's "NEVER transmitted" rule: that rule protects the registry
-- TABLE - its shape, its per-player lastSeen, its token pools - from going out
-- on the wire. What leaves here is a bounded, derived projection (name,
-- position, owner, claim id), admin-gated at the handler, built on demand and
-- never on a timer. The rule's intent is intact; a fleet view that silently
-- omitted every unloaded car would be lying about the fleet.
-- ---------------------------------------------------------------------------
local function collectClaimed()
    local rows = {}
    local loaded = RCRegistry.loadedClaimMap()   -- self-heals the index first
    for _, rec in ipairs(RCRegistry.allClaims()) do
        local v = loaded[rec.claimId]
        if v then
            -- guarded: the mapped ref can be mid-removal; one bad car must not
            -- lose the rest of the claimed list
            local ok, row = pcall(buildRow, v)
            if ok and row then rows[#rows + 1] = row end
        else
            rows[#rows + 1] = {
                loaded  = false,
                claimId = rec.claimId,
                script  = rec.name or "?",
                owner   = rec.owner,
                x = rec.x, y = rec.y, z = rec.z,
                kind    = rec.trailer and "trailer" or "car",
                seen    = rec.seen,
                -- a claimed car is held by the claim system by definition; the
                -- Janitor never looks at one, loaded or not
                verdict = "claimed",
                shields = { claimed = true },
            }
        end
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Entry point (called by RCServer's dispatcher)
-- ---------------------------------------------------------------------------
function RCFleet.begin(player, scope)
    if not (player and sendServerCommand) then return end
    local key = player:getUsername()
    if not key then return end

    seqNext = seqNext + 1

    -- A new request SUPERSEDES the old one. The client discards any page whose
    -- seq is not the one it is waiting on, so an admin hammering Refresh can
    -- never interleave two snapshots into one list.
    scans[key] = nil

    -- "due" is the loaded scan wearing a filter, so it shares that whole path
    -- and only sets the predicate flag. Anything unrecognised falls back to
    -- loaded rather than erroring: an unknown scope from a stale client should
    -- show the admin the safe superset, not nothing.
    if scope ~= "claimed" and scope ~= "due" then scope = "loaded" end

    local scan = {
        key = key, player = player, seq = seqNext, scope = scope,
        rows = {}, i = 1, page = 0, emitted = 0, seen = 0, capped = false,
        dueOnly = (scope == "due"),
    }

    if scope == "claimed" then
        -- The claimed set is index-sized (KB-scale, bounded by MaxClaims x
        -- players), not world-sized, so it is built in one go and then PAGED
        -- out on the same ticker - the wire still gets modest packets.
        -- guarded: the registry self-heal inside walks live vehicles that can
        -- mutate under it; the fallback is an empty (not partial) snapshot
        local ok, rows = pcall(collectClaimed)
        scan.pre = ok and rows or {}
        scan.refs = {}
        scan.i = 1
        -- feed the pre-built rows through the same pager
        scan.step = function(s, budget)
            local used = 0
            while used < budget and s.i <= #s.pre do
                s.rows[#s.rows + 1] = s.pre[s.i]
                s.i = s.i + 1
                s.emitted = s.emitted + 1
                s.seen = s.seen + 1
                used = used + 1
                if s.emitted >= MAX_ROWS then s.capped = true; break end
                if #s.rows >= ROWS_PER_PAGE then emit(s, false) end
            end
            return used
        end
        scan.count = #scan.pre
    else
        -- guarded: getCell() dereferences IsoWorld.instance unguarded
        -- (LuaManager.java:4772) - an early request must degrade to an empty
        -- scan, not an error mid-dispatch
        local ok, refs = pcall(collectLoaded)
        scan.refs = ok and refs or {}
        scan.count = #scan.refs
    end

    scans[key] = scan
    RCShared.dbg("fleet: scan %d for %s (%s) - %d candidate(s)",
        scan.seq, tostring(key), scope, scan.count)
    ensureTicking()
end

-- ---------------------------------------------------------------------------
-- One vehicle's parts, on demand.
--
-- The fleet snapshot deliberately does NOT carry these: 30-odd values per car
-- across hundreds of cars is the payload the paging exists to avoid, and the
-- admin only ever looks at one at a time. The client reads parts locally when
-- the car is streamed to it (free) and only asks here when it is not - so this
-- fires once per car actually inspected at range, and the client caches it.
--
-- Unbounded only in the sense that a vehicle can have many parts; that is a
-- fixed property of the script, not of the world, so there is nothing to page.
-- ---------------------------------------------------------------------------
function RCFleet.parts(player, vid)
    if not (player and sendServerCommand and vid) then return end
    -- vid comes off the wire: a non-number would blow the (short) cast inside
    -- getVehicleById, so the guard stays.
    local okv, v = pcall(getVehicleById, vid)
    if not okv or not v then
        -- Answer anyway with an empty list. Silence would leave the client's
        -- in-flight flag set forever and the diagram stuck on "reading parts".
        sendServerCommand(player, M, "VehicleParts", { vid = vid, parts = {} })
        return
    end

    local out = {}
    local n = v:getPartCount()
    for i = 0, n - 1 do
        local p = v:getPartByIndex(i)
        if p then
            local rec = { id = p:getId() }
            rec.cond = math.floor(p:getCondition() or 0)
            rec.missing = (p:getInventoryItem() == nil) and (p:getTable("install") ~= nil) or false
            if p:isContainer() then
                rec.amount   = p:getContainerContentAmount()
                rec.capacity = p:getContainerCapacity()
            end
            -- The item types this part slot ACCEPTS, for the Workshop tab's
            -- recipe filter. Read here because it is unreachable client-side
            -- for a car that is not streamed to that client: the script-level
            -- Part keeps itemType as a bare public FIELD (VehicleScript.java,
            -- Part class) and Kahlua reads fields never, methods only - only
            -- the LIVE VehiclePart carries a getItemType() getter, and for a
            -- remote car the live object exists only here on the server.
            local it = p:getItemType()
            if it and it:size() > 0 then
                local list = {}
                for j = 0, it:size() - 1 do list[#list + 1] = tostring(it:get(j)) end
                rec.items = list
            end
            out[#out + 1] = rec
        end
    end

    -- Split for the same reason Fleet is, and pre-emptively rather than after a
    -- capture catches it. VehicleParts was NOT flagged in the 2026-08-08 report -
    -- 5,067 B average, 7,021 B largest, comfortably inside the 8 KB ceiling. That
    -- is exactly what a latent breach looks like: the payload is a list of parts
    -- with an `items` array on each, so its size is set by the vehicle, not by us,
    -- and a heavily-modded or fully-loaded vehicle is one longer list away from
    -- the same 12 KB message Fleet was already sending.
    --
    -- seq/total ride every message so the client can assemble; a single-slice
    -- send still carries seq=1 total=1, which keeps the receiver's path uniform.
    local slices = (RDChunk and RDChunk.slice(M, "VehicleParts", out)) or { out }
    if #slices == 0 then slices = { {} } end

    for i = 1, #slices do
        sendServerCommand(player, M, "VehicleParts",
            { vid = vid, parts = slices[i], seq = i, total = #slices })
    end
end

-- Drop a player's in-flight scan (disconnect, or the tab closing).
function RCFleet.cancel(player)
    if not player then return end
    local key = player:getUsername()
    if key then scans[key] = nil end
end

print("[RC] RCFleet loaded (paged fleet snapshot)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
