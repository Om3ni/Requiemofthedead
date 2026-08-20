-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================
-- RQServer.lua - Dirge Server Orchestrator
-- Runs only on server (dedicated or online host).
-- Each zombie type now has its own module; this file ties them
-- together, owns global state, handles conversion scanning,
-- snapshot building, client commands, and the main tick loop.
-- =============================================

if not isServer() then return end

-- ========================
-- Load submodules
-- ========================

require "RQCommon"      -- RQCommon.MODULE is read at file scope by the registrations
require "RDNet"         -- so is RDNet.register
require "RQDirgeLog"
require "RQSvShared"
require "RQSvDormant"
require "RQSvEating"
require "RQSvGlutton"
require "RQSvScavenger"
require "RQSvScreamer"
require "RQSvJuggernaut"
require "RQSvBoss"
require "RQSvEMP"
require "RQSvLoot"
require "RQWireHeadroom"

-- ========================
-- Orchestrator-owned state
-- ========================

local svActiveZombies  = setmetatable({}, { __mode = "k" })
-- Roll bookkeeping -- the consumed ticket and any spacing-parked winner --
-- lives in zombie modData (RQRolled / RQPendingType), NOT in Lua tables keyed
-- by the zombie object. Engine-verified reason (ZombiePopulationManager /
-- VirtualZombieManager in the 42.x decompile): IsoZombie objects are POOLED.
-- removeFromWorld parks the object in reusableZombies and resetForReuse()
-- wipes its modData before the same Java object comes back as a DIFFERENT
-- zombie. A table keyed by the object outlives the zombie it described and
-- aliases the recycled one: the new zombie arrives "already rolled" (silent
-- roll starvation) or inherits a parked pending win (a random zombie
-- spontaneously converts, possibly mid-fight). modData dies exactly when the
-- zombie stops being that zombie, so it cannot alias. It does NOT survive
-- chunk unload either -- virtualization keeps only pos/dir/outfit/stateflags
-- (n_addZombie) -- so a verdict lasts for the zombie's loaded lifetime; that
-- is the best any Lua-side state can do. Post-reload re-rolls are accepted
-- and made invisible by the GUARD_RANGE gate below.
local svDeathCache     = {}   -- onlineID -> { zType, x, y, z, updatedAt }
-- Dormant-registry pid per tracked special. Parallel weak table on purpose:
-- svActiveZombies keeps its value shape (zombie -> zType) so every existing
-- iteration site stays untouched. Entries share svActiveZombies' lifecycle --
-- both are evicted in the same tick-loop cleanup pass, so the pooled-object
-- aliasing window is identical to what the tracker already accepts.
local svPids           = setmetatable({}, { __mode = "k" })
local svProcessedDeaths = {}  -- onlineIDStr -> timestamp
-- adminReroll support: non-nil only during the command's synchronous sweep.
-- Dedups per-zombie refunds when overlapping player scan ranges visit the
-- same zombie twice in one pass (object keys are safe within a single pass).
local svRefundSeen  = nil
local svRefundCount = 0

local svTickCount      = 0
local svSnapshotTimer  = 0
local svSnapshotDirty  = false
local svConfigRefreshTimer = 0
local deathCleanupTimer    = 0
local svReservationCleanupTimer = 0
local svJuggBuffTick   = 0
local svToCleanup      = {}
local svToCleanupDead  = {}  -- parallel to svToCleanup: true = confirmed death

local SCAN_RANGE    = 30
-- No organic conversion fires within GUARD_RANGE of a visible player, or on a
-- zombie actively chasing a target. The roll is DEFERRED, not consumed -- the
-- zombie simply isn't a candidate until the fight moves away -- so a zombie
-- can never transform in front of the player engaging it (the reported
-- "rerolled mid-fight" bug). Must stay well below SCAN_RANGE or the funnel
-- starves: conversions now happen only in the 15..30 tile band.
local GUARD_RANGE   = 15
local SCAN_INTERVAL = 60
local DEATH_CLEANUP_INTERVAL = 18000

-- Delta position granularity, in tiles. Rows still carry true floor() coords --
-- this only coarsens the DECISION to re-ship a row, so a special walking a
-- straight line ships roughly 1/POS_BUCKET as often. At per-tile granularity
-- every walking special re-shipped its whole enriched row to every client on
-- every snapshot pass, which is most of the steady-state delta volume.
-- Safe because every consumer already tolerates staleness: the row was up to
-- 2s old anyway, findZombieByID searches +/-15 tiles, and the only
-- precision-sensitive reader (RQCore.ensureCastFromSnapshot placing a recovery
-- ring) is a fallback -- castStart carries exact coords on the primary path.
-- Do not raise much past 5 or that ring drift becomes visible.
local POS_BUCKET = 3

-- Inject the shared active-zombie table into the modules that need it
RQSvShared.setActiveZombies(svActiveZombies)
RQSvJuggernaut.setActiveZombies(svActiveZombies)
RQSvBoss.setActiveZombies(svActiveZombies)
RQSvScavenger.setActiveZombies(svActiveZombies)

-- ========================
-- Helpers kept in orchestrator
-- ========================

local function svRememberZombie(zombie, zType)
    if not zombie or not zType then return end
    local oid = zombie:getOnlineID()
    if not oid or oid == 0 then return end

    local x, y, z = zombie:getX(), zombie:getY(), zombie:getZ()

    svDeathCache[oid] = {
        zType     = zType,
        x         = math.floor(x),
        y         = math.floor(y),
        z         = math.floor(z),
        updatedAt = getTimestampMs(),
    }
end

-- Dormant registry hand-off for a LIVE special: mint the pid on first sight
-- and create the world-anchored record; on later calls refresh it in place
-- (touch keeps the outfitID-change WARN). If the record was evicted while
-- the zombie is still live (sweep race), re-record rather than silently
-- losing the identity. Single entry point for conversion, reload recovery,
-- and the per-tick refresh -- Phase 2 adoption should reuse it too.
local function svDormantTrack(zombie, zType)
    local outfitID = zombie:getPersistentOutfitID()
    local pid = svPids[zombie]
    if pid and RQSvDormant.touch(pid, zombie:getX(), zombie:getY(), zombie:getZ(),
                                 zombie:getHealth(), outfitID) then
        return
    end
    if not pid then
        pid = RQSvDormant.mint()
        svPids[zombie] = pid
    end
    RQSvDormant.record(pid, zType, zombie:getX(), zombie:getY(), zombie:getZ(),
                       outfitID, zombie:getHealth())
end

local function svMarkZombie(zombie, zType)
    local md = zombie:getModData()
    md["RQType"]      = zType
    md["RQConverted"] = true
    svActiveZombies[zombie] = zType
    svRememberZombie(zombie, zType)
    -- Dormant registry: world-anchored identity record so this special can be
    -- re-bound after virtualization wipes its modData.
    svDormantTrack(zombie, zType)
    zombie:transmitModData()
    RQSvShared.broadcast("zombieConverted", {
        onlineID = zombie:getOnlineID(),
        x        = math.floor(zombie:getX()),
        y        = math.floor(zombie:getY()),
        z        = math.floor(zombie:getZ()),
        zType    = zType,
    })
    svSnapshotDirty = true
end

