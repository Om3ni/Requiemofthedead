-- RDLife.lua - player life-cycle instrumentation (server only).
--
-- Owns the family's ONLY player-ready poll. Trigger reality on a dedicated
-- server (proven the hard way in DFBanBox, whose header is the authoritative
-- record): OnPlayerUpdate does not fire server-side, OnConnected and
-- OnCreatePlayer bind but never fire on a remote join, and OnTick is the only
-- event proven to fire. So: a standing OnTick poll, throttled to ~1s, keyed by
-- onlineID, gated on BOTH getSquare() and getInventory(), with a 5-minute
-- per-player give-up so a stuck loader never causes repeated work, pruned on
-- both OnDisconnect and OnPlayerDisconnect. Consumer mods subscribe with
-- RDLife.onPlayerReady(fn) instead of building their own poll.
--
-- LIFE IDENTITY is minted at spawn, not lazily: RFTD_LifeId in player modData
-- (death wipes player modData, so a respawn reads as absent and starts a new
-- life). Format <epoch>-<onlineID>-<rand>; onlineID is in there because two
-- spawns in the same second collide on epoch+rand alone. Characters already
-- alive when Core is first installed also read as absent - those get
-- x.retro=true so a reader knows the life was in progress when recording
-- began, rather than inventing a spawn point.
--
-- That "a respawn reads as absent" only became TRUE in practice once the poll
-- learned to re-arm: respawning is not a reconnect, the onlineID does not
-- change, and the poll's own once-per-connection gate used to stop handleReady
-- from ever seeing the new character. See the block above poll() for the engine
-- evidence. Consequence for anyone reading old data: records written by a
-- respawned life before that fix carry "l":null, so any join on life id has to
-- treat null as "unknown life", not as a value.
--
-- DEATH: OnPlayerDeath NEVER fires on a dedicated server (IsoPlayer.OnDeath
-- returns early on GameServer.server, and the trigger is further gated by
-- isLocalPlayer). OnCharacterDeath fires via super.OnDeath() BEFORE that
-- return and is the only reachable hook - but it fires for EVERY character,
-- zombies and animals included, so the player guard is the first real
-- statement and does not allocate. Everything is read synchronously inside
-- the handler: removeSaveFile() runs after it, and this is the only moment
-- RFTD_LifeId is still readable. getAttackedBy() is valid here (the engine
-- itself uses it one line later for PVPLogTool.logKill).
-- SandboxVars.RFTDCore.DeathCaptureEnabled is the day-one kill switch; the
-- call-rate counter below exists so a horde night can be measured before the
-- hook is trusted.
--
-- KILLS are recorded at both SPAWN and DEATH, and per-life kills are the
-- delta. The server's kill counters are additively carried across lives by
-- the memoir recall on purpose - that is a gameplay rule, not a bug, so this
-- file works around it instead of "fixing" it.

if not isServer() then return end

RDLife = RDLife or {}

-- ---------------------------------------------------------------------------
-- Config / small helpers
-- ---------------------------------------------------------------------------

local function deathCaptureOn()
    local ok, v = pcall(function() return SandboxVars.RFTDCore and SandboxVars.RFTDCore.DeathCaptureEnabled end)
    if ok and v ~= nil then return v == true end
    return true
end

local function hoursSurvived(p)
    local ok, h = pcall(function() return p:getHoursSurvived() end)
    if ok and type(h) == "number" then return h end
    return 0
end

local function killsOf(p)
    local z, s = 0, 0
    pcall(function() z = p:getZombieKills() or 0 end)
    pcall(function() s = p:getSurvivorKills() or 0 end)
    return { zombies = z, survivors = s }
end

local function posOf(p)
    local x, y, z = -1, -1, -1
    pcall(function()
        x = math.floor(p:getX()); y = math.floor(p:getY()); z = math.floor(p:getZ())
    end)
    return x, y, z
end

