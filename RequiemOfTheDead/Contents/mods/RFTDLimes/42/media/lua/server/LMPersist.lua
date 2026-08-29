-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMPersist.lua - RFTDLimes.ini read/write, boot load, save-on-edit (server).
--
-- THE DISK CONTRACT (§8). One human-editable file, jailed to Zomboid/Lua/:
--
--   [ZoneName]
--   inherits = Louisville
--   tier = IDDQL
--   rects = 12361,4215,12863,4472 ; 11907,993,14695,4215
--   title = Louisville
--
-- ".ini" is on the 42.20 getFileWriter extension allowlist
-- (LuaManager.java:1045; lowercase mandatory, the check is case-sensitive and
-- reads the substring after the LAST dot) - and the extension is the point:
-- admins hand-edit this file, editors syntax-highlight it. Values are stringly
-- on disk; TYPES live in LMCore's field registry, which coerces on resolve.
-- The parser auto-detects number/boolean-looking values so imports round-trip;
-- an unregistered numeric-looking string flips type across a round trip, which
-- is harmless today and healed the day its consumer registers the field.
--
-- Writer is deterministic - sorted sections, sorted keys, fixed header -
-- so identical stores serialize identically and the file diffs cleanly
-- (RDJson's discipline). Atomic rename does not exist in the jail (Lua cannot
-- rename or delete, engine-file-io determination), so every save is
-- truncate-overwrite with a writeLog journal line FIRST: a crash mid-write
-- leaves a diagnosable journal entry, not a mystery. writeLog is the engine's
-- own rotating log machinery (LuaManager.java:7409-7412) - the zone audit stream
-- ("who edited what") rides it by design.
--
-- BOOT ORDER (OnServerStarted): defaults <- RFTDLimes.ini <- editor deltas,
-- with the §8.1 ladder seed as the last resort when the .ini is absent.
-- The ini is migrated on the way in (LMImport.migrateLadder - a no-op on a
-- current store) and the migrated form is written straight back, so a
-- pre-redesign file is rewritten exactly once and reads clean forever after.
--
-- THE FIRST-BOOT PHUNZONES PROBE IS GONE (S2, 2026-08-27). It existed so a
-- fresh install on the production box could eat the live layer with zero
-- ceremony; the redesign moved that translation OFFLINE
-- (tools/limes-zone-converter.html), whose output is pasted or dropped as
-- schema-1 JSON through the capability-gated import in LMSync. A boot-time
-- importer that restructures somebody else's format is exactly the
-- complexity the offline tool exists to hold.
--
-- parse()/serialize() are pure (stock Lua 5.1) and sit above the engine
-- section so tools\run-tests.bat exercises the round trip without a game.

if not isServer() then return end

require "RDFile"

require "RDJson"
require "LMCore"
require "LMIni"
require "LMImport"

LMPersist = LMPersist or {}

LMPersist.FILE = "RFTDLimes.ini"

-- ---------------------------------------------------------------------------
-- The .ini dialect now lives in shared/LMIni.lua, so the CLIENT can read the
-- format the server writes - which is what lets the importer accept our own
-- export instead of only PhunZones'. These two names are kept as delegates
-- because they are the file's published surface and every caller, including
-- the test suite, addresses them.
-- ---------------------------------------------------------------------------

function LMPersist.parse(text)          return LMIni.parse(text) end
function LMPersist.serialize(rawZones)  return LMIni.serialize(rawZones) end

-- ---------------------------------------------------------------------------
-- Engine half: the jail, the journal, the boot
-- ---------------------------------------------------------------------------

-- Whole-file read from the Zomboid/Lua/ jail; nil if absent. Reads are not
-- extension-gated (only writes are), so this opens .lua candidates too.
function LMPersist.readAll(name)
    -- No guard. getFileReader returns nil for a refused name or failed open
    -- (LuaManager.java:4894-4917) - the nil test IS that branch - and
    -- readLine/close on the handle CANNOT raise into Lua: BufferedReader is an
    -- exposed class (LuaManager.java:1651), and every exposed method body
    -- routes through MethodCaller, which logs any IOException with a stack
    -- trace and returns nil (MethodCaller.java:33-56). A mid-read fault
    -- therefore reads as early EOF: truncated text, not an error - the ini
    -- parser downstream is what rejects a half-file.
    local reader = getFileReader(name, false)
    if not reader then return nil end
    local lines = {}
    while true do
        local line = reader:readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    reader:close()
    return table.concat(lines, "\n")
end

local function forensic(evt, payload)
    if RDLog and RDLog.forensic then
        RDLog.forensic("limes", evt, nil, payload, "RFTDLimes")
    end
end

-- Truncate-overwrite with the journal line first (see header). Returns ok.
-- Snapshot the CURRENT store to a second file before something destructive.
--
-- The jail gives Lua no rename and no delete (engine-file-io determination), so
-- there is no atomic "move the old one aside" - a snapshot is a second write to
-- a second allowlisted name, and it necessarily overwrites the previous
-- snapshot. One level of undo, not a history: enough to survive a mis-clicked
-- Clear All, not enough to be a backup strategy. Say so where it is offered.
--
-- Serialises Limes.raw() rather than taking an argument, because the only
-- honest thing to snapshot is what is live right now.
LMPersist.BACKUP = "RFTDLimes.backup.ini"

