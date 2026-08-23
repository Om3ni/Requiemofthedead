-- SPDX-License-Identifier: GPL-3.0-or-later
-- RDConfigStore.lua - durable server-owned configuration (server only).
--
-- One persistence pattern with two consumers already lined up - RDVars' player
-- attributes and Dragonfly's admin layout overlay - which is what puts it in
-- Core rather than in either of them (CLAUDE.md sect. 5). It holds NO domain
-- knowledge: it does not know what a var or a layout is, only that a consumer
-- has two documents, that one is cold and one is hot, and that both must
-- survive a crash. Swapping the backing store later stays a one-file change.
--
-- ---------------------------------------------------------------------------
-- WHY TWO LAYERS, AND WHICH ONE IS AUTHORITATIVE
--
-- The LIVE store is ModData.getOrCreate(modKey). That choice is about
-- authority, not convenience: an inbound GlobalModDataPacket cannot reach it.
-- parse() builds a FRESH KahluaTable and fires OnReceiveGlobalModData with it
-- (GlobalModDataPacket.java:43-56) - it never writes GlobalModData's own map -
-- so a client can offer us a table but can never mutate the server's. Contrast
-- item and player modData, which SyncItemFieldsPacket/ObjectModDataPacket let
-- any logged-in client overwrite wholesale. See TODO.md.
--
-- ModData is also SAVE-SCOPED, and that is a feature here. global_mod_data.bin
-- lives in the save, so a wipe destroys it and config goes with the world -
-- cleanup by construction, nothing to remember to clear.
--
-- The JSON files are a DURABLE MIRROR, not a second source of truth. They exist
-- because ModData flushes only when the world does: GlobalModData.instance.save()
-- is called from exactly one server-side place, inside ServerMap's world-save
-- routine (ServerMap.java:397), on the SaveWorldEveryMinutes timer. Lua cannot
-- force it. A hard kill therefore loses every ModData change since the last
-- world save, which for a 15-minute timer is 15 minutes of admin work.
--
-- NEVER call ModData.transmit on a store's table. transmit() loops
-- GameServer.udpEngine.connections and sends the whole table to every one of
-- them, with no relevance filter of any kind (GlobalModData.java:126-143). Push
-- per-player slices with sendServerCommand instead; RCRegistry is the precedent.
--
-- ---------------------------------------------------------------------------
-- COLD AND HOT
--
-- Two documents, always, because they have opposite write profiles and opposite
-- restore semantics:
--
--   defs   rare writes, exported IMMEDIATELY. Definitions - what a var IS, what
--          a kit CONTAINS. This is the half an admin wants back after a wipe.
--   state  frequent writes, exported on a flushMs budget. Per-player progress -
--          who holds what, what has been claimed. Restoring this across a wipe
--          would hand players back one-time grants they already consumed, so
--          the normal wipe move is defs only.
--
-- That is why import is TWO calls and why the envelope carries `kind`: an admin
-- restoring after a wipe reaches for whichever file is in front of them, and
-- the one mistake this design invites is importing state when they meant defs.
-- A state file offered to importDefs is refused by name at the door.
--
-- ---------------------------------------------------------------------------
-- BOOT RESOLUTION - five cases, and the third is the one worth arguing about
--
--   corrupt file        keep the live table, shout, and LATCH EXPORT OFF for
--                       that document (see FAULT LATCH below).
--   live, no file       export. First boot after the mirror shipped.
--   live, file newer    IMPORT. This is crash recovery, the whole point of the
--                       mirror: ModData came back from the last world save,
--                       the file came back from the last flush.
--   live, file older    export.
--   NO live, file       do NOT import. Say so, loudly, and wait.
--
-- "No live" means the ModData table carries no meta stamp - it has never been
-- written by this store. On a dedicated server that means one of two things:
-- a genuinely fresh world, or a WIPE. The files outlive both, because
-- getFileWriter roots at the Lua cache dir, OUTSIDE the save
-- (LuaManager.java:5528). So auto-importing here would carry every definition
-- AND, if the rule were uniform, every consumed grant straight across a wipe -
-- exactly the exploit the save-scoping was chosen to prevent. Making the rule
-- differ per document instead would be worse: a silent asymmetry nobody
-- remembers is how behaviour that nobody chose gets discovered months later.
--
-- So the rule is uniform and it is REFUSE, with a console line that names the
-- file and the call that would load it. An admin staring at an empty panel with
-- a full JSON file on disk deserves to be told why, not left to guess.
--
-- ---------------------------------------------------------------------------
-- THE HOLD
--
-- Two of those cases end with a file on disk that this store must not write
-- over, so both raise the same latch and export for that document stops:
--
--   "corrupt"  the file is present and will not decode.
--   "foreign"  the file outlived the world that wrote it (the wipe case above).
--
-- The latch is not caution, it is the only non-destructive option available: PZ
-- Lua has no rename and no delete (see RDLog's rotation note), so "move the bad
-- file aside" does not exist. The choices are overwrite it - destroying the only
-- copy, which in the corrupt case a human might still repair by hand and in the
-- foreign case is the previous season's configuration - or stop writing.
--
-- Without the foreign hold the advice printed in that case is a trap: it tells
-- the admin to import deliberately, while the consumer's very first touchDefs
-- during boot seeding would already have replaced the file they were told to
-- import. The hold makes the advice true.
--
-- Two ways out, both explicit, neither reachable by accident:
--   import(doc)    take the file. Clears the hold.
--   discard(doc)   abandon it. Clears the hold; the next write overwrites it.
-- A held store nags periodically so it cannot pass for a healthy one.
--
-- ---------------------------------------------------------------------------
-- NOT OnSave. The obvious hook for "flush before the world saves" is the OnSave
-- event, and it does not fire on a dedicated server: every caller of
-- GameWindow.save - IngameState, GameLoadingState, ModalDialog, SleepingEvent
-- and the Lua-exposed one at LuaManager.java:3292 - is client-side game-state
-- code, and the server's own save routine (ServerMap.java:375-402) never calls
-- it. Same trap as OnPlayerDeath. The sweep rides EveryTenMinutes, which is the
-- family's established server cadence, and every write path also checks its own
-- budget so a busy store does not wait for the sweep.

if not isServer() then return end

require "RDShared"
require "RDJson"

RDConfigStore = RDConfigStore or {}

-- Envelope version. Bump only for a shape change readers must branch on; the
-- reader refuses a version it does not know rather than guessing at the fields.
RDConfigStore.FORMAT = 1

-- Complain again every Nth suppressed export while latched. At a 30s flush
-- budget that is roughly one line every six minutes - enough that a latched
-- store is visible in a console scroll, few enough that it is not the console.
local NAG_EVERY = 12

local stores = {}   -- every store built this session, for flushAll

-- ---------------------------------------------------------------------------
-- File I/O
--
-- Both directions are bare. getFileWriter returns nil for a denied path or a
-- refused extension and catches both of its own IOException sites
-- (LuaManager.java:5523-5555); LuaFileWriter.write/close delegate to
-- PrintWriter, which records a full-or-locked disk on an internal flag rather
-- than raising (LuaManager.java:9850-9868). On the read side getFileReader is
-- called with createIfNull=false, so its one unguarded throw site is
-- unreachable, and BufferedReader is an exposed class (LuaManager.java:1651) -
-- a fault inside readLine is a Java body throw, swallowed to nil by
-- MethodCaller (MethodCaller.java:33-56) and therefore indistinguishable from
-- end of file. A truncated read presents as short content, which is precisely
-- what the decoder is here to reject.
-- ---------------------------------------------------------------------------

-- Returns the file's whole content as one string, or nil if it is not there.
-- Joined without separators: RDJson.encode emits no newlines, so a document is
-- one line today, and concatenating tolerates it being pretty-printed later.
local function readWhole(path)
    local r = getFileReader(path, false)
    if not r then return nil end
    local parts, n = {}, 0
    -- Bounded rather than while-true: this file was not necessarily written by
    -- this session, and an unbounded loop over a reader we do not control is
    -- how a boot hangs instead of failing.
    for _ = 1, 200000 do
        local line = r:readLine()
        if line == nil then break end
        n = n + 1
        parts[n] = line
    end
    r:close()
    return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Construction
--
-- spec:
--   modKey     ModData tag. Required.
--   defsFile   path under the Lua cache dir. Required.
--   stateFile  ditto. Required, and must differ from defsFile.
--   flushMs    state write budget in real milliseconds. Default 30000.
--   label      console prefix. Defaults to modKey.
--
-- Filenames are the CALLER'S, deliberately - the store does not append an
-- extension, because picking one is a decision with an engine constraint
-- attached and hiding it here would put that constraint out of sight. Use
-- RDShared.EXT_DOC: it ends ".txt", which has been in the write allowlist the
-- whole time, so the name survives that set changing again the way it did
-- mid-42.20. The store REFUSES a name the engine will not write rather than
-- discovering it at the first flush - a nil writer is silent, and a silently
-- unwritten mirror is the exact failure this whole file exists to prevent.
-- ---------------------------------------------------------------------------

local ALLOWED_EXT = { ini = true, cfg = true, txt = true, log = true, json = true }

-- LuaManager.java:1045, gate at :5526. getFileExtension reads the text after
-- the LAST dot, so "vars-defs.json.txt" presents as "txt". The engine's check
-- is case-sensitive and unlowercased, so ".TXT" is refused; this mirrors that
-- rather than being lenient, because being lenient here would mean approving a
-- name the engine then rejects at write time.
local function extAllowed(path)
    local last = tostring(path):match("([^/\\]+)$") or ""
    local ext = last:match("%.([^.]+)$")
    return ext ~= nil and ALLOWED_EXT[ext] == true
end

function RDConfigStore.new(spec)
    spec = spec or {}
    local modKey    = spec.modKey
    local defsFile  = spec.defsFile
    local stateFile = spec.stateFile

    -- Hard failures, not warnings. Every one of these produces a store that
    -- looks like it is working and persists nothing, which is unfalsifiable
    -- from the outside until an admin loses a day of configuration.
    if type(modKey) ~= "string" or modKey == "" then
        error("RDConfigStore.new: modKey is required")
    end
    if type(defsFile) ~= "string" or type(stateFile) ~= "string" then
        error("RDConfigStore.new: defsFile and stateFile are required (" .. modKey .. ")")
    end
    if defsFile == stateFile then
        error("RDConfigStore.new: defsFile and stateFile must differ (" .. modKey .. ")")
    end
    if not extAllowed(defsFile) then
        error("RDConfigStore.new: getFileWriter will refuse '" .. defsFile
            .. "' - use RDShared.EXT_DOC (" .. modKey .. ")")
    end
    if not extAllowed(stateFile) then
        error("RDConfigStore.new: getFileWriter will refuse '" .. stateFile
            .. "' - use RDShared.EXT_DOC (" .. modKey .. ")")
    end

    local self = {
        modKey    = modKey,
        label     = spec.label or modKey,
        flushMs   = spec.flushMs or 30000,
        files     = { defs = defsFile, state = stateFile },
        held      = {},           -- doc -> "corrupt" | "foreign"; see THE HOLD
        suppressed= {},           -- doc -> exports refused while held
        pending   = {},           -- doc -> true when the mirror is behind
        lastWrite = {},           -- doc -> nowMs of the last successful export
        booted    = false,
        stats     = { exports = 0, imports = 0, refusedWrites = 0, faults = 0 },
    }
    setmetatable(self, { __index = RDConfigStore })
    stores[#stores + 1] = self
    return self
end

local function say(self, msg)
    print("[" .. self.label .. "] RDConfigStore: " .. msg)
end

-- ---------------------------------------------------------------------------
-- The live tables
-- ---------------------------------------------------------------------------

-- ModData.getOrCreate is idempotent and cheap, but it is an engine call, so the
-- root is resolved once per call rather than cached in an upvalue: a cached
-- reference would survive a reset() the engine performs on world teardown and
-- hand the next world the previous one's table.
function RDConfigStore:root()
    local md = ModData.getOrCreate(self.modKey)
    md.defs  = md.defs  or {}
    md.state = md.state or {}
    md.meta  = md.meta  or {}
    return md
end

function RDConfigStore:defs()  return self:root().defs  end
function RDConfigStore:state() return self:root().state end

-- Has this store ever written the live table? Distinguishes a fresh or wiped
-- world from one whose ModData merely lags the mirror. See BOOT RESOLUTION.
local function hasLive(self, doc)
    return self:root().meta[doc .. "Ms"] ~= nil
end

-- ---------------------------------------------------------------------------
-- Elapsed time, defensively.
--
-- RDShared.nowMs is getTimestampMs, wall clock, NOT monotonic - an NTP step can
-- move it backwards. A naive `now - last >= budget` stalls forever when that
-- happens, so negative elapsed is treated as "due now": the cost of an extra
-- write is one file; the cost of a stalled mirror is every change until reboot.
-- ---------------------------------------------------------------------------
local function budgetExpired(last, budget)
    if last == nil then return true end
    local elapsed = RDShared.nowMs() - last
    return elapsed < 0 or elapsed >= budget
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

local HOLD_WHY = {
    corrupt = "it failed to decode at boot and is being kept for inspection",
    foreign = "it outlived the world that wrote it, so overwriting it would "
           .. "destroy the previous season's copy",
}

local function writeDoc(self, doc)
    local hold = self.held[doc]
    if hold then
        -- Never overwrite a file we were told to keep - see THE HOLD. The nag
        -- is what keeps a held store from reading as a quiet healthy one.
        local n = (self.suppressed[doc] or 0) + 1
        self.suppressed[doc] = n
        if n == 1 or n % NAG_EVERY == 0 then
            say(self, "NOT writing " .. doc .. " - '" .. self.files[doc]
                .. "' is held (" .. hold .. "): " .. HOLD_WHY[hold] .. ". "
                .. n .. " write(s) held back. Call import('" .. doc
                .. "') to take that file, or discard('" .. doc .. "') to abandon it.")
        end
        return false, "held"
    end

    local md = self:root()
    local payload = RDJson.encode{
        format  = RDConfigStore.FORMAT,
        kind    = doc,
        key     = self.modKey,
        savedMs = md.meta[doc .. "Ms"],
        data    = md[doc],
    }

    -- The nil test IS the failure path; getFileWriter cannot throw. append is
    -- false: a document is rewritten whole, which is what EXT_DOC's ".txt"
    -- suffix announces on disk.
    local w = getFileWriter(self.files[doc], true, false)
    if not w then
        self.stats.refusedWrites = self.stats.refusedWrites + 1
        say(self, "CRITICAL: getFileWriter refused '" .. self.files[doc]
            .. "'. " .. doc .. " is NOT mirrored - a hard restart will lose "
            .. "everything since the last world save.")
        return false, "refused"
    end
    w:write(payload)
    w:write("\n")
    w:close()

    self.pending[doc]   = false
    self.lastWrite[doc] = RDShared.nowMs()
    self.stats.exports  = self.stats.exports + 1
    return true
end

-- ---------------------------------------------------------------------------
-- Import
--
-- Returns (true) on success, (false, reason) otherwise. Reasons are meant to
-- reach an admin verbatim, so they name the file.
--
-- `expectKind` is enforced, not advisory. Loading a state file as defs would
-- put per-player progress where definitions belong and, worse, the reverse
-- would hand back consumed one-time grants after a wipe. The envelope knows
-- which it is; refusing costs one comparison.
-- ---------------------------------------------------------------------------

local function loadFile(self, doc)
    local path = self.files[doc]
    local raw = readWhole(path)
    if raw == nil then return nil, "missing" end
    if raw:match("^%s*$") then return nil, "empty file '" .. path .. "'" end

    local env, err = RDJson.decode(raw)
    if env == nil then
        return nil, "malformed JSON in '" .. path .. "': " .. tostring(err)
    end
    if type(env) ~= "table" then
        return nil, "'" .. path .. "' is not a JSON object"
    end
    if env.format ~= RDConfigStore.FORMAT then
        return nil, "'" .. path .. "' has format " .. tostring(env.format)
            .. ", this build reads " .. RDConfigStore.FORMAT
    end
    if env.kind ~= doc then
        return nil, "'" .. path .. "' holds " .. tostring(env.kind)
            .. ", not " .. doc .. " - this is the wrong file for this import"
    end
    if type(env.data) ~= "table" then
        return nil, "'" .. path .. "' carries no data object"
    end
    return env
end

-- Replace one document wholesale from its file. Wholesale is deliberate: a
-- merge would need to know what a key MEANS to resolve a conflict, and this
-- file is the half that does not know.
function RDConfigStore:import(doc)
    if doc ~= "defs" and doc ~= "state" then
        return false, "unknown document '" .. tostring(doc) .. "'"
    end
    local env, err = loadFile(self, doc)
    if not env then
        if err == "missing" then return false, "no file at '" .. self.files[doc] .. "'" end
        return false, err
    end

    local md = self:root()
    md[doc] = env.data
    md.meta[doc .. "Ms"] = env.savedMs or RDShared.nowMs()
    -- A successful read releases the hold: the file is now the live table, so
    -- there is nothing left on disk that writing would destroy.
    self.held[doc]       = nil
    self.suppressed[doc] = nil
    self.pending[doc]    = true
    self.stats.imports   = self.stats.imports + 1
    say(self, "imported " .. doc .. " from '" .. self.files[doc] .. "'.")
    return true
end

function RDConfigStore:importDefs()  return self:import("defs")  end
function RDConfigStore:importState() return self:import("state") end

-- The other way out of a hold: abandon the file. The next write overwrites it,
-- and since Lua cannot delete, overwriting is the only "delete" available - so
-- this is deliberately a separate verb from import rather than a flag on it.
function RDConfigStore:discard(doc)
    if doc ~= "defs" and doc ~= "state" then
        return false, "unknown document '" .. tostring(doc) .. "'"
    end
    if not self.held[doc] then return false, doc .. " is not held" end
    say(self, "discarding the held " .. doc .. " file '" .. self.files[doc]
        .. "' - the next write will overwrite it.")
    self.held[doc]       = nil
    self.suppressed[doc] = nil
    self.pending[doc]    = true
    return true
end

-- ---------------------------------------------------------------------------
-- Touch - the consumer's signal that it changed something
-- ---------------------------------------------------------------------------

-- Definitions are rare and precious: stamped and written now.
function RDConfigStore:touchDefs()
    self:root().meta.defsMs = RDShared.nowMs()
    self.pending.defs = true
    return writeDoc(self, "defs")
end

-- State is hot: stamped now, written when the budget says so. The lazy check
-- means a store that is being written to steadily never waits for the sweep.
function RDConfigStore:touchState()
    self:root().meta.stateMs = RDShared.nowMs()
    self.pending.state = true
    if budgetExpired(self.lastWrite.state, self.flushMs) then
        return writeDoc(self, "state")
    end
    return true
end

-- Write anything outstanding regardless of budget.
function RDConfigStore:flush()
    local ok = true
    for _, doc in ipairs({ "defs", "state" }) do
        if self.pending[doc] then
            local wrote = writeDoc(self, doc)
            ok = ok and wrote
        end
    end
    return ok
end

function RDConfigStore.flushAll()
    for _, s in ipairs(stores) do s:flush() end
end

-- ---------------------------------------------------------------------------
-- Boot
--
-- Idempotent, and safe to call from a consumer's own boot path rather than from
-- an event here: the consumer knows when its defaults are in place, and a store
-- resolved before that would export an empty document over a good file.
-- ---------------------------------------------------------------------------

function RDConfigStore:boot()
    if self.booted then return end
    self.booted = true

    for _, doc in ipairs({ "defs", "state" }) do
        local live = hasLive(self, doc)
        local env, err = loadFile(self, doc)

        if not env and err ~= "missing" then
            -- Present and unreadable. Loud, held, and the live table is left
            -- exactly as it is - an empty store here would look like a wipe.
            self.held[doc]    = "corrupt"
            self.stats.faults = self.stats.faults + 1
            say(self, "CRITICAL: " .. err .. ". Keeping the live " .. doc
                .. " table and refusing to overwrite the file. Repair or "
                .. "replace it and import, or discard('" .. doc .. "').")

        elseif not live and env then
            -- Files outlive the save; ModData does not. This is a fresh world
            -- or a wipe, and carrying either document across one automatically
            -- is the thing the save-scoping was chosen to prevent. Held so the
            -- advice below stays true - see THE HOLD.
            self.held[doc] = "foreign"
            say(self, "a " .. doc .. " file exists at '" .. self.files[doc]
                .. "' but this world has no " .. doc .. " yet - it is from a "
                .. "previous world. NOT loading it automatically: after a wipe "
                .. "that would restore progress players already spent. "
                .. "import('" .. doc .. "') to take it, discard('" .. doc
                .. "') to start clean.")

        elseif live and env and (env.savedMs or 0) > (self:root().meta[doc .. "Ms"] or 0) then
            -- Crash recovery: the mirror is ahead of what the world save kept.
            say(self, "the " .. doc .. " file is newer than the world's copy - "
                .. "recovering it (the server did not shut down cleanly).")
            self:import(doc)
            writeDoc(self, doc)

        elseif live then
            -- The live table is current. Mirror it, which also covers the first
            -- boot after this store shipped, when no file exists at all.
            writeDoc(self, doc)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Observability. A persistence layer that quietly stops persisting is the
-- failure mode here, so the sweep is also the reporter: it says nothing while
-- healthy, and a faulted or refused store cannot stay quiet.
-- ---------------------------------------------------------------------------

function RDConfigStore:report()
    local md = self:root()
    return {
        key       = self.modKey,
        defsMs    = md.meta.defsMs,
        stateMs   = md.meta.stateMs,
        heldDefs  = self.held.defs,
        heldState = self.held.state,
        exports   = self.stats.exports,
        imports   = self.stats.imports,
        refused   = self.stats.refusedWrites,
        faults    = self.stats.faults,
    }
end

-- EveryTenMinutes is compressed GAME time - at the default one-hour day it
-- fires about every ten real seconds - so this is a floor on staleness rather
-- than a schedule. The body is a dirty-flag test per store, which is what keeps
-- it honest at that rate.
Events.EveryTenMinutes.Add(function()
    for _, s in ipairs(stores) do
        if s.pending.state and budgetExpired(s.lastWrite.state, s.flushMs) then
            writeDoc(s, "state")
        end
        if s.pending.defs then writeDoc(s, "defs") end
    end
end)

return RDConfigStore

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
