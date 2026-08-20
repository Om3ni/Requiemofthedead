-- SPDX-License-Identifier: GPL-3.0-or-later
-- HBSexCheck - diagnostic for the "all animals read as male" bug.
--
-- Sex is decided once in the AnimalData constructor from the animal definition:
--   adef.female -> female,  adef.male -> male,  else Rand.NextBool(2) (50/50).
-- SurvivorDesc defaults to FEMALE, so "everything male" means something is
-- explicitly setting male - by far the most likely culprit being a definition
-- (a species or its babyType) that carries male=true. This dumps every animal
-- definition's sex flags so that is verifiable at a glance, and can compare a
-- single animal's sex as the SERVER sees it vs. the CLIENT (to catch a
-- sync/serialization bug instead of a definition bug).
--
-- Usage (debug console / admin):
--   HBSexCheck.dumpDefs()   -- list every type's female / male / babyType
--   HBSexCheck.run(oid)     -- dump defs + compare server vs client sex for OID
-- The server also dumps the definition table once at startup to the server log,
-- so the prime diagnostic needs no in-game action at all.

HBSexCheck = HBSexCheck or {}

local function readDef(d)
    local t, female, male, baby = "?", "?", "?", "?"
    if d then t = d:getAnimalType() end  -- AnimalDefinitions:699, field return
    -- No guards, and the premise is now READ rather than assumed. It is true
    -- that female/male/babyType are Java instance fields and Kahlua exposes
    -- only methods - but an unexposed key does not THROW, it reads nil.
    -- LuaJavaClassExposer builds __index as a plain KahluaTable of exposed
    -- methods, chained to the superclass metatable
    -- (LuaJavaClassExposer.java:225-236), and KahluaThread.tableget walks that
    -- chain and returns null when it runs out, because the last link IS a table
    -- (:1089-1096). The throw at :1097-1102 is for indexing a NON-table, which
    -- an exposed AnimalDefinition is not - proven by getAnimalType() resolving
    -- one line above.
    --
    -- So the nil test does the work the guards were doing, and "?" still means
    -- "this build does not surface that field".
    if d then
        if d.female   ~= nil then female = tostring(d.female)   end
        if d.male     ~= nil then male   = tostring(d.male)     end
        if d.babyType ~= nil then baby   = tostring(d.babyType) end
    end
    return t, female, male, baby
end

function HBSexCheck.dumpDefs(tag)
    tag = tag or (isServer() and "server" or "client")
    -- Indexing an absent global is nil in Lua; only CALLING it throws, so the
    -- existence check is the guard. (LuaManager:2789 in 42.20.2.)
    local defs
    if type(getAllAnimalsDefinitions) == "function" then
        defs = getAllAnimalsDefinitions()
    end
    if not defs then
        print("[HBSexCheck] (" .. tag .. ") getAllAnimalsDefinitions() unavailable")
        return
    end
    local n = defs:size() or 0   -- ArrayList.size on a non-nil list
    print(string.format("[HBSexCheck] (%s) ==== %d animal definitions ====", tag, n))
    local males, females, randoms = 0, 0, 0
    for i = 0, n - 1 do
        local d = defs:get(i)
        if d then
            local t, female, male, baby = readDef(d)
            if male == "true" then males = males + 1
            elseif female == "true" then females = females + 1
            else randoms = randoms + 1 end
            print(string.format("[HBSexCheck]   type=%-16s female=%-5s male=%-5s babyType=%s",
                tostring(t), female, male, baby))
        end
    end
    print(string.format(
        "[HBSexCheck] (%s) forced-male=%d forced-female=%d random=%d  <-- any unexpected forced-male (esp. a babyType) is the bug",
        tag, males, females, randoms))
end

-- Client-side: dump defs, read THIS client's view of the animal's sex, then
-- ask the server to report its authoritative view for the same OID. Compare
-- the two: both male on a fresh baby => definition bug; client male / server
-- mixed => sync bug.
function HBSexCheck.run(oid)
    oid = tonumber(oid)
    HBSexCheck.dumpDefs(isServer() and "server" or "client")
    if not oid then
        print("[HBSexCheck] run: pass an animal OID, e.g. HBSexCheck.run(123)")
        return
    end
    local a = getAnimal(oid)
    if a then
        -- No guard - and the one that sat here was worse than inert: it made
        -- this diagnostic LIE. isFemale's descriptor NPE (IsoGameCharacter:9312
        -- through this.descriptor; constructor bail at IsoAnimal:259-275) is a
        -- Java body throw, swallowed by MethodCaller into a nil return
        -- (MethodCaller.java:33-56) - so the closure never errored,
        -- `nil and "FEMALE" or "MALE"` evaluated to "MALE", and an unreadable
        -- animal printed as MALE while the "?" fallback sat unreachable. The
        -- three-way test restores the honest answer this tool existed to give.
        local f = a:isFemale()
        local sex = (f == true and "FEMALE") or (f == false and "MALE") or "?"
        print(string.format("[HBSexCheck] %s view: oid=%d sex=%s",
            isServer() and "server" or "client", oid, sex))
    else
        print("[HBSexCheck] animal " .. oid .. " not resolvable here")
    end
    if not isServer() then
        sendClientCommand(getPlayer(), "RFTDHusbandry", "hbSexCheck", { id = oid })
    end
end

-- Server logs the full definition table once at startup. No action required.
if isServer() then
    local done = false
    local function bootDump()
        if done then return end
        done = true
        HBSexCheck.dumpDefs("server-boot")
    end
    Events.OnServerStarted.Add(bootDump)
    Events.OnGameStart.Add(bootDump)
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