-- marks summoned zombies so the conversion scan skips them (avoids converting our own spawns)
local function svCheckAndMarkSummoned(zombie)
    local now = getTimestampMs()
    local zx  = math.floor(zombie:getX())
    local zy  = math.floor(zombie:getY())
    local kept  = {}
    local keptN = 0
    local result = false
    for _, p in ipairs(RQSvShared.svPendingSummons) do
        if now - p.t > 20000 then
            -- expired, drop it
        elseif (not result) and (p.x - zx)^2 + (p.y - zy)^2 <= p.r * p.r then
            zombie:getModData()["RQRolled"] = true
            result = true
            keptN = keptN + 1
            kept[keptN] = p
        else
            keptN = keptN + 1
            kept[keptN] = p
        end
    end
    RQSvShared.svPendingSummons = kept
    return result
end

-- Spacing check: only reject if another zombie of the SAME type is too close.
-- spacingDist <= 0 disables the check entirely for that type.
local function svCanSpawnHere(zombie, zType, spacingDist)
    if spacingDist <= 0 then return true end
    local zx, zy = zombie:getX(), zombie:getY()
    local distSq = spacingDist * spacingDist
    for existing, existingType in pairs(svActiveZombies) do
        if existingType == zType then
            local dx, dy = zx - existing:getX(), zy - existing:getY()
            if dx * dx + dy * dy < distSq then return false end
        end
    end
    return true
end

-- Per-type config lookups. Shared by the fresh-roll path, the pending
-- spacing retry, and adminReroll -- all of which live outside the closure
-- scope inside svCheckZombie where the spacing lookup used to be defined.
local function svTypeSpacing(cfg, zType)
    if     zType == "Screamer"   then return cfg.screamerSpacing   or 0
    elseif zType == "Juggernaut" then return cfg.juggernautSpacing or 0
    elseif zType == "EMP"        then return cfg.empSpacing        or 0
    elseif zType == "Glutton"    then return cfg.gluttonSpacing    or 0
    elseif zType == "Scavenger"  then return cfg.scavengerSpacing  or 0
    end
    return 0
end

local function svTypeEnabled(cfg, zType)
    if     zType == "Screamer"   then return cfg.screamerEnabled
    elseif zType == "Juggernaut" then return cfg.juggernautEnabled
    elseif zType == "EMP"        then return cfg.empEnabled
    elseif zType == "Glutton"    then return cfg.gluttonEnabled
    elseif zType == "Scavenger"  then return cfg.scavengerEnabled
    end
    return false
end

