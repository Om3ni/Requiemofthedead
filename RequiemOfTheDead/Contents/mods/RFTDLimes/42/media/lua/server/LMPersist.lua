-- SPDX-License-Identifier: GPL-3.0-or-later
-- LMPersist.lua - RFTDLimes.ini read/write, boot load, save-on-edit (server).
--
-- THE DISK CONTRACT (§8). One human-editable file, jailed to Zomboid/Lua/:
--
--   [ZoneName]
--   inherits = Very_Hard
--   rects = 12361,4215,12863,4472 ; 11907,993,14695,4215
--   tier = 5
--   title = Louisville
--
-- ".ini" is on the 42.20 getFileWriter extension allowlist
-- (LuaManager.java:9884; lowercase mandatory, the check is case-sensitive and
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
-- own rotating log machinery (LuaManager.java:7448) - the zone audit stream
-- ("who edited what") rides it by design.
--
-- BOOT ORDER (OnServerStarted): defaults <- RFTDLimes.ini <- editor deltas,
-- with the §8.1 template seed as the last resort when the .ini is absent and
-- no import candidate exists.
-- First boot with no .ini probes IMPORT_CANDIDATES in Zomboid/Lua/ and runs
-- the §9 one-way import on the first hit, writing the .ini it will read
-- forevermore. "phunzones.txt" leads the list because that is the name
-- PhunZones2 itself persists under on the 42.20 dedi (grabbed off the
-- production box 2026-08-02; the write-extension allowlist forces .txt on it
-- too) - so a fresh Limes install on the box that matters imports the real
-- dataset with zero admin ceremony. Re-import later is the capability-gated
-- RDNet command in LMSync.
--
-- BOTH CASINGS of the PhunZones filename are probed. Their source constant is
-- "PhunZones.txt" (core.lua: Core.const.modifiedLuaFile) while the copy taken
-- off production arrived lowercase; the 42.20 allowlist check is
-- case-sensitive and the dedi is Linux, so guessing one casing silently loses
-- the fallback route on the box it exists for. Cheap to probe, expensive to
-- get wrong.
--
-- parse()/serialize() are pure (stock Lua 5.1) and sit above the engine
-- section so tools\run-tests.bat exercises the round trip without a game.

if not isServer() then return end

require "RDJson"
require "LMCore"
require "LMImport"

LMPersist = LMPersist or {}

LMPersist.FILE              = "RFTDLimes.ini"
LMPersist.IMPORT_CANDIDATES = { "phunzones.txt", "PhunZones.txt", "PhunZonesExport.lua" }

-- ---------------------------------------------------------------------------
-- Pure half: text -> raw zones -> text
-- ---------------------------------------------------------------------------

local HEADER = "; RFTDLimes zone store. Hand-editable; the server rewrites it on every\n"
            .. "; zone edit (sorted sections and keys - keep diffs clean, not comments:\n"
            .. "; lines starting with ; or # survive a reload but NOT the next rewrite).\n"

local function autoType(s)
    if s == "true"  then return true  end
    if s == "false" then return false end
    local n = tonumber(s)
    if n ~= nil then return n end
    return s
end

local function encodeValue(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number"  then return RDJson.fmtNum(v) end
    -- One line per key is the grammar; a value cannot carry the line breaks.
    return (tostring(v):gsub("[\r\n]", " "))
end

-- text -> rawZones, warnings
function LMPersist.parse(text)
    local zones, warnings = {}, {}
    local cur, curName = nil, nil
    local lineNo = 0
    for line in tostring(text or ""):gmatch("([^\n]*)\n?") do
        lineNo = lineNo + 1
        line = line:gsub("\r$", "")
        local section = line:match("^%s*%[([%w_%-%.]+)%]%s*$")
        if section then
            if zones[section] then
                warnings[#warnings + 1] = "line " .. lineNo .. ": duplicate section ["
                    .. section .. "], merging"
                cur = zones[section]
            else
                cur = { inherits = nil, rects = {}, fields = {} }
                zones[section] = cur
            end
            curName = section
        elseif line:match("^%s*$") or line:match("^%s*[;#]") then
            -- blank or comment
        else
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if not key then
                warnings[#warnings + 1] = "line " .. lineNo .. ": unparseable, skipped: " .. line
            elseif not cur then
                warnings[#warnings + 1] = "line " .. lineNo .. ": '" .. key
                    .. "' before any [section], skipped"
            elseif key == "inherits" then
                if value ~= "" then cur.inherits = value end
            elseif key == "rects" then
                for rect in value:gmatch("[^;]+") do
                    local x1, y1, x2, y2 = rect:match("^%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*$")
                    if x1 then
                        cur.rects[#cur.rects + 1] =
                            { tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2) }
                    else
                        warnings[#warnings + 1] = "line " .. lineNo .. ": [" .. tostring(curName)
                            .. "] bad rect '" .. rect .. "', skipped"
                    end
                end
            else
                cur.fields[key] = autoType(value)
            end
        end
    end
    return zones, warnings
end

-- rawZones -> deterministic text
function LMPersist.serialize(rawZones)
    local names = {}
    for name in pairs(rawZones or {}) do names[#names + 1] = name end
    table.sort(names)

    local out = { HEADER }
    for i = 1, #names do
        local name = names[i]
        local z = rawZones[name]
        out[#out + 1] = "\n[" .. name .. "]\n"
        if z.inherits then
            out[#out + 1] = "inherits = " .. tostring(z.inherits) .. "\n"
        end
        if z.rects and #z.rects > 0 then
            local parts = {}
            for j = 1, #z.rects do
                local r = z.rects[j]
                parts[j] = RDJson.fmtNum(r[1]) .. "," .. RDJson.fmtNum(r[2]) .. ","
                        .. RDJson.fmtNum(r[3]) .. "," .. RDJson.fmtNum(r[4])
            end
            out[#out + 1] = "rects = " .. table.concat(parts, " ; ") .. "\n"
        end
        local keys = {}
        for k in pairs(z.fields or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        for j = 1, #keys do
            out[#out + 1] = keys[j] .. " = " .. encodeValue(z.fields[keys[j]]) .. "\n"
        end
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Engine half: the jail, the journal, the boot
-- ---------------------------------------------------------------------------

-- Whole-file read from the Zomboid/Lua/ jail; nil if absent. Reads are not
-- extension-gated (only writes are), so this opens .lua candidates too.
function LMPersist.readAll(name)
    local text = nil
    pcall(function()
        local reader = getFileReader(name, false)
        if not reader then return end
        local lines = {}
        while true do
            local line = reader:readLine()
            if line == nil then break end
            lines[#lines + 1] = line
        end
        reader:close()
        text = table.concat(lines, "\n")
    end)
    return text
end

local function forensic(evt, payload)
    if RDLog and RDLog.forensic then
        RDLog.forensic("limes", evt, nil, payload, "RFTDLimes")
    end
end

-- Truncate-overwrite with the journal line first (see header). Returns ok.
function LMPersist.save(rawZones, why, who)
    local text = LMPersist.serialize(rawZones)
    local n = 0
    for _ in pairs(rawZones or {}) do n = n + 1 end
    pcall(function()
        writeLog("RFTDLimes", string.format("save begin: %s by %s, %d zones, %d bytes",
            tostring(why), tostring(who), n, #text))
    end)
    local ok = false
    pcall(function()
        local w = getFileWriter(LMPersist.FILE, true, false)
        if not w then return end
        w:write(text)
        w:close()
        ok = true
    end)
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

-- First candidate that exists in the jail; nil if none do.
function LMPersist.findImportCandidate()
    for i = 1, #LMPersist.IMPORT_CANDIDATES do
        local name = LMPersist.IMPORT_CANDIDATES[i]
        local text = LMPersist.readAll(name)
        if text then return name, text end
    end
    return nil
end

local function bootImport()
    local file, text = LMPersist.findImportCandidate()
    if not text then return nil end
    print("[Limes] no " .. LMPersist.FILE .. " but found " .. file
        .. " - running the one-way import")
    local ok, res = LMImport.parsePhunZones(text)
    if not ok then
        print("[Limes] import failed: " .. tostring(res))
        forensic("LM.IMPORT_FAIL", { file = file, err = tostring(res) })
        return nil
    end
    for i = 1, #res.warnings do
        print("[Limes] import: " .. res.warnings[i])
    end
    LMPersist.save(res.zones, "first-boot import from " .. file, "server")
    forensic("LM.IMPORT", { file = file, zones = res.count, warnings = #res.warnings })
    return res.zones
end

local function boot()
    local zones = nil
    local text = LMPersist.readAll(LMPersist.FILE)
    if text then
        local warnings
        zones, warnings = LMPersist.parse(text)
        for i = 1, #warnings do print("[Limes] " .. LMPersist.FILE .. ": " .. warnings[i]) end
    else
        zones = bootImport()
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
        LMPersist.save(Limes.raw(), "first-boot template seed", "server")
        print("[Limes] empty store - seeded " .. #Limes.zoneNames() .. " templates")
    end

    print("[Limes] store up: " .. #Limes.zoneNames() .. " zones, revision " .. Limes.revision)
end

if Events and Events.OnServerStarted then
    Events.OnServerStarted.Add(function() pcall(boot) end)
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
