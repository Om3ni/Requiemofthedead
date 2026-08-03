-- RCSession - the lifecycle wiring (server only).
--
-- All of the registry's TIME behaviour lives here, kept bounded and
-- event/timer-driven (never WG's per-tick all-vehicles scan):
--   * heartbeat + activity stamping (so an online owner never expires)
--   * server-downtime credit on boot
--   * an hourly bounded pass that reconciles the index TOWARD loaded vehicles'
--     modData (self-heals the index, then applies inactivity expiry on
--     positive evidence). modData is the source of truth - this pass never
--     deletes a claim just because the index lacks it.

if not isServer() then return end

RCSession = RCSession or {}

-- Stamp every currently-online player's activity: claim rows (expiry clock)
-- AND the all-players presence map (the janitor's "player logged in" gate).
-- getOnlinePlayers() is a Java ArrayList (size/get, NOT the crash-prone
-- vehicle Set), bounded by the player count.
local function stampOnline()
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and p.getUsername then
            local name = p:getUsername()
            RCRegistry.stampSeen(name)
            RCRegistry.notePresence(name)
        end
    end
end

-- Iterate loaded vehicles safely. getCell():getVehicles() is a Set - iterating
-- it with get(i) crashes; :iterator() is the supported path. This runs at most
-- hourly, so it is NOT the banned per-tick scan.
local function forEachLoadedVehicle(fn)
    local cell = getCell and getCell()
    if not cell then return end
    local vs = cell:getVehicles()
    if not vs then return end
    local ok, it = pcall(function() return vs:iterator() end)
    if not ok or not it then return end
    while it:hasNext() do
        local v = it:next()
        if v then pcall(fn, v) end
    end
end

-- Heartbeat cadence: record liveness + keep online owners fresh.
Events.EveryTenMinutes.Add(function()
    if not RCShared.cfg().enabled then return end
    RCRegistry.heartbeat()
    stampOnline()
end)

-- Hourly reconcile + expiry pass. We stamp online players FIRST so no online
-- owner can ever be expired (closes the login race without a fragile connect
-- hook). Then we walk LOADED vehicles and reconcile the index toward each one's
-- modData: self-heal a missing index entry, and expire ONLY on positive
-- evidence (a persisted, genuinely-old lastSeen). A claimed car whose owner is
-- unloaded-and-elsewhere is reconciled/expired the next time this pass sees it
-- loaded. modData is truth: this never deletes a claim for a missing index.
Events.EveryHours.Add(function()
    if not RCShared.cfg().enabled or not RCShared.cfg().claimsEnabled then return end

    stampOnline()

    -- The Janitor (§5) rides THIS iteration - one pass serves reconcile,
    -- expiry, AND abandonment (never a second scan). Expiry runs first per
    -- vehicle, so a just-expired car is seen unclaimed and gets a fresh
    -- abandonment clock, not an instant reclaim.
    if RCJanitor then RCJanitor.beginSweep() end

    local expired = 0
    forEachLoadedVehicle(function(v)
        if RCRegistry.syncFromVehicle(v) == "expired" then expired = expired + 1 end
        if RCJanitor then RCJanitor.consider(v) end
        -- Destruction accounting (§4) rides the SAME iteration. B42 fires no
        -- vehicle-removal event, so a car that was intact last sweep and is a
        -- wreck now is how we learn a player destroyed one. Runs after
        -- consider() so a car reclaimed this pass is already gone and cannot
        -- be double-counted as a destruction.
        if RCRespawn then RCRespawn.observe(v) end
    end)
    if expired > 0 then RCShared.dbg("hourly pass: expired %d claim(s)", expired) end

    -- Redemption: spend a metered slice of the token pool back into the world.
    -- Last, so this hour's reclamations and destructions are already banked and
    -- a car can be reclaimed in one corner and replaced near a player in the
    -- same pass.
    if RCRespawn then RCRespawn.sweep() end

    -- After this hour's loaded cars have refreshed their `seen`, drop index
    -- entries for online owners whose cars haven't been confirmed in a long
    -- time (presumed-deleted). Index-only; never touches a claim's modData, so
    -- a still-real car just self-heals back in when it next loads.
    RCRegistry.pruneOrphans()

    -- Bound the deferred-release set (the one unbounded vector). Runs regardless
    -- of expiry - it's storage hygiene, not an expiry action.
    RCRegistry.prunePendingRelease()

    -- Presence-map hygiene (drop names not seen for 4x the widest window).
    RCRegistry.prunePresence()
end)

-- Boot: credit the downtime the server was off, then start a fresh heartbeat.
Events.OnServerStarted.Add(function()
    RCRegistry.creditDowntime()
    RCRegistry.heartbeat()
    -- Re-apply the admin's saved tuning overrides. Must happen AFTER global
    -- ModData has loaded (OnServerStarted is past OnInitGlobalModData), and
    -- before the first hourly pass, or the server would spend an hour running
    -- the raw sandbox values and then silently change behaviour.
    if RCTuning then RCTuning.apply(RCTuning.load()) end
    print("[RC] RCSession loaded (lifecycle active)")
end)
