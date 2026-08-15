-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDSeasonServer.lua - season bookkeeping (server only).
--
-- A "season" partitions everything Core writes: the name is a PATH COMPONENT
-- (RFTD/season/<SeasonName>/...), so starting a new season means "start writing
-- elsewhere" - nothing migrates, nothing can clobber the previous season, and
-- old seasons stay readable forever.
--
-- ONE KNOB, NO CLEVERNESS. The season is whatever the server owner typed into
-- SandboxVars.RFTDCore.SeasonName, always, with no exceptions. Set it before
-- first boot; change it by hand when you wipe. That is the whole model.
--
-- This replaced a manifest-driven design that tracked world age and rolled the
-- season automatically when it detected a wipe the admin had not accounted for.
-- It worked exactly as specified and was still the wrong shape: the failure it
-- produced ("why is my folder called auto-20260726?") was unexplainable to
-- anyone who had not read this file, and the recovery was non-obvious even to
-- the person who wrote it. A tool whose safety mechanism generates support
-- tickets is not safer. The manual version can also go wrong - forget to change
-- the name after a wipe and two worlds share a folder - but that failure is
-- legible: the records are in the folder you named, because you named it.
--
-- What is left of the safety net is advisory only and changes NOTHING about
-- where records go: if this season already has records and the world is young,
-- somebody probably wiped without renaming, so say so - in the console and, on
-- the first admin to join, on their screen. A dedicated server console is read
-- by nobody until the damage is already done.
--
-- The "already has records" probe is the season's own world stream rather than
-- a state file, so the simplification did not smuggle a manifest back in under
-- another name. Existence probing uses cacheFileExists, which roots at
-- cacheDir/Lua/ - the same root RDLog writes to.
--
-- NOTE (write down why, because someone will try): MMShared.WIPE_EPOCH is a
-- DIFFERENT mechanism and must never be merged into the season name. WIPE_EPOCH
-- voids memoir items wherever they lie; SeasonName partitions Core's records.
-- Conflating them means renaming a season silently voids every memoir.

if not isServer() then return end

require "RDShared"

RDSeasonServer = RDSeasonServer or {}

local DIR = RDShared.DIR

-- A world younger than this is treated as fresh for the stale-season warning.
-- Generous on purpose: the warning is advisory, and crying wolf on an
-- established season would train people to ignore the one that matters.
local FRESH_WORLD_HOURS = 24

local current     = nil     -- active season name; nil until boot
local booted      = false
local schemaDirty = true
local stale       = false   -- season already had records when a young world booted

-- Season names become directory names; keep them boring.
local function sanitize(name)
    name = tostring(name or ""):gsub("[^%w%-_]", "-")
    if name == "" then name = "unset" end
    if #name > 64 then name = name:sub(1, 64) end
    return name
end

-- Sandbox, not global ModData (its durability rides the engine-save cadence and
-- a force-killed restart can hand back a stale value at exactly the moment a
-- wipe makes staleness expensive) and not a Lua constant (changing a server
-- setting must never require a Workshop republish).
local function configuredName()
    local v = SandboxVars and SandboxVars.RFTDCore and SandboxVars.RFTDCore.SeasonName
    if type(v) == "string" and v ~= "" then return sanitize(v) end
    return "unset"
end

local function emitSchema()
    -- getFileWriter allowlist I/O; a failed schema write is retried on the
    -- next dirty mark and must not disturb the caller
    pcall(function()
        -- Rewritten whole, so EXT_DOC; the bare ".json" is refused since 42.20.
        local w = getFileWriter(DIR .. "schema" .. RDShared.EXT_DOC, true, false)
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

-- Must recognise BOTH eras. This probe is what arms the "you wiped but the season
-- name is unchanged" warning, and a season whose records predate the 42.20
-- rename would otherwise read as empty - the one case where a false negative
-- silently mixes two worlds' records together.
local function seasonHasRecords(name)
    local base = DIR .. "season/" .. name .. "/chronicle/world"
    for _, ext in ipairs({ RDShared.EXT_STREAM, RDShared.EXT_STREAM_LEGACY }) do
        -- cacheFileExists (LuaManager:4618) is string ops + File.exists -
        -- cannot throw
        if cacheFileExists(base .. ext) == true then return true end
    end
    return false
end

-- Idempotent; safe to call from any write path. Does nothing until the world
-- clock exists (nothing chronicle-worthy can happen before it does).
function RDSeasonServer.ensure()
    if booted then return true end
    -- getGameTime() is a bare read of GameTime.instance (LuaManager:4733) and
    -- never throws; the old pcall checked only that it RAN, so this nil-check
    -- is the gate the comment above always described
    if getGameTime() == nil then return false end
    booted = true   -- set first: the write below goes through RDLog, which calls back here

    current = configuredName()

    local had = seasonHasRecords(current)
    local age = RDShared.worldAgeHours()
    stale = had and (age ~= nil) and (age < FRESH_WORLD_HOURS)

    if not had then
        -- First write into this season opens its world stream, which is also
        -- what makes the probe above meaningful on the next boot.
        RDLog.chronicleInto(current, "RD.SEASON_BEGIN", nil, {
            season = current,
            core   = RDShared.VERSION,
        })
    end
    emitSchema()

    if stale then
        print("[RFTDCore] ================================================================")
        print("[RFTDCore] Season '" .. current .. "' ALREADY HAS RECORDS, but this world is")
        print("[RFTDCore] only " .. string.format("%.1f", age) .. " hours old. If you wiped, this season's records")
        print("[RFTDCore] are about to be mixed with the previous world's.")
        print("[RFTDCore] Fix: set Sandbox Options -> Requiem of the Dead: Core -> Season")
        print("[RFTDCore] Name to a new value and restart, BEFORE players join.")
        print("[RFTDCore] Nothing has been changed automatically - the season is what you named it.")
        print("[RFTDCore] ================================================================")
    else
        print("[RFTDCore] season '" .. current .. "' active")
    end
    return true
end

function RDSeasonServer.current()
    if not booted then RDSeasonServer.ensure() end
    return current or "unset"
end

-- True when this boot looks like a wipe the season name was not updated for.
function RDSeasonServer.isStale()
    return stale
end

-- ---------------------------------------------------------------------------
-- Boot on the first usable tick (the only server event proven to fire on a
-- dedi), then re-emit the schema if a late namespace registration dirtied it.
-- ---------------------------------------------------------------------------

local function onBootTick()
    if RDSeasonServer.ensure() then
        Events.OnTick.Remove(onBootTick)
    end
end
Events.OnTick.Add(onBootTick)

Events.EveryHours.Add(function()
    if booted and schemaDirty then emitSchema() end
end)

-- ---------------------------------------------------------------------------
-- On-screen warning for the first admin in. Console-only would be read after
-- the season was already polluted; the whole point is to catch it before
-- players arrive. Admin rather than any staffer, because changing a sandbox
-- option is not something a general staff role can act on anyway.
-- ---------------------------------------------------------------------------

-- Registered at file scope rather than from OnGameStart: that event is not one
-- of the ones proven to fire on a dedicated server, and RDLife.onPlayerReady is
-- itself the family's answer to that problem (an OnTick poll). Explicit require
-- because "RDLife.lua" sorts before this file only by luck of the alphabet.
require "RDLife"

local told = {}

RDLife.onPlayerReady(function(player)
    if not stale then return end
    if not RDAccess.isTopAdmin(player) then return end
    local name = player and player.getUsername and player:getUsername()
    if not name or told[name] then return end
    told[name] = true
    RDNet.reply(player, RDShared.MODULE, "seasonNotice", { season = current })
end)

return RDSeasonServer

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
