-- RDSeasonServer.lua - season bookkeeping (server only).
--
-- A "season" partitions everything Core writes: the id is a PATH COMPONENT
-- (RFTD/season/<SeasonId>/...), so rolling the season means "start writing
-- elsewhere" - nothing migrates, nothing can clobber the previous season, and
-- old seasons stay readable forever.
--
-- The id comes from SandboxVars.RFTDCore.SeasonId. NOT global ModData (RAM-only
-- under SaveWorldEveryMinutes=0 with force-kill restarts - it would forget) and
-- NOT a hand-edited Lua constant (changing a server setting must not require a
-- Workshop republish). Sandbox survives restarts and is admin-editable.
--
-- Boot sequence (first server tick after the world is up):
--   manifest matches sandbox id  -> normal boot; regression check (below)
--   manifest missing             -> first install: begin the configured season
--   manifest differs             -> season roll: close the old season (write
--       RD.SEASON_END into ITS world stream - timestamped "last observed",
--       honest about the fact there was no graceful shutdown), then begin the
--       new one and rewrite the manifest.
--
-- Defensive auto-roll: if world age has gone BACKWARDS versus the manifest,
-- the world was wiped and the admin forgot to bump the knob. Roll to
-- "auto-<YYYYMMDD>" rather than appending a fresh world onto last season's
-- record. Ten lines, and it saves an entire season's integrity.
--
-- NOTE (write down why, because someone will try): MMShared.WIPE_EPOCH is a
-- DIFFERENT mechanism and must never be merged into the season id. WIPE_EPOCH
-- voids memoir items wherever they lie; SeasonId partitions Core's records.
-- Conflating them means bumping a season silently voids every memoir in the
-- world.

if not isServer() then return end

RDSeasonServer = RDSeasonServer or {}

local DIR      = RDShared.DIR
local MANIFEST = DIR .. "manifest.json"

local current      = nil     -- active season id; nil until boot
local booted       = false
local schemaDirty  = true

-- Season ids become directory names and manifest fields; keep them boring.
local function sanitize(id)
    id = tostring(id or ""):gsub("[^%w%-_]", "-")
    if id == "" then id = "unset" end
    if #id > 64 then id = id:sub(1, 64) end
    return id
end

local function configuredId()
    local ok, v = pcall(function() return SandboxVars.RFTDCore and SandboxVars.RFTDCore.SeasonId end)
    if ok and type(v) == "string" and v ~= "" then return sanitize(v) end
    return "unset"
end

-- Manifest: flat JSON we both write and read. Pattern-parsed on read, which is
-- safe because we control the writer (sorted keys, sanitized ids, no nesting).
local function readManifest()
    local text
    pcall(function()
        local r = getFileReader(MANIFEST, false)
        if not r then return end
        local parts = {}
        for _ = 1, 100 do
            local line = r:readLine()
            if line == nil then break end
            parts[#parts + 1] = line
        end
        r:close()
        text = table.concat(parts, "")
    end)
    if not text or text == "" then return nil end
    local season = text:match('"season":"([^"]*)"')
    if not season then return nil end
    return {
        season        = season,
        worldAgeHours = tonumber(text:match('"worldAgeHours":([%d%.%-]+)')),
        updatedAt     = tonumber(text:match('"updatedAt":([%d%.%-]+)')),
    }
end

local function writeManifest()
    pcall(function()
        local w = getFileWriter(MANIFEST, true, false)
        if w then
            w:write(RDJson.encode({
                season        = current,
                schemaV       = RDEvents.SCHEMA_V,
                worldAgeHours = RDShared.worldAgeHours(),
                updatedAt     = RDShared.nowSec(),
            }) .. "\n")
            w:close()
        end
    end)
end

local function emitSchema()
    pcall(function()
        local w = getFileWriter(DIR .. "schema.json", true, false)
        if w then
            w:write(RDJson.encode(RDEvents.schemaTable()) .. "\n")
            w:close()
        end
    end)
    schemaDirty = false
end

function RDSeasonServer.markSchemaDirty()
    schemaDirty = true
end

local function autoId()
    local ok, stamp = pcall(function() return os.date("!%Y%m%d") end)
    if ok and stamp then return "auto-" .. stamp end
    return "auto-" .. tostring(RDShared.nowSec())
end

local function beginSeason(id, why)
    current = id
    RDLog.chronicleInto(id, "RD.SEASON_BEGIN", nil, {
        season = id,
        why    = why,
        core   = RDShared.VERSION,
    })
    writeManifest()
    emitSchema()
    print("[RFTDCore] season '" .. id .. "' active (" .. why .. ")")
end

local function endSeason(oldId, manifest, why)
    RDLog.chronicleInto(oldId, "RD.SEASON_END", nil, {
        season       = oldId,
        why          = why,
        lastObserved = manifest and manifest.updatedAt or nil,
    })
end

-- Idempotent; safe to call from any write path. Does nothing until the world
-- clock exists (nothing chronicle-worthy can happen before it does).
function RDSeasonServer.ensure()
    if booted then return true end
    local ok = pcall(function() return getGameTime() ~= nil end)
    if not ok then return false end
    booted = true   -- set first: beginSeason writes through RDLog, which calls back here

    local cfg      = configuredId()
    local manifest = readManifest()
    local wah      = RDShared.worldAgeHours()

    if not manifest then
        beginSeason(cfg, "first-boot")
    elseif manifest.season ~= cfg then
        endSeason(manifest.season, manifest, "id-changed")
        beginSeason(cfg, "roll")
    elseif wah and manifest.worldAgeHours and (wah < manifest.worldAgeHours - 1.0) then
        endSeason(manifest.season, manifest, "world-age-regressed")
        beginSeason(autoId(), "auto-roll-after-wipe")
    else
        current = cfg
        if schemaDirty then emitSchema() end
    end
    return true
end

function RDSeasonServer.current()
    if not booted then RDSeasonServer.ensure() end
    return current or "unset"
end

-- ---------------------------------------------------------------------------
-- Boot on the first usable tick; keep the manifest's world age fresh hourly so
-- the regression check has something recent to compare against, and re-emit
-- the schema when a late namespace registration dirtied it.
-- ---------------------------------------------------------------------------

local function onBootTick()
    if RDSeasonServer.ensure() then
        Events.OnTick.Remove(onBootTick)
    end
end
Events.OnTick.Add(onBootTick)

Events.EveryHours.Add(function()
    if not booted then return end
    writeManifest()
    if schemaDirty then emitSchema() end
end)

return RDSeasonServer
