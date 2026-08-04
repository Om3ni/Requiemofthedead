-- RCRespawn - the redemption half of the vehicle economy (server only).
--
-- THE LOOP. The Janitor reclaims abandoned cars and mints tokens; field
-- dismantle trickles more in; this spends them back into the world near the
-- players who have least. Net fleet size stays roughly flat, but the fleet
-- MIGRATES: cars stop accumulating in the dead corners of the map where
-- someone parked one and quit, and reappear where people are actually playing.
-- That migration is the point. A shrinking fleet would be attrition and a
-- growing one would be inflation; neither is a lifecycle.
--
-- METERED, NOT IMMEDIATE (owner's call, 2026-08-03). A reclamation does not
-- place a car - it mints a token, and this worker spends at most
-- RespawnPerSweep tokens per hourly pass. Three reasons that is the right
-- shape: a big Janitor sweep would otherwise drop a convoy at once; the pool
-- gives the admin a dial that is legible ("how fast does the world restock")
-- rather than emergent; and a placement that cannot find anywhere legal costs
-- nothing but a retry next hour.
--
-- WHO GETS ONE. Players holding NO claims are served first, then players
-- holding fewer, with ties broken randomly so the same person is not
-- permanently first in line. This is the closest thing the economy has to a
-- fairness rule, and it is deliberately about CLAIMS rather than proximity or
-- playtime: a claim is the game's own statement that someone has a car.
--
-- WHERE. RCParking owns legality; this file only decides which player to
-- search around. Placements land no closer than RespawnMinDistance so a car
-- never materialises in somebody's field of view, and no further than
-- RespawnMaxDistance. In practice the loaded-chunk edge binds long before that
-- ceiling does - addVehicleDebug needs a streamed-in square - which is exactly
-- why replacements track the active play area without any explicit rule
-- saying so.
--
-- WHAT. RCNoVanilla.roster() picks the script, so a server suppressing vanilla
-- cars never has its own lifecycle quietly reintroducing them. Construction is
-- RCSpawn's - one spawn brain, many doors, as that file's header requires.
--
-- DESTRUCTION ACCOUNTING. B42 fires no vehicle-removal event (the wall
-- RCRegistry.pruneOrphans documents), so "a player destroyed a car" is
-- detected as a STATE TRANSITION instead: a vehicle observed intact on one
-- sweep and found wrecked on a later one has been destroyed, whatever did it.
-- The observation rides the sweep that already walks every loaded vehicle, so
-- it costs one modData flag and no new scan.

if not isServer() then return end

require "RCShared"
require "RCNoVanilla"
require "RCParking"
require "RCSpawn"

RCRespawn = RCRespawn or {}

local KEY_INTACT = "RC_Intact"    -- observed alive; its absence on a wreck means "was always a wreck"
local KEY_BORN   = "RC_Respawned" -- epoch this car was placed by the lifecycle (audit + telemetry)

local CONDITION = { [1] = "random", [2] = "perfect", [3] = "average", [4] = "low" }

-- Last-run telemetry for the Lifecycle tab. Plain counters, overwritten each
-- sweep - not a log, so it cannot grow.
--
-- `spots` carries WHERE the last sweep put things. A placement lands in a
-- loaded chunk near somebody else, so the admin who pressed the button has no
-- way to see the result: "placed 3" is a claim they cannot check, and an
-- unverifiable success reads exactly like a silent failure. The coordinates
-- make it falsifiable. Bounded by the burst ceiling (25, clamped in RCServer),
-- and replaced wholesale each sweep, so it is telemetry and not a ledger - the
-- durable record is RCAudit's RESPAWN line.
RCRespawn.last = { placed = 0, tried = 0, noSpot = 0, noToken = 0, at = 0, spots = {} }

-- ---------------------------------------------------------------------------
-- Destruction accounting
-- ---------------------------------------------------------------------------

-- One vehicle, one look, on the hourly sweep. Mints a token when a car we had
-- previously seen intact has become a wreck.
--
-- Claimed cars count too: destroying somebody's owned car is still a car
-- leaving the fleet, and the replacement is owed to the WORLD, not to them.
-- (It does not go to the victim - that would make ramming your own car a way
-- to farm fresh ones.)
function RCRespawn.observe(vehicle)
    if not vehicle then return end
    local c = RCShared.cfg()
    if not (c.enabled and c.respawnOnDestroy) then return end

    pcall(function()
        local md = vehicle:getModData()
        if not md then return end
        if RCShared.isWreck(vehicle) then
            if md[KEY_INTACT] then
                md[KEY_INTACT] = nil
                local trailer = RCShared.isTrailer(vehicle)
                RCRegistry.addToken(trailer and "trailer" or "vehicle")
                local tv, tt = RCRegistry.tokens()
                RCAudit.log("DESTROYED", nil, {
                    vehicle = vehicle:getScriptName(),
                    x = math.floor(vehicle:getX()), y = math.floor(vehicle:getY()),
                    trailer = trailer and true or false,
                    tokensVehicle = tv, tokensTrailer = tt,
                })
                RCShared.dbg("respawn: %s became a wreck - token minted (v=%d t=%d)",
                    tostring(vehicle:getScriptName()), tv, tt)
            end
        elseif not md[KEY_INTACT] then
            -- First time we have seen this car alive. Stamped once, so the
            -- write happens on discovery rather than every sweep.
            md[KEY_INTACT] = true
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Recipient selection
-- ---------------------------------------------------------------------------

-- Online players ordered by how few claims they hold. Returns an array of
-- IsoPlayer. Bounded by the player count, and the claim count comes from the
-- registry index (already in memory) rather than a vehicle walk.
local function playersByNeed()
    local out = {}
    local players = getOnlinePlayers()
    if not players then return out end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local name
        if p and p.getUsername then name = p:getUsername() end
        if name then
            -- Motor vehicles AND trailers: someone with three trailers and no
            -- car still has no car, but they are not the emptiest-handed
            -- player on the server either.
            local claims = RCRegistry.count(name, false) + RCRegistry.count(name, true)
            out[#out + 1] = { player = p, name = name, claims = claims, roll = ZombRand(1000) }
        end
    end
    -- Fewest claims first; random tiebreak so the same player is not
    -- permanently at the head of the queue on a server where several people
    -- have none.
    table.sort(out, function(a, b)
        if a.claims ~= b.claims then return a.claims < b.claims end
        return a.roll < b.roll
    end)
    return out
end

-- ---------------------------------------------------------------------------
-- Placement
-- ---------------------------------------------------------------------------

-- Place one replacement near `player`. Returns the vehicle, or nil plus a
-- reason ("noroster" | "nospot" | "spawnfailed").
--
-- On success a third value describes WHERE it went - see RCRespawn.last.spots.
-- Appended rather than folded into the vehicle handle because the caller needs
-- the coordinates after the sweep has finished, by which time the car may have
-- streamed out and the handle be worthless.
--
-- `avoid` carries the spots THIS sweep has already used. It is not an
-- optimisation and not defensive: a car placed a moment ago is queued in
-- cell.addVehicles and is absent from every world query until the cell's next
-- update pass, so without this list a burst of placements is free to stack
-- itself in one car park (see RCParking's SPACING).
function RCRespawn.placeNear(player, avoid)
    local c = RCShared.cfg()

    local roster = RCNoVanilla.roster(c.respawnModdedOnly)
    if not roster or #roster == 0 then return nil, "noroster" end

    local px, py, pz
    local okPos = pcall(function()
        px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    end)
    if not okPos or not px then return nil, "nospot" end

    local sx, sy, sz = RCParking.findSpot(px, py, pz, c.respawnMinDist, c.respawnMaxDist, avoid)
    if not sx then return nil, "nospot" end

    -- Prefer a car that suits the stall it is parking in: the zone's own
    -- distribution list, filtered the same way the general roster is. A police
    -- lot gets police vehicles, a farm gets farm ones. Falls back to the
    -- general roster whenever the zone has nothing usable, so this can only
    -- improve the choice, never block a placement.
    local zoneName = RCParking.zoneNameAt(sx, sy, sz)
    local pick = (zoneName and RCNoVanilla.rosterForZone(zoneName, c.respawnModdedOnly)) or roster
    local model = pick[ZombRand(#pick) + 1]
    local vehicle, reason = RCSpawn.spawn({
        model     = model,
        x = sx, y = sy, z = sz,
        -- Point it along the stall rather than across it. nil when the tile is
        -- in no zone, which leaves RCSpawn's roll exactly as it was.
        direction = RCParking.zoneDirection(sx, sy, sz),
        condition = CONDITION[c.respawnCondition] or "low",
        -- No key and no forced fuel: a car the world put back is something to
        -- be found and got running, not a delivery. RCSpawn rolls fuel and
        -- battery on its own.
        keyGlovebox  = false,
        missingParts = false,
    })
    if not vehicle then return nil, reason or "spawnfailed" end

    pcall(function()
        local md = vehicle:getModData()
        md[KEY_BORN]   = os.time()
        -- Born alive, so a later wreck correctly mints its own replacement and
        -- the loop continues rather than terminating at this car.
        md[KEY_INTACT] = true
    end)

    RCAudit.log("RESPAWN", nil, {
        vehicle = model, x = sx, y = sy, z = sz,
        nearPlayer = player:getUsername(),
    })
    RCShared.dbg("respawn: placed %s at %d,%d,%d near %s",
        model, sx, sy, sz, tostring(player:getUsername()))
    return vehicle, nil, {
        -- Prefixless: the panel column is narrow and "Base." is noise on every
        -- single row. The full script name is in the audit line.
        model = tostring(model):gsub("^.-%.", ""),
        x = sx, y = sy, z = sz,
        near = player:getUsername(),
    }
end

-- ---------------------------------------------------------------------------
-- The sweep worker - called by RCSession once per hourly pass, and by the
-- Janitor view's "Place now" for an immediate run.
--
-- `burst` overrides RespawnPerSweep for THIS run only. It exists because the
-- hourly rate is tuned for ambient upkeep (default 2/hour), and a retrofit is
-- not ambient: an admin who has just purged fifty vanilla cars should not have
-- to leave the server running for a day to see them replaced. The hourly caller
-- passes nothing and is completely unchanged.
--
-- Deliberately does NOT bypass the token pool. A manual run spends banked
-- tokens faster; it cannot conjure them. That keeps one invariant true
-- everywhere - a car only ever appears because a car left - which is the whole
-- reason the pool exists rather than a spawn button.
-- ---------------------------------------------------------------------------
function RCRespawn.sweep(burst)
    local c = RCShared.cfg()
    local stat = { placed = 0, tried = 0, noSpot = 0, noToken = 0, at = os.time(), spots = {} }
    RCRespawn.last = stat

    -- RespawnEnabled still gates a manual run: it is the admin's statement that
    -- this server does not place replacements at all, and a button should not
    -- quietly outrank a setting.
    if not (c.enabled and c.respawnEnabled) then return 0 end
    local perSweep = tonumber(burst) or c.respawnPerSweep or 0
    if perSweep <= 0 then return 0 end

    local queue = playersByNeed()
    if #queue == 0 then return 0 end

    -- Round-robin from the front of the need-ordered queue. Each placement
    -- re-reads the queue position rather than serving one player repeatedly,
    -- so a sweep of 3 with 3 empty-handed players gives them one each.
    local idx = 1
    for _ = 1, perSweep do
        local tv = RCRegistry.tokens()
        if tv <= 0 then stat.noToken = stat.noToken + 1; break end

        -- Spend first: a failure after this point costs one token, which is
        -- the harmless direction (see RCRegistry.spendToken).
        if not RCRegistry.spendToken("vehicle") then
            stat.noToken = stat.noToken + 1
            break
        end

        local placed = false
        -- One pass over the queue per token, so a token is not wasted just
        -- because the neediest player happens to be standing in deep forest.
        for _ = 1, #queue do
            local entry = queue[idx]
            idx = idx % #queue + 1
            if entry then
                stat.tried = stat.tried + 1
                -- stat.spots doubles as the avoid list: its entries already
                -- carry x/y, and it is exactly "what this sweep has placed so
                -- far", which is the set nothing in the world can see yet.
                local v, _, spot = RCRespawn.placeNear(entry.player, stat.spots)
                if v then
                    stat.placed = stat.placed + 1
                    if spot then stat.spots[#stat.spots + 1] = spot end
                    entry.claims = entry.claims + 1   -- served: drop them down the order
                    placed = true
                    break
                end
            end
        end

        if not placed then
            -- Nowhere legal near anyone right now. Refund and stop: retrying
            -- the remaining budget this same sweep would just re-walk the same
            -- unloaded map for the same answer.
            RCRegistry.addToken("vehicle")
            stat.noSpot = stat.noSpot + 1
            break
        end
    end

    if stat.placed > 0 then
        RCShared.dbg("respawn sweep: placed %d (tried %d)", stat.placed, stat.tried)
    end
    return stat.placed
end