-- Weighted type lottery. File-scope (was a closure inside svCheckZombie) so
-- the summon hook below can run the exact same funnel math.
local function svRollWeightedType(cfg, isIndoor)
    local weightedTypes = {}
    local totalWeight = 0

    local function addWeight(enabled, zType, weight)
        local safeWeight = tonumber(weight) or 0
        if enabled and safeWeight > 0 then
            weightedTypes[#weightedTypes + 1] = { zType = zType, weight = safeWeight }
            totalWeight = totalWeight + safeWeight
        end
    end

    addWeight(cfg.gluttonEnabled, "Glutton", cfg.gluttonWeight)
    addWeight(cfg.empEnabled and not isIndoor, "EMP", cfg.empWeight)
    addWeight(cfg.juggernautEnabled, "Juggernaut", cfg.juggernautWeight)
    addWeight(cfg.screamerEnabled, "Screamer", cfg.screamerWeight)
    addWeight(cfg.scavengerEnabled, "Scavenger", cfg.scavengerWeight)

    if totalWeight <= 0 then
        return nil
    end

    local rollCeiling = totalWeight > 100 and totalWeight or 100
    local roll = ZombRand(rollCeiling)
    local cursor = 0
    for i = 1, #weightedTypes do
        local entry = weightedTypes[i]
        cursor = cursor + entry.weight
        if roll < cursor then
            return entry.zType
        end
    end

    return nil
end

-- The engagement gate: engaged = has a live chase target; observed = visible
-- player within GUARD_RANGE. The range check is 2D on purpose -- a player one
-- floor up/down still counts, which is what keeps upstairs zombies from
-- converting in your face given the conversion scan itself is single-z.
-- Ghost/invisible admins don't count (isAnyPlayerInRange already skips them):
-- they're watching the funnel, not playing in it.
local function svIsEngagedOrObserved(zombie)
    if zombie:getTarget() then return true end
    return RQSvShared.isAnyPlayerInRange(zombie, GUARD_RANGE)
end

-- Finalize a conversion whose type is already decided (fresh roll winner,
-- pending spacing retry, or admin action). Returns false when the same-type
-- spacing veto blocks it; skipSpacing bypasses that (debug mode / admin
-- convert, which are deliberate placements rather than organic spawns).
local function svTryConvert(zombie, cfg, zType, skipSpacing)
    if not skipSpacing and not svCanSpawnHere(zombie, zType, svTypeSpacing(cfg, zType)) then
        return false
    end
    zombie:getModData()["RQPendingType"] = nil
    svMarkZombie(zombie, zType)
    RQSvShared.svApplyTypeHealth(zombie, cfg, zType)
    if zType == "Juggernaut" then
        zombie:getModData()["RQJuggMaxHP"] = zombie:getHealth()
        zombie:transmitModData()
    elseif zType == "Glutton" or zType == "Scavenger" then
        zombie:getModData()["RQGluttonBaseHealth"] = zombie:getHealth()
        zombie:transmitModData()
    end
    return true
end

-- Summoned zombies (screamer / boss scream waves) burn their ticket at birth
-- -- the positional window in svCheckAndMarkSummoned becomes a fallback for
-- spawn calls that fail to return the zombie list -- AND get the same
-- one-shot funnel roll as any organic zombie, so a scream can call in
-- something worse. Newborns convert immediately, bypassing the engagement
-- gate on purpose: that gate exists to stop zombies TRANSFORMING in front of
-- a player, and a summon that arrives already-special never transformed in
-- front of anyone. Spacing still applies (a fresh Screamer can't stack on its
-- summoner); a spacing veto parks the win in RQPendingType as usual.
RQSvShared.onSummonSpawned = function(zombie)
    if not zombie then return end
    local md = zombie:getModData()
    if md["RQRolled"] or md["RQConverted"] then return end
    md["RQRolled"] = true
    local cfg = RQSvShared.getSvConfig()
    if not cfg.enabled then return end
    cfg = RQPhunZones.getEffectiveRules(zombie, nil, cfg)
    if ZombRand(100) >= cfg.spawnChance then return end
    local sq       = zombie:getSquare()
    local isIndoor = sq and sq:isInARoom()
    local zType = svRollWeightedType(cfg, isIndoor)
    if not zType then return end
    if not svTryConvert(zombie, cfg, zType, false) then
        md["RQPendingType"] = zType
    end
end

-- ========================
-- Snapshot builder (ModData-based sync)
-- ========================
-- Sends a canonical state table to all clients every ~2 seconds when dirty.
-- Clients reconcile their local registry against this snapshot.

-- Pure comparison - no external deps, so it stays exactly as-is.
local function svRowChanged(prev, cur)
    if not prev then return true end
    if prev.zType        ~= cur.zType        then return true end
    if prev.alive        ~= cur.alive        then return true end
    if prev.phase        ~= cur.phase        then return true end
    if prev.castDue      ~= cur.castDue      then return true end
    if prev.castDuration ~= cur.castDuration then return true end
    if prev.castLabel    ~= cur.castLabel    then return true end
    if prev.castRadius   ~= cur.castRadius   then return true end
    if prev.castRingId   ~= cur.castRingId   then return true end
    if prev.eatCount     ~= cur.eatCount     then return true end
    if prev.hostile      ~= cur.hostile      then return true end
    if prev.enraged      ~= cur.enraged      then return true end
    if prev.currentHP    ~= cur.currentHP    then return true end  -- bucketed, not raw
    if prev.peakHP       ~= cur.peakHP       then return true end  -- scav gradient denominator
    if prev.bossSkill    ~= cur.bossSkill    then return true end
    -- Bucketed compare, not raw tiles -- see POS_BUCKET. Floor is on the same
    -- floor as the z check: a floor change is always worth shipping.
    if math.floor(prev.x / POS_BUCKET) ~= math.floor(cur.x / POS_BUCKET)
    or math.floor(prev.y / POS_BUCKET) ~= math.floor(cur.y / POS_BUCKET)
    or prev.z ~= cur.z then return true end
    return false
end

-- Rebuilds the full authoritative md.active table and returns a DELTA describing
-- what changed since the last snapshot -- { revision, serverTime, changed = {idStr->row},
-- removed = {idStr,...} } -- or nil when nothing client-visible changed. "Changed"
-- means any field tracked by svRowChanged (notably position-bucket changes, the common
-- case as zombies move) or a brand-new row; "removed" means a row that vanished. The
-- caller broadcasts the delta; md.active is committed only when something changed.
local function svBuildSnapshot()
    local md = ModData.getOrCreate("RQZombieState")
    local prevActive = md.active or {}
    local newActive  = {}
    local now = getTimestampMs()
    local cfg = RQSvShared.getSvConfig()
    local changedRows = {}      -- idStr -> row, only rows added or visibly changed (the delta payload)
    local anyChange   = false

    for zombie, zType in pairs(svActiveZombies) do
        if not zombie:isDead() then
            local oid = zombie:getOnlineID()
            if oid then
                local idStr = tostring(oid)
                local row = {
                    id    = oid,
                    zType = zType,
                    x     = math.floor(zombie:getX()),
                    y     = math.floor(zombie:getY()),
                    z     = math.floor(zombie:getZ()),
                    alive = true,
                }

                -- Type-specific enrichment
                if zType == "Screamer" then
                    local st = RQSvScreamer.state[oid]
                    if st and st.castDue and st.castDue > now then
                        row.castDue      = st.castDue
                        row.castDuration = cfg.screamerCastTime
                        row.castLabel    = "Screaming..."
                        row.castRadius   = math.min(cfg.screamerSoundRadius, 15)
                        row.castRingId   = "screamer_" .. idStr
                    end

                elseif zType == "Glutton" then
                    local gt = RQSvGlutton.state[oid]
                    if gt then
                        row.phase    = gt.phase
                        row.eatCount = gt.eatCount
                        if gt.castDue and gt.castDue > now then
                            row.castDue      = gt.castDue
                            row.castDuration = cfg.devourTime
                            row.castLabel    = "Devouring..."
                            row.castRadius   = cfg.gluttonRadius
                            row.castRingId   = "glutton_" .. idStr
                        end
                    end

                elseif zType == "Boss" then
                    local bt = RQSvBoss.state[oid]
                    if bt then
                        row.bossSkill = bt.currentSkill
                        if bt.castDue and bt.castDue > now then
                            row.castDue      = bt.castDue
                            row.castDuration = cfg.bossCastTime
                            row.castLabel    = RQSvShared.BOSS_SKILL_LABELS[bt.currentSkill] or "..."
                            local skill = bt.currentSkill
                            if     skill == "Scream"  then row.castRadius = math.min(cfg.screamerSoundRadius, 15)
                            elseif skill == "Buff"    then row.castRadius = cfg.juggernautBuffRadius
                            elseif skill == "EMPulse" then row.castRadius = cfg.empRadius
                            else                           row.castRadius = 0
                            end
                            row.castRingId = (skill == "EMPulse")
                                and ("boss_emp_" .. idStr)
                                or  ("boss_"     .. idStr)
                        end
                    end

                elseif zType == "Scavenger" then
                    local sc = RQSvScavenger.state[oid]
                    if sc then
                        row.phase      = sc.phase
                        row.hostile    = sc.hostile
                        row.enraged    = sc.hostile  -- client gradient uses this
                        -- Bucket currentHP/peakHP to nearest integer for snapshot churn
                        -- protection. The previous /5*5 bucket floored small-HP scavs
                        -- (base/peak < 5) to zero, which made the client's bar code fall
                        -- back to "no peakHP info" mode and never reflect the rage balloon.
                        -- Integer buckets are still coarse enough to suppress sub-tick
                        -- decay noise without losing visible HP granularity.
                        row.currentHP  = math.floor(zombie:getHealth())
                        row.peakHP     = math.floor(sc.peakHP or 0)
                        row.baseHealth = sc.baseHealth
                        if sc.castDue and sc.castDue > now then
                            row.castDue      = sc.castDue
                            row.castDuration = cfg.devourTime
                            row.castLabel    = "Scavenging..."
                            row.castRadius   = RQSvShared.SCAV_CORPSE_RADIUS
                            row.castRingId   = "scav_" .. idStr
                        end
                    end
                end
                -- EMP and Juggernaut have no extra behavior state to snapshot

                -- Per-row revision: only bump when client-visible state changed.
                -- Changed/added rows (svRowChanged is true for a nil prev) go into
                -- the delta; unchanged rows keep their rev and stay out of it.
                local prev = prevActive[idStr]
                if svRowChanged(prev, row) then
                    row.rev            = (prev and prev.rev or 0) + 1
                    row.updatedAt      = now
                    changedRows[idStr] = row
                    anyChange          = true
                else
                    row.rev       = prev.rev
                    row.updatedAt = prev.updatedAt
                end

                newActive[idStr] = row
            end
        end
    end

    -- Rows that vanished (zombie died/cleared) become explicit removals in the delta.
    local removed      = {}
    local removedCount = 0
    for idStr in pairs(prevActive) do
        if not newActive[idStr] then
            removedCount = removedCount + 1
            removed[removedCount] = idStr
            anyChange = true
        end
    end

    if not anyChange then return nil end

    md.active     = newActive
    md.serverTime = now
    md.revision   = (md.revision or 0) + 1

    -- Steady-state sync sends only this delta, not the whole table. md.active above
    -- stays the full authoritative baseline that late joiners pull via ModData
    -- (request on join / transmit on connect); the delta carries just the churn.
    return {
        revision   = md.revision,
        serverTime = now,
        changed    = changedRows,   -- idStr -> full row, only for changed/added zombies
        removed    = removed,       -- list of idStr no longer active
    }
end

-- ========================
-- Zombie conversion (server scan)
-- ========================

local function svCheckZombie(zombie)
    if svActiveZombies[zombie] then return end

    local md = zombie:getModData()

    -- adminReroll refund pass: wipe this zombie's roll verdicts so the visit
    -- below re-rolls it fresh. Only ever non-nil during the command's
    -- synchronous sweep; converted specials never reach here (skipped above).
    if svRefundSeen and not svRefundSeen[zombie] then
        svRefundSeen[zombie] = true
        if md["RQRolled"] or md["RQPendingType"] then
            svRefundCount = svRefundCount + 1
            md["RQRolled"]      = nil
            md["RQPendingType"] = nil
        end
    end

    -- Dragging a corpse reanimates it into a live IsoZombie (engine path:
    -- IsoDeadBody.Grappled -> reanimateZombieForGrapple), and that husk inherits
    -- the dead special's modData (RQConverted/RQType are copied onto the dead body
    -- and back onto the reanimated zombie). Without this guard, the RQConverted
    -- recovery path below re-adopts it as a special and the behavior tick resumes
    -- on a body you drag around -- a screamer becomes a portable siren, a
    -- glutton/scavenger an evil broom that eats corpses on contact. These husks
    -- exist ONLY to be dragged (isReanimatedForGrappleOnly); never track them.
    if zombie:isReanimatedForGrappleOnly() then
        -- Grapple-only is a permanent property of the husk: safe to burn.
        md["RQRolled"]      = true
        md["RQPendingType"] = nil
        return
    end

    -- Phase 1 dormant probe (LOG-ONLY): would a freshly realized zombie here
    -- have adopted a dormant record? Emits drift + outfit-match data to
    -- calibrate ADOPT_RADIUS before Phase 2 turns adoption on. Must stay
    -- side-effect free -- the zombie falls through to the normal roll path.
    if not md["RQConverted"] and not RQSvDormant.isEmpty() then
        RQSvDormant.probeMatch(zombie:getX(), zombie:getY(), zombie:getZ(),
                               zombie:getPersistentOutfitID())
    end

    -- Save/chunk reload recovery: zombie was already converted, just restore tracking
    if md["RQConverted"] then
        md["RQPendingType"] = nil
        local savedType = md["RQType"]
        if savedType then
            svActiveZombies[zombie] = savedType
            svRememberZombie(zombie, savedType)
            -- Dormant registry: this branch bypasses svMarkZombie, so reloaded
            -- specials mint their pid + record here.
            svDormantTrack(zombie, savedType)
            -- Scavengers are always aggressive to players; no setUseless on reload.
            if savedType == "Boss" then
                RQSvShared.applyBossSprinter(zombie)
            end
            -- Backfill max HP for Juggernauts converted before mitigation was added
            if savedType == "Juggernaut" and not md["RQJuggMaxHP"] then
                md["RQJuggMaxHP"] = zombie:getHealth()
                zombie:transmitModData()
            end
            -- Backfill baseHealth for Glutton/Scavenger when modData is missing on reload.
            -- Without this, the first tick sets state.baseHealth = curHP and a raging scav
            -- at 5-15x base anchors its decay floor at the inflated value, effectively
            -- breaking the rage-decay timer forever. We don't have the true base post-hoc,
            -- so divide current by the type's HEALTH_MULTIPLIER as a best guess. Wrong if
            -- the zombie has been buffed/eaten/decayed since spawn, but better than nothing.
            if (savedType == "Glutton" or savedType == "Scavenger") and not md["RQGluttonBaseHealth"] then
                local mult = RQSvShared.HEALTH_MULTIPLIER[savedType] or 1
                md["RQGluttonBaseHealth"] = zombie:getHealth() / mult
                zombie:transmitModData()
            end
        end
        return
    end

    -- Pending spacing retry: the roll is already spent, only re-test room.
    -- Runs before the summon check on purpose -- a pending zombie can never
    -- be a fresh summon (summons get rolled-marked at birth / on first scan,
    -- before they can ever park), and a screamer summoning nearby must not
    -- consume a parked winning roll via the positional summon match.
    local pendingType = md["RQPendingType"]
    if pendingType then
        -- A parked win stays parked while the zombie is engaged or watched.
        -- Without this, killing the local special frees the spacing slot and
        -- the zombie you're mid-fighting instantly becomes the replacement --
        -- the reported "it turned into a special after I engaged" bug.
        if svIsEngagedOrObserved(zombie) then return end
        local cfg = RQSvShared.getSvConfig()
        if not cfg.enabled then return end
        cfg = RQPhunZones.getEffectiveRules(zombie, nil, cfg)
        -- Re-check the type's enable flag: if an admin disabled the type
        -- since the roll, converting anyway would be the same disease this
        -- rework cures (transient state treated as a permanent verdict).
        if not svTypeEnabled(cfg, pendingType) then
            md["RQPendingType"] = nil   -- roll stays consumed (RQRolled is set)
            return
        end
        svTryConvert(zombie, cfg, pendingType, false)
        return
    end

    -- Ticket already consumed in this zombie's loaded lifetime.
    if md["RQRolled"] then return end

    if svCheckAndMarkSummoned(zombie) then return end
    if md.GhostServant then
        md["RQRolled"] = true
        return
    end

    local cfg = RQSvShared.getSvConfig()
    -- Deliberately no checked-mark here: "mod disabled" is world state, not
    -- a verdict on this zombie. If an admin enables Dirge mid-session the
    -- loaded population must still be rollable.
    if not cfg.enabled then return end

    -- PhunZones2 per-zone overrides (no-op if plugin not installed)
    cfg = RQPhunZones.getEffectiveRules(zombie, nil, cfg)

    local sq       = zombie:getSquare()
    local isIndoor = sq and sq:isInARoom()

    if cfg.debugMode then
        -- Debug converts everything, so no roll is consumed on a nil result:
        -- an admin can flip weights live and the very next scan picks them up.
        -- Deliberately ignores the engagement gate: debug placements are
        -- admin-driven tests, not organic spawns.
        local zType = svRollWeightedType(cfg, isIndoor)
        if not zType then return end
        md["RQRolled"] = true
        svTryConvert(zombie, cfg, zType, true)
        return
    end

    -- Engagement gate BEFORE the roll: nothing is consumed, the zombie just
    -- isn't a candidate until the fight moves off. See GUARD_RANGE above.
    if svIsEngagedOrObserved(zombie) then return end

    -- THE one-and-only spawn roll. The ticket is marked consumed here -- at
    -- the roll -- so both roll outcomes (fail, convert) are final, while the
    -- spacing veto below parks the winner for retry instead of burning it.
    md["RQRolled"] = true
    if ZombRand(100) >= cfg.spawnChance then return end

    local zType = svRollWeightedType(cfg, isIndoor)
    if not zType then return end

    if not svTryConvert(zombie, cfg, zType, false) then
        -- Spacing veto: another special of this type is too close right now.
        -- That is a fact about the moment, not about this zombie -- park the
        -- decided type and re-test on later scans until room frees up.
        md["RQPendingType"] = zType
    end