function LMPersist.snapshot(why, who)
    local text = LMPersist.serialize(Limes.raw())
    -- Mechanism in RDFile (2026-08-25); its header carries the engine facts
    -- the comment here used to re-derive. This caller's policy: `ok` feeds the
    -- journal line and the forensic record either way.
    local ok = RDFile.rewrite(LMPersist.BACKUP, text)
    -- No guard. writeLog cannot raise into Lua: ZLogger.write wraps the whole
    -- write INCLUDING rotation in catch(Exception) (ZLogger.java:52-58,
    -- :96-103), a failed open leaves a null stream whose writes are dropped by
    -- a null test (:25-37, :112-120), and getLogger creates on miss
    -- (LoggerManager.java:20-25). Disk trouble costs the journal line only.
    writeLog("RFTDLimes", string.format("snapshot %s: %s by %s, %d bytes",
        ok and "ok" or "FAILED", tostring(why), tostring(who), #text))
    forensic(ok and "LM.SNAPSHOT" or "LM.SNAPSHOT_FAIL",
        { why = tostring(why), who = tostring(who), bytes = #text })
    return ok
end

function LMPersist.save(rawZones, why, who)
    local text = LMPersist.serialize(rawZones)
    local n = 0
    for _ in pairs(rawZones or {}) do n = n + 1 end
    -- No guard - same reading as snapshot's journal line above: ZLogger
    -- absorbs every failure internally (ZLogger.java:52-58), so this line can
    -- be dropped by disk trouble but can never stop the save it explains.
    writeLog("RFTDLimes", string.format("save begin: %s by %s, %d zones, %d bytes",
        tostring(why), tostring(who), n, #text))
    -- Same conversion as snapshot's, same policy: `ok` drives the forensic
    -- record and the loud SAVE FAILED print below.
    local ok = RDFile.rewrite(LMPersist.FILE, text)
    if ok then
        forensic("LM.SAVE", { why = tostring(why), who = tostring(who), zones = n, bytes = #text })
    else
        forensic("LM.SAVE_FAIL", { why = tostring(why), who = tostring(who), zones = n })
        print("[Limes] SAVE FAILED - getFileWriter refused " .. LMPersist.FILE
            .. " (allowlist regression?) - store is live but NOT persisted")
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

local function boot()
    local zones = nil
    local text = LMPersist.readAll(LMPersist.FILE)
    if text then
        local warnings
        zones, warnings = LMPersist.parse(text)
        for i = 1, #warnings do print("[Limes] " .. LMPersist.FILE .. ": " .. warnings[i]) end
        -- The one-shot ladder migration, then the file is rewritten in the
        -- migrated form so it never migrates again. A current store notes
        -- nothing and skips the save.
        local notes = LMImport.migrateLadder(zones)
        if #notes > 0 then
            for i = 1, #notes do print("[Limes] migrate: " .. notes[i]) end
            LMPersist.save(zones, "ladder migration (" .. #notes .. " notes)", "server")
            forensic("LM.MIGRATE", { notes = #notes })
        end
    end
    zones = zones or {}
    local warnings = Limes.apply(zones, 1)
    for i = 1, #warnings do print("[Limes] resolve: " .. warnings[i]) end

    -- Nothing on disk and nothing to import: lay down the §8.1 template seed
    -- and write it out, so the next boot reads it back as ordinary data the
    -- admin can edit or delete like any other zone. seedIfEmpty is a no-op on
    -- any non-empty store - that is what keeps a deleted template deleted
    -- instead of resurrecting it every boot.
    if Limes.seedIfEmpty() then
        LMPersist.save(Limes.raw(), "first-boot ladder seed", "server")
        print("[Limes] empty store - seeded the tier ladder ("
            .. #Limes.zoneNames() .. " records)")
    end

    print("[Limes] store up: " .. #Limes.zoneNames() .. " zones, revision " .. Limes.revision)
end

if Events and Events.OnServerStarted then
    -- The pcall still guards the event loop, and it does not silence the
    -- engine: a boot that throws still leaves a Kahlua stack trace in the
    -- console (pcall does not suppress the mod error reporter). What the
    -- trace never says is what it MEANT - that the store is empty for the
    -- whole session while the ini on disk is fine, which otherwise reads as
    -- "the save never happened", the most expensive misread this file can
    -- cause. So name the consequence next to the error, and put it in the
    -- forensic stream where it survives to be queried.
    Events.OnServerStarted.Add(function()
        local ok, err = pcall(boot)
        if not ok then
            print("[Limes] BOOT FAILED: " .. tostring(err)
                .. " - the store is empty this session and " .. LMPersist.FILE
                .. " was NOT loaded (the file itself is untouched)")
            forensic("LM.BOOT_FAIL", { err = tostring(err) })
        end
    end)
end

return LMPersist

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