-- Perk LEVELS, not raw XP: smaller, and levels are what a record of
-- progression should carry. Zero levels are skipped.
local function perkLevels(p)
    local out = {}
    pcall(function()
        for i = 0, PerkFactory.PerkList:size() - 1 do
            local perk = PerkFactory.PerkList:get(i)
            local t = perk:getType()
            if t ~= PerkFactory.Perks.None and t ~= PerkFactory.Perks.MAX then
                local lvl = p:getPerkLevel(t)
                if lvl and lvl > 0 then out[perk:getId()] = lvl end
            end
        end
    end)
    return out
end

local function traitsOf(p)
    local out = {}
    pcall(function()
        local known = p:getCharacterTraits():getKnownTraits()
        for i = 0, known:size() - 1 do
            out[#out + 1] = known:get(i):getName()
        end
        table.sort(out)
    end)
    return out
end

local function professionOf(p)
    local name
    pcall(function()
        local prof = p:getDescriptor() and p:getDescriptor():getCharacterProfession()
        if prof then name = prof:getName() end
    end)
    return name
end

-- Building bounding box at the player's square, so a coordinate can later be
-- resolved to "the house on the corner" rather than a bare point.
local function houseOf(p)
    local box
    pcall(function()
        local sq = p:getSquare()
        local b = sq and sq:getBuilding()
        local def = b and b:getDef()
        if def then
            box = { x1 = def:getX(), y1 = def:getY(), x2 = def:getX2(), y2 = def:getY2() }
        end
    end)
    return box
end

-- ---------------------------------------------------------------------------
-- Ready subscribers
-- ---------------------------------------------------------------------------

local readyFns = {}

-- fn(player) is called once per connection, after the player is genuinely
-- loaded in (square + inventory both present). Errors in one subscriber never
-- disturb another.
function RDLife.onPlayerReady(fn)
    if type(fn) == "function" then readyFns[#readyFns + 1] = fn end
end

-- ---------------------------------------------------------------------------
-- Spawn / login handling (runs on ready)
-- ---------------------------------------------------------------------------

-- A brand-new character has essentially zero survival hours; anything with
-- real hours behind it when we first see a missing life id was alive before
-- Core was installed (or before a wipe of the RFTD folder) - mark it retro.
local RETRO_HOURS = 1.0

local function mintLifeId(p)
    local rand = 0
    pcall(function() rand = ZombRand(100000000) end)
    local id = tostring(RDShared.nowSec()) .. "-" .. tostring(p:getOnlineID()) .. "-" .. tostring(rand)
    return id
end

local function helloSignature()
    local parts = {}
    for id, v in pairs(RDShared.mods) do parts[#parts + 1] = id .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function handleReady(p)
    local md
    pcall(function() md = p:getModData() end)
    if not md then return end

    if md.RFTD_LifeId then
        local x, y, z = posOf(p)
        RDLog.chronicle("RD.LOGIN", p, { hours = hoursSurvived(p), x = x, y = y, z = z })
    else
        md.RFTD_LifeId = mintLifeId(p)
        pcall(function() p:transmitModData() end)
        local hours = hoursSurvived(p)
        local x, y, z = posOf(p)
        RDLog.chronicle("RD.SPAWN", p, {
            x = x, y = y, z = z,
            house = houseOf(p),
            hours = hours,
            retro = (hours > RETRO_HOURS) or nil,
            kills = killsOf(p),
            build = {
                profession = professionOf(p),
                traits     = traitsOf(p),
                perks      = perkLevels(p),
            },
        })
    end

    -- HELLO: the loaded-mod version set, chronicled only when it CHANGES for
    -- this character (per-connection copies go to the forensic ring instead).
    local sig = helloSignature()
    RDLog.forensic("hello", "RD.HELLO", p, { mods = RDShared.mods })
    if md.RFTD_HelloSig ~= sig then
        md.RFTD_HelloSig = sig
        RDLog.chronicle("RD.HELLO", p, { mods = RDShared.mods })
    end

    for _, fn in ipairs(readyFns) do pcall(fn, p) end
end

-- ---------------------------------------------------------------------------
-- The standing poll (DFBanBox pattern, verbatim structure)
-- ---------------------------------------------------------------------------

local WATCH_MAX_MS     = 5 * 60 * 1000
local POLL_INTERVAL_MS = 1000
local readyID    = {}   -- onlineID -> true (handled this connection)
local gaveUpID   = {}   -- onlineID -> true (never loaded in; do not retry)
local watchStart = {}   -- onlineID -> ms first seen, still loading in
local lastPoll   = 0

-- A character this poll already handled whose modData no longer carries
-- RFTD_LifeId is a NEW character on an OLD connection, because modData died with
-- the previous IsoPlayer. That is the whole detection.
local function swappedCharacter(p)
    local md
    pcall(function() md = p:getModData() end)
    return md ~= nil and md.RFTD_LifeId == nil
end

-- RESPAWN IS NOT A RECONNECT. Verified against the B42 decompile, because the
-- header's "a respawn reads as absent and starts a new life" was the INTENT and
-- this poll's own gate defeated it: readyID is keyed by onlineID and cleared only
-- on disconnect, so handleReady never ran a second time and the entire respawned
-- life went unrecorded - no RD.SPAWN, and every record it produced carrying
-- "l":null. Observed live (Kriegan, 2026-07-26: RD.DEATH, then a memoir write by
-- a character with no chronicle entries at all).
--
-- Why there is no event to wait for:
--   * GameServer.receivePlayerConnect returns immediately when the connection's
--     player slot is occupied, so a repeat connect is refused outright.
--   * onlineID comes from connection.getPlayerId(playerIndex) - derived from the
--     connection and player index, so it is stable for the whole session.
--   * Server-side registration happens in exactly two places,
--     receivePlayerConnect and disconnectPlayer. Neither runs on respawn.
-- What DOES happen is CreatePlayerPacket.processServer constructing a brand new
-- IsoPlayer and firing OnNewGame. Hooking that is a trap: at trigger time the
-- character is not in the world, has no square, and has not been assigned an
-- onlineID yet. So detect the invariant instead of awaiting the event - it also
-- self-heals if modData is ever lost by some other route.
--
-- Idempotent by construction: handleReady mints RFTD_LifeId, so the condition
-- stops matching on the very next pass and a failure cannot flood RD.SPAWN once
-- per second. gaveUpID is excluded because that path deliberately never sets a
-- life id, and re-arming it would turn the 5-minute give-up into a retry loop.
local function poll()
    local now = RDShared.nowMs()
    if now == 0 or (now - lastPoll) < POLL_INTERVAL_MS then return end
    lastPoll = now
    local players
    pcall(function() players = getOnlinePlayers() end)
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local id = p and p.getOnlineID and p:getOnlineID()

        -- Skip the dead outright. A corpse still answers getSquare() and
        -- getInventory(), so without this the re-arm below would fire
        -- handleReady on the body and chronicle a spawn for someone who just
        -- died. It also keeps the give-up timer from burning down while a player
        -- sits on the death screen.
        local dead = false
        if p then pcall(function() dead = p:isDead() end) end

        if id and not dead then
            if readyID[id] and not gaveUpID[id] and swappedCharacter(p) then
                readyID[id] = nil; watchStart[id] = nil
            end
            if not readyID[id] then
                local sq, inv
                pcall(function() sq = p:getSquare(); inv = p:getInventory() end)
                if sq and inv then
                    readyID[id] = true; watchStart[id] = nil
                    handleReady(p)
                else
                    local start = watchStart[id]
                    if not start then watchStart[id] = now; start = now end
                    if now - start >= WATCH_MAX_MS then
                        readyID[id] = true; gaveUpID[id] = true; watchStart[id] = nil
                        print("[RFTDCore] RDLife: gave up waiting for "
                            .. tostring((p.getUsername and p:getUsername()) or id)
                            .. " to load in - not instrumented this connection")
                    end
                end
            end
        end
    end
end

Events.OnTick.Add(poll)

local function prune(p)
    local id = p and p.getOnlineID and p:getOnlineID()
    if id then readyID[id] = nil; gaveUpID[id] = nil; watchStart[id] = nil end
end
if Events.OnDisconnect then Events.OnDisconnect.Add(prune) end
if Events.OnPlayerDisconnect then Events.OnPlayerDisconnect.Add(prune) end

-- ---------------------------------------------------------------------------
-- Death capture
-- ---------------------------------------------------------------------------

local deathCalls = 0   -- every invocation, players or not: the measurable rate

local function killerOf(p)
    local kind, who
    pcall(function()
        local a = p:getAttackedBy()
        if a == nil then return end
        if instanceof(a, "IsoPlayer") then
            kind = "player"
            who  = a:getUsername()
        elseif instanceof(a, "IsoZombie") then
            kind = "zombie"
        elseif instanceof(a, "IsoAnimal") then
            kind = "animal"
        else
            kind = "other"
        end
    end)
    return kind and { kind = kind, who = who } or nil
end

local function onCharacterDeath(ch)
    deathCalls = deathCalls + 1
    if not instanceof(ch, "IsoPlayer") then return end
    if not deathCaptureOn() then return end

    local x, y, z = posOf(ch)
    RDLog.chronicle("RD.DEATH", ch, {
        x = x, y = y, z = z,
        hours  = hoursSurvived(ch),
        kills  = killsOf(ch),
        killer = killerOf(ch),
        perks  = perkLevels(ch),
    })
end

Events.OnCharacterDeath.Add(onCharacterDeath)

-- ---------------------------------------------------------------------------
-- Hourly pass: progression samples (on change, with a daily heartbeat floor)
-- and home detection. One walk of the online list per game hour.
-- ---------------------------------------------------------------------------

local sampleSig = {}   -- onlineID -> { sig, day }

local function sampleSignature(p)
    local parts = {}
    for id, lvl in pairs(perkLevels(p)) do parts[#parts + 1] = id .. ":" .. lvl end
    table.sort(parts)
    local k = killsOf(p)
    return table.concat(parts, ",") .. "|" .. k.zombies .. "|" .. k.survivors
end

local function homePass(p, md)
    local sh
    pcall(function() sh = SafeHouse.hasSafehouse(p) end)
    if not sh then return end
    local key, payload
    pcall(function()
        key = tostring(sh:getX()) .. "," .. tostring(sh:getY())
        payload = {
            x = sh:getX(), y = sh:getY(),
            w = sh:getW(), h = sh:getH(),
            title = sh:getTitle(),
        }
    end)
    if not key or md.RFTD_HomeKey == key then return end
    local evt = md.RFTD_HomeKey and "RD.HOME_CHANGE" or "RD.HOME_SET"
    md.RFTD_HomeKey = key
    RDLog.chronicle(evt, p, payload)
end

Events.EveryHours.Add(function()
    if RDShared.debugOn() and deathCalls > 0 then
        print("[RFTDCore] RDLife: OnCharacterDeath calls this session: " .. tostring(deathCalls))
    end
    local players
    pcall(function() players = getOnlinePlayers() end)
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local id = p and p.getOnlineID and p:getOnlineID()
        if id and readyID[id] then
            local md
            pcall(function() md = p:getModData() end)
            if md then
                local sig  = sampleSignature(p)
                local day  = RDShared.gameDay() or 0
                local prev = sampleSig[id]
                if not prev or prev.sig ~= sig or (day - prev.day) >= 1.0 then
                    sampleSig[id] = { sig = sig, day = day }
                    RDLog.chronicle("RD.SAMPLE", p, {
                        hours = hoursSurvived(p),
                        kills = killsOf(p),
                        perks = perkLevels(p),
                    })
                end
                homePass(p, md)
            end
        end
    end
end)

return RDLife