end

-- One full conversion sweep over every zombie within SCAN_RANGE of any
-- player. Shared by the interval tick below and the adminReroll command
-- (which wants its results synchronously, not on the next interval).
-- Returns the number of live zombies visited (overlapping player ranges can
-- visit a zombie twice; the guards make the second visit a no-op).
-- Exported for RQSvAdminCmds (adminReroll). These two are the only pieces of
-- this file's conversion machinery the admin plane needs; everything else it
-- uses already lives in RQSvShared.
RQServer = RQServer or {}

local function svRunConversionScan()
    local cell = getCell()
    if not cell then return 0 end

    local playerList = {}
    local online = getOnlinePlayers()
    if online and online:size() > 0 then
        for i = 0, online:size() - 1 do
            playerList[#playerList + 1] = online:get(i)
        end
    else
        local p = getPlayer()
        if p then playerList[1] = p end
    end
    if #playerList == 0 then return 0 end

    local visited = 0
    for _, player in ipairs(playerList) do
        if player then
            local px = math.floor(player:getX())
            local py = math.floor(player:getY())
            local pz = math.floor(player:getZ())
            for dx = -SCAN_RANGE, SCAN_RANGE do
                for dy = -SCAN_RANGE, SCAN_RANGE do
                    local sq = cell:getGridSquare(px + dx, py + dy, pz)
                    if sq then
                        local movs = sq:getMovingObjects()
                        if movs then
                            for i = 0, movs:size() - 1 do
                                local obj = movs:get(i)
                                if obj and instanceof(obj, "IsoZombie") and not obj:isDead() then
                                    svCheckZombie(obj)
                                    visited = visited + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return visited
end

RQServer.svTryConvert        = svTryConvert
RQServer.svRunConversionScan = svRunConversionScan

local function svConversionTick()
    svTickCount = svTickCount + 1
    if svTickCount < SCAN_INTERVAL then return end
    svTickCount = 0
    svRunConversionScan()
end

-- ========================
-- Client command handling
-- ========================
--
-- The admin type whitelist and spawn cap moved to RQSvAdminCmds with the
-- commands that used them.

-- reflectPing per-player gap (username-keyed: exact SteamIDs are lossy in
-- server-side Lua). Any client may ping; the answer is read-only state. Pruned
-- on disconnect below - it used to grow one entry per distinct player seen, for
-- the lifetime of the server.
local svReflectPingAt = {}

-- Ceiling on the eater-arrival queue between tick drains. Each pending entry
-- costs a linear scan of the active-special registry when it drains, so this is
-- a bound on tick-thread work, not on packets. Comfortably above what every
-- eater on a busy server reports in one tick.
local MAX_PENDING_EATER_ARRIVALS = 256

-- ---------------------------------------------------------------------------
-- Inbound commands, player plane.
--
-- The admin verbs used to live here too, inline, in one 433-line anonymous
-- listener; they are now RQSvAdminCmds.lua. These three stayed because they
-- read and write this file's own state - svProcessedDeaths, svDeathCache,
-- svPids, the snapshot - and exporting three mutable tables to make a file
-- boundary look tidier would trade a real invariant for a cosmetic one.
--
-- All three are ungated on purpose and always were: they are reports from an
-- ordinary player's client about zombies that client owns. What they lacked was
-- a limiter and, in two cases, a server-owned source of truth for the values
-- they act on. Both arrive here.
-- ---------------------------------------------------------------------------

-- Reflection probe (client half: RQReflect.lua). A client is asking "which
-- specials does the server believe are near me RIGHT NOW?". Answer with
-- authoritative rows AND log the same rows server-side, so the truth survives
-- even if the response packet never lands.
--
-- The 3s per-player gap is DOMAIN policy and stays here. RDNet's rate is a
-- per-second ceiling - RDRate is called with a fixed 1000ms window - so the
-- strictest thing registration can express is 1/s, and this endpoint wants to
-- be six times stricter than that. RDNet's bucket sits behind it as the flood
-- backstop; this is the actual policy.
--
-- The table used to leak: keyed by username, never evicted on disconnect or on
-- OnGameStart, so it grew one entry per distinct player for the lifetime of the
-- server. It is pruned on disconnect now.
local function hReflectPing(player, args)
    local pingNow = getTimestampMs()
    local uname   = player and player:getUsername() or "?"
    if svReflectPingAt[uname] and pingNow - svReflectPingAt[uname] < 3000 then return end
    svReflectPingAt[uname] = pingNow
        -- Reflection probe (client half: RQReflect.lua). A client is asking
        -- "which specials does the server believe are near me RIGHT NOW?".
        -- Answer with authoritative rows AND log the same rows server-side,
        -- so the truth survives even if the response packet never lands.

        local px, py, pz = 0, 0, 0
        if player then px, py, pz = player:getX(), player:getY(), player:getZ() end
        -- client-reported position rides along; disagreement with the server's
        -- own view of the player is itself a sync-health datapoint
        local cx = tonumber(args and args.x) or px
        local cy = tonumber(args and args.y) or py
        local pdx, pdy = px - cx, py - cy
        local posDrift = math.sqrt(pdx * pdx + pdy * pdy)

        local md    = ModData.getOrCreate("RQZombieState")
        local rows  = {}
        local nRows = 0
        local total = 0
        for zombie, zType in pairs(svActiveZombies) do
            total = total + 1
            if not zombie:isDead() then
                local oid = zombie:getOnlineID()
                local zx  = zombie:getX()
                local zy  = zombie:getY()
                local zz  = zombie:getZ()
                if oid then
                    local dx, dy = zx - px, zy - py
                    local dist = math.sqrt(dx * dx + dy * dy)
                    -- 48 tiles: comfortably past the client's 30-tile sample
                    -- radius, so "server-only" rows can't be range artifacts
                    if dist <= 48 and nRows < 32 then
                        local rowMd = md.active and md.active[tostring(oid)]
                        nRows = nRows + 1
                        rows[nRows] = {
                            id    = oid,
                            zType = zType,
                            x     = math.floor(zx),
                            y     = math.floor(zy),
                            z     = math.floor(zz),
                            dist  = math.floor(dist * 10) / 10,
                            -- snapshot-row staleness: how old is the position
                            -- the delta channel last shipped for this zombie?
                            rev   = rowMd and rowMd.rev or -1,
                            ageMs = (rowMd and rowMd.updatedAt) and (pingNow - rowMd.updatedAt) or -1,
                        }
                    end
                end
            end
        end

        if RQReflectLog then
            local lines = {}
            lines[1] = string.format(
                "PING from=%s reason=%s clientPos=(%.0f,%.0f) serverPos=(%.0f,%.0f,%.0f) posDrift=%.1f totalActive=%.0f nearRows=%.0f",
                tostring(uname), tostring(args and args.reason), cx, cy, px, py, pz, posDrift, total, nRows)
            for i = 1, nRows do
                local r = rows[i]
                lines[#lines + 1] = string.format(
                    " TRUTH id=%s type=%s pos=(%.0f,%.0f,%.0f) dist=%.1f rev=%s ageMs=%s",
                    tostring(r.id), r.zType, r.x, r.y, r.z, r.dist, tostring(r.rev), tostring(r.ageMs))
            end
            RQReflectLog.writeAll(lines)
        end

        RQSvShared.sendToPlayer(player, "reflectTruth", {
            serverTime  = pingNow,
            clientTs    = args and args.clientTs,
            reason      = args and args.reason,
            totalActive = total,
            px          = math.floor(px),
            py          = math.floor(py),
            posDrift    = math.floor(posDrift * 10) / 10,
            rows        = rows,
        })
        return
end

-- An owned eater reports that it reached its corpse.
local function hEaterArrived(player, args)
    -- The queue is BOUNDED, and that is the repair. Every entry costs a linear
    -- scan of svActiveZombies when it drains (RQSvShared.svFindActiveZombieByOnlineID),
    -- so an unbounded append let one client turn N packets into N scans on the
    -- tick thread. The content was never the weak part - svProcessEaterArrival
    -- already checks type, phase, target square and exact corpse coordinates
    -- against the server's own state, and rejects anything that disagrees.
    --
    -- Dedup on onlineID as well: a client latches arrivedSent (RQGlutton.lua:149)
    -- so an honest sender reports once, which means a second entry for the same
    -- zombie in the same drain window is either a resend or a forgery. Either
    -- way the first one is the one that matters.
    local q = RQSvEating.svPendingEaterArrivals
    if #q >= MAX_PENDING_EATER_ARRIVALS then return end

    local onlineID = tonumber(args and args.onlineID)
    if not onlineID then return end
    for i = 1, #q do
        if q[i].onlineID == onlineID then return end
    end

    q[#q + 1] = {
        onlineID = onlineID,
        corpseX  = tonumber(args.corpseX),
        corpseY  = tonumber(args.corpseY),
        corpseZ  = tonumber(args.corpseZ),
    }
end

-- A client reports one of its specials died. The report is a HINT, never a
-- fact: the server confirms the zombie is real, is dead, and is the type it
-- believes, before any of this has an effect.
local function hZombieKilled(player, args)

    local onlineID = tonumber(args.onlineID)
    if not onlineID then return end

    -- Dedup: process each zombie death only once
    local onlineIDStr = tostring(onlineID)
    if svProcessedDeaths[onlineIDStr] then return end

    -- THE SCAN ORIGIN PREFERS SERVER STATE, and only falls back to the wire.
    --
    -- Three sources, best first. svDeathCache is written at conversion time and
    -- refreshed on every sighting, so it is authoritative and carries zType.
    -- Failing that, the active-special registry resolves the id with no
    -- coordinates at all. Only if neither knows the id do the client's coordinates
    -- get used - and then only COERCED, because they are the centre of a 17x17
    -- getGridSquare sweep and an unfloored value makes every lookup in it
    -- fractional. adminSpawnSpecial already did exactly this coercion; these two
    -- never got it.
    --
    -- The wire fallback is deliberately KEPT rather than removed. It looks
    -- redundant - the object below overwrites x/y/z from server state the moment
    -- it is found - but the scan is also the only path that recovers zType for a
    -- special that has left svActiveZombies and survives only as RQType in its own
    -- modData (see the resolution below). Dropping the fallback would silently
    -- stop processing those deaths: no loot, no chronicle record, no dormant
    -- retirement, no EMP detonation. A narrow path, but a real one, and its
    -- failure mode is a ghost special that never retires.
    local cached = svDeathCache[onlineID]
    if not cached then
        local live = RQSvShared.svFindActiveZombieByOnlineID(onlineID)
        if live then
            cached = { x = math.floor(live:getX()), y = math.floor(live:getY()),
                       z = math.floor(live:getZ()) }
        end
    end

    local x      = cached and cached.x or math.floor(tonumber(args.x) or 0)
    local y      = cached and cached.y or math.floor(tonumber(args.y) or 0)
    local z      = cached and cached.z or math.floor(tonumber(args.z) or 0)
    local zType  = cached and cached.zType or nil

    local cell     = getCell()
    local lootDone = false
    local deadObj  = nil
    if cell then
        if onlineID then
            for dx2 = -8, 8 do
                if lootDone then break end
                for dy2 = -8, 8 do
                    if lootDone then break end
                    local sq = cell:getGridSquare(x + dx2, y + dy2, z)
                    if sq then
                        local movs = sq:getMovingObjects()
                        if movs then
                            for i = 0, movs:size() - 1 do
                                local obj = movs:get(i)
                                if obj and instanceof(obj, "IsoZombie")
                                   and obj:getOnlineID() == onlineID then
                                    -- A kill report must describe a DEAD zombie. Without
                                    -- this, a spoofed zombieKilled on a LIVING special
                                    -- fires real death effects (EMP detonation) and
                                    -- poisons svProcessedDeaths so its genuine death is
                                    -- later swallowed. Bail before loot/effects/dedup so
                                    -- the real death report still processes normally.
                                    if not obj:isDead() then return end
                                    deadObj = obj
                                    -- Prefer live server object state; fall back to ID cache after corpse cleanup
                                    zType = svActiveZombies[obj] or obj:getModData()["RQType"] or zType
                                    if zType then
                                        x = math.floor(obj:getX())
                                        y = math.floor(obj:getY())
                                        z = math.floor(obj:getZ())
                                        svDeathCache[onlineID] = {
                                            zType     = zType,
                                            x         = x,
                                            y         = y,
                                            z         = z,
                                            updatedAt = getTimestampMs(),
                                        }
                                    end
                                    RQSvLoot.drop(obj, zType)
                                    lootDone = true
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Only server-confirmed type triggers death effects
    if not zType then return end
    svProcessedDeaths[onlineIDStr] = getTimestampMs()

    -- Chronicle: one record per server-confirmed special death, attributed to
    -- the reporting client (the zombie's owning client - the killer in
    -- practice). Sits after the liveness guard and the dedup stamp, so a
    -- spoofed or duplicate report can never mint a record.
    RDLog.chronicle("RQ.SPECIAL_KILL", player, { ztype = zType, x = x, y = y, z = z })

    -- Dormant registry: a server-confirmed death retires the record. The tick
    -- cleanup would catch it anyway; doing it here closes the window where a
    -- dead special's record could linger as an adoption candidate.
    if deadObj then
        local pid = svPids[deadObj]
        if pid then
            RQSvDormant.remove(pid)
            svPids[deadObj] = nil
        end
    end

    -- Death effects
    if zType == "EMP" then
        local cfg    = RQSvShared.getSvConfig()
        local ringId = "emp_" .. x .. "_" .. y
        RQSvShared.broadcast("castStart", RQSvShared.makeCastArgs(ringId, x, y, z,
            cfg.empCastTime, RQSvShared.COLORS.EMP, "EMP Detonating...", cfg.empRadius))
        RQSvShared.scheduleAction(cfg.empCastTime, function()
            RQSvShared.broadcast("castDone", { ringId = ringId, fixedX = x, fixedY = y, fixedZ = z, radius = cfg.empRadius })
            RQSvShared.svApplyEMPBlast(x, y, z, cfg.empRadius, cfg.empBatteryDrain)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Registration.
--
-- Rates come from the 2026-08-18 live capture, with burst headroom on top. The
-- measured figures are all-sender aggregates over 78.7h - eaterArrived 52.9/h
-- across 80 senders, zombieKilled 47.6/h across 82 - which averages under 1/h
-- each. Averages are the wrong shape for the limit though: kills and eater
-- arrivals come in flurries during a horde, and a ceiling set near the mean
-- would refuse honest players at exactly the moment the mod is busiest. These
-- are set well above any plausible burst and bound only a scripted client.
--
-- public = true on all three: they are reports from ordinary players' clients
-- and gating them would silence the traffic the features are built on. That is
-- a declaration, not an oversight - see RDNet.register.
-- ---------------------------------------------------------------------------

RDNet.register(RQCommon.MODULE, "reflectPing",  { public = true, rate = 2  }, hReflectPing)   -- real policy is the 3s gap in the handler
RDNet.register(RQCommon.MODULE, "eaterArrived", { public = true, rate = 20 }, hEaterArrived)
RDNet.register(RQCommon.MODULE, "zombieKilled", { public = true, rate = 20 }, hZombieKilled)

-- ========================
-- Main OnTick (Server)
-- ========================

local function svOnTick()
    -- Drain the shared delayed-action queue
    RQSvShared.processPending()

    -- Process eater arrivals buffered this tick
    RQSvEating.processPendingArrivals()

    local now = getTimestampMs()

    -- Periodic cleanup of processed deaths table (prevents unbounded growth)
    deathCleanupTimer = deathCleanupTimer + 1
    if deathCleanupTimer >= DEATH_CLEANUP_INTERVAL then
        deathCleanupTimer = 0
        local cutoff  = now - 300000  -- 5 minutes
        local toDelete = {}
        local delCount = 0
        for k, ts in pairs(svProcessedDeaths) do
            if ts < cutoff then
                delCount = delCount + 1
                toDelete[delCount] = k
            end
        end
        for i = 1, delCount do
            svProcessedDeaths[toDelete[i]] = nil
        end
        for id, row in pairs(svDeathCache) do
            if not row.updatedAt or row.updatedAt < cutoff then
                svDeathCache[id] = nil
            end
        end
        -- Dormant registry expiry + hard cap, on the same cadence.
        RQSvDormant.sweep()
        -- (No pending-spacing sweep anymore: parked wins live in zombie
        -- modData, which dies with the zombie -- nothing to leak.)
    end

    -- Corpse reservation sweep (~10 seconds)
    svReservationCleanupTimer = svReservationCleanupTimer + 1
    if svReservationCleanupTimer >= 600 then
        svReservationCleanupTimer = 0
        RQSvEating.svCleanReservations()
    end

    -- Periodic config refresh in case sandbox vars changed mid-game
    svConfigRefreshTimer = svConfigRefreshTimer + 1
    if svConfigRefreshTimer >= 3600 then
        svConfigRefreshTimer = 0
        RQSvShared.clearSvConfig()
    end

    -- Juggernaut buff is expensive so we only run it every ~2 seconds
    svJuggBuffTick = (svJuggBuffTick or 0) + 1
    local doJuggBuff = svJuggBuffTick >= 120
    if doJuggBuff then svJuggBuffTick = 0 end

    -- Iterate alive special zombies and dispatch to type modules
    local cleanupCount = 0
    for zombie, zType in pairs(svActiveZombies) do
        local dead = zombie:isDead()
        local gid  = zombie:getOnlineID()
        -- Defensive: a dragged corpse reanimates into a grapple-only husk
        -- (isDead()=false, health>0) that inherits modData. svCheckZombie blocks
        -- it from ever being adopted, but if one slips in, evict it like a dead
        -- zombie so its scream/eat cast rings get cleared too.
        local grappleOnly = zombie:isReanimatedForGrappleOnly()
        -- Stale Java refs come back isDead()=false but getOnlineID()=-1 forever.
        -- Evict them so they don't sit as permanently inert entries.
        -- Use gid == -1 (not gid < 0) - B42 assigns valid negative IDs like -31580.
        if dead or grappleOnly or (not gid or gid == -1) then
            cleanupCount = cleanupCount + 1
            svToCleanup[cleanupCount] = zombie
            -- Genuine death (or a grapple husk that should never have a record)
            -- deletes the dormant record; a stale ref (vanished without dying,
            -- i.e. the virtualization moment) keeps it as an adoption candidate.
            svToCleanupDead[cleanupCount] = dead or grappleOnly
        else
            svRememberZombie(zombie, zType)
            svDormantTrack(zombie, zType)
            if zombie:getHealth() > 0 then
                if zType == "Screamer" then
                    RQSvScreamer.tick(zombie)
                elseif zType == "Juggernaut" then
                    if doJuggBuff then RQSvJuggernaut.tick(zombie) end
                elseif zType == "Glutton" then
                    RQSvGlutton.tick(zombie)
                elseif zType == "Boss" then
                    RQSvBoss.tick(zombie)
                elseif zType == "Scavenger" then
                    RQSvScavenger.tick(zombie)
                end
                -- EMP has no alive behavior; it detonates on death via zombieKilled
            end
        end
    end

    -- Safe delete after iteration finishes
    for i = 1, cleanupCount do
        local zombie = svToCleanup[i]
        svToCleanup[i] = nil
        -- Dormant registry hand-off. demote() only touches the record's own
        -- cached fields -- per the pooling doc this ref may already be a
        -- recycled, different zombie, so its live position must not be read.
        local pid = svPids[zombie]
        if pid then
            if svToCleanupDead[i] then
                RQSvDormant.remove(pid)
            else
                RQSvDormant.demote(pid)
            end
            svPids[zombie] = nil
        end
        svToCleanupDead[i] = nil
        local zid = zombie:getOnlineID()
        if zid then
            local sid = tostring(zid)
            RQSvScreamer.state[zid]  = nil
            RQSvBoss.state[zid]      = nil
            RQSvEMP.state[zid]       = nil
            if RQSvGlutton.state[zid] then
                RQSvEating.svClearEatingIntent(zombie)
                -- Co-eating: drop the dying zombie from any shared cast it was part of so
                -- survivors get the correct share count.
                RQSvEating.svRemoveEaterFromCast(RQSvGlutton.state[zid].targetCorpse, zid)
                RQSvEating.svRestoreAI(zombie)
                RQSvGlutton.state[zid] = nil
            end
            if RQSvScavenger.state[zid] then
                RQSvEating.svClearEatingIntent(zombie)
                RQSvEating.svRemoveEaterFromCast(RQSvScavenger.state[zid].targetCorpse, zid)
                RQSvEating.svRestoreAI(zombie)
                RQSvScavenger.state[zid] = nil
            end
            -- One packet, not seven. This sweep runs per EVICTION (deaths, stale
            -- Java refs and grapple husks all land here), so on a loaded cell the
            -- old form was the second-largest broadcast source in the mod. The
            -- client expands the id across every cast prefix -- see CAST_PREFIXES
            -- in RQCore.lua. Behaviour is identical: none of these seven ids could
            -- ever match castDone's EMP detonation regex, so no VFX is lost.
            RQSvShared.broadcast("castClearAll", { id = sid })
        end
        svActiveZombies[zombie] = nil
    end
    if cleanupCount > 0 then
        svSnapshotDirty = true
    end

    -- Conversion scan runs after behaviors so this-tick summons are
    -- already recorded before the next scan pass
    svConversionTick()

    -- Periodic snapshot pass (~2 seconds).
    svSnapshotTimer = svSnapshotTimer + 1
    if svSnapshotTimer >= 120 then
        svSnapshotTimer = 0
        -- Steady-state sync is a DELTA broadcast (RQ:zombieDelta): only the rows that
        -- changed since the last snapshot ride the wire, not the full table. This is
        -- the fix for RQZombieState's oversized full-table broadcasts; svBuildSnapshot
        -- returns the delta (or nil when nothing client-visible changed). Same-tick
        -- events (conversion/cleanup) set svSnapshotDirty -> they surface as a real
        -- diff on this pass, so the delta already carries them; just clear the flag.
        local delta = svBuildSnapshot()
        if delta then
            -- ---------------------------------------------------------------
            -- SIZE WATCH, added 2026-08-09. NOT a chunker, deliberately.
            --
            -- The 2026-08-08 wire capture put this key at 7,915 B against an
            -- 8,192 B alert ceiling - 96.6%, the mod's dominant key at 60.9% of
            -- its traffic, and the observed max is a FLOOR because the sampler
            -- was keeping 12 keys while up to 76 were live. It is the closest
            -- thing in the family to an oversize breach that has not happened.
            --
            -- The other three streams in that capture were paged onto RDChunk.
            -- This one was not, and the reason is protocol rather than effort:
            --
            --   * `changed` is a MAP keyed by id string, not an array, so it
            --     cannot be sliced without changing the wire shape on both sides.
            --   * `revision` drives the client's gap detector. It drops anything
            --     where revision <= lastRevision, so naive chunks all carrying one
            --     revision would apply the first and silently discard the rest -
            --     presenting as zombie desync, not as a transport fault.
            --   * A wrong fix here desyncs every zombie for every player, and it
            --     cannot be verified outside a live server.
            --
            -- So this MEASURES instead of guessing. Declaring a budget without
            -- paging would be worse than doing nothing: declareChunked makes a
            -- breach report as "this constant is wrong" instead of "go write a
            -- chunker", which is exactly the wrong instruction here.
            --
            -- What we get is the distribution rather than one sampled floor - how
            -- often it approaches the ceiling, and how big it gets at 39 players
            -- during a horde. That is what sizing the real fix needs.
            -- Authoritative send FIRST, telemetry after. The observer used to
            -- run first behind a pcall whose only job was to stop a telemetry
            -- fault eating this broadcast; ordering answers that outright and
            -- keeps answering it if the observer changes. broadcast does not
            -- touch the payload - it forwards to sendServerCommand
            -- (RQSvShared.lua:299-301) - so the delta it reads is identical.
            RQSvShared.broadcast("zombieDelta", delta)
            RQWireHeadroom.observe(delta)
        end
        svSnapshotDirty = false
    end
end

Events.OnTick.Add(svOnTick)

-- ========================
-- New player connected: resend full state
-- ========================

-- ModData.transmit fans the whole blob to EVERY connection, not just the joiner
-- (GlobalModData.transmit iterates udpEngine.connections; there is no
-- per-connection form). So N sequential joins after a restart used to fire N
-- all-connections broadcasts back to back -- a self-inflicted congestion spike
-- at exactly the moment the server is least able to absorb one. Coalesce them.
local svLastBaselineTransmit = 0
local svBaselineQueued       = false
local BASELINE_TRANSMIT_GAP  = 10000

-- Full snapshot for late-join recovery. This is the BASELINE channel: rebuild
-- md.active and push the whole table via ModData so joiners get complete state
-- in one shot. Steady-state churn after this rides the lighter delta broadcast
-- (svOnTick). We ignore svBuildSnapshot's delta return on purpose -- transmit
-- sends the full md.active regardless, which is what a fresh client needs.
local function svTransmitBaseline()
    svLastBaselineTransmit = getTimestampMs()
    svBaselineQueued       = false
    svBuildSnapshot()
    ModData.transmit("RQZombieState")
end

-- Drop a leaver's reflectPing gap so the table cannot grow without bound. The
-- arg shape differs by engine path - some builds pass the IsoPlayer, some a
-- username string - which is the same hedge DFServer and RDRate both carry.
local function onPlayerDisconnect(a)
    local name
    if type(a) == "string" then
        name = a
    elseif a and a.getUsername then
        name = a:getUsername()
    end
    if name then svReflectPingAt[name] = nil end
end
if Events.OnPlayerDisconnect then
    Events.OnPlayerDisconnect.Add(onPlayerDisconnect)
end

local function onPlayerConnect(player)
    -- The per-special zombieConverted unicast loop that used to live here is
    -- gone: RQReconcile.applyRow registers any unknown onlineID straight off the
    -- baseline this delivers, so those were one redundant packet per active
    -- special per join.
    --
    -- Coalesced, not dropped. A suppressed transmit would leave THAT joiner with
    -- no baseline (transmit has no per-connection form, so we can't serve one
    -- client alone), so an over-gap join queues a single trailing transmit
    -- instead. A burst of N joins therefore costs at most 2 broadcasts rather
    -- than N, and nobody waits on their own pull to see the world.
    local now = getTimestampMs()
    if now - svLastBaselineTransmit >= BASELINE_TRANSMIT_GAP then
        svTransmitBaseline()
    elseif not svBaselineQueued then
        svBaselineQueued = true
        RQSvShared.scheduleAction(BASELINE_TRANSMIT_GAP, svTransmitBaseline)
    end
end

-- Register player-connect handler defensively.
-- Events.OnClientConnect is null on B42 dedicated servers per TIS docs.
-- Events.OnPlayerConnect is the correct B42 hook. Register on whichever
-- exists; duplicate sends are harmless since the handler is idempotent.
local _rqConnectRegistered = {}

if Events.OnPlayerConnect then
    Events.OnPlayerConnect.Add(onPlayerConnect)
    _rqConnectRegistered[#_rqConnectRegistered + 1] = "OnPlayerConnect"
end

if Events.OnClientConnect then
    Events.OnClientConnect.Add(onPlayerConnect)
    _rqConnectRegistered[#_rqConnectRegistered + 1] = "OnClientConnect"
end

if #_rqConnectRegistered > 0 then
    print("[Dirge] Registered player-connect resync handler on: " ..
          table.concat(_rqConnectRegistered, ", "))
else
    print("[Dirge] WARNING: no player-connect event available; " ..
          "clients joining mid-game may miss initial special-zombie sync")
end

-- ========================
-- Game start: reset all state
-- ========================

Events.OnGameStart.Add(function()
    svActiveZombies   = setmetatable({}, { __mode = "k" })
    -- svPids resets with it; the RQDormant GMD table deliberately does NOT --
    -- surviving restarts is the whole feature. Live specials re-mint pids via
    -- the svCheckZombie recovery branch.
    svPids            = setmetatable({}, { __mode = "k" })
    svRefundSeen      = nil
    svRefundCount     = 0
    svDeathCache      = {}
    svProcessedDeaths = {}
    svTickCount       = 0
    deathCleanupTimer = 0
    svReservationCleanupTimer = 0
    svConfigRefreshTimer = 0
    svSnapshotTimer   = 0
    svSnapshotDirty   = false
    svJuggBuffTick    = 0
    -- Must clear alongside svPending below: a queued trailing transmit lives in
    -- that queue, so wiping the queue without clearing the flag would leave
    -- svBaselineQueued true forever and block every future coalesced transmit.
    svLastBaselineTransmit = 0
    svBaselineQueued       = false

    -- Reset shared module state
    RQSvShared.svPending        = {}
    RQSvShared.svPendingSummons = {}
    RQSvShared.clearSvConfig()

    -- Reinject fresh table into shared modules
    RQSvShared.setActiveZombies(svActiveZombies)
    RQSvJuggernaut.setActiveZombies(svActiveZombies)
    RQSvBoss.setActiveZombies(svActiveZombies)
    RQSvScavenger.setActiveZombies(svActiveZombies)

    -- Reset per-type module state
    RQSvEating.svPendingEaterArrivals = {}
    RQSvEating.svCorpseCast           = {}
    RQSvGlutton.state                 = {}
    RQSvScavenger.state               = {}
    -- State tables were replaced above, so re-inject the fresh refs into eating engine
    RQSvEating.setGluttonState(RQSvGlutton.state)
    RQSvEating.setScavengerState(RQSvScavenger.state)
    RQSvScreamer.state                = {}
    RQSvBoss.state                    = {}
    RQSvEMP.state                     = {}
    RQSvJuggernaut.buffed             = setmetatable({}, { __mode = "k" })
    RQSvBoss.buffed                   = setmetatable({}, { __mode = "k" })

    if not ModData.exists("RQZombieState") then
        ModData.create("RQZombieState")
    end
end)

-- Create the table at the earliest ModData hook too. OnGameStart is unreliable
-- server-side on a B42 dedicated server (same class of gotcha as the null
-- OnClientConnect this file already hedges), so a client's OnGameStart
-- ModData.request("RQZombieState") can land before OnGameStart created the table,
-- logging "received request for non-existing table". OnInitGlobalModData fires
-- early enough that the table always exists when requests arrive. Harmless if it
-- already exists; the connect-time transmit remains the real baseline path.
Events.OnInitGlobalModData.Add(function()
    if not ModData.exists("RQZombieState") then
        ModData.create("RQZombieState")
    end
end)

if getDebug() then
    print("[RQServer] Dirge server modules loaded")
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
