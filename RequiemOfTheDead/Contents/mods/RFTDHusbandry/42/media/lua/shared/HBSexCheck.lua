-- HBSexCheck — diagnostic for the "all animals read as male" bug.
--
-- Sex is decided once in the AnimalData constructor from the animal definition:
--   adef.female -> female,  adef.male -> male,  else Rand.NextBool(2) (50/50).
-- SurvivorDesc defaults to FEMALE, so "everything male" means something is
-- explicitly setting male — by far the most likely culprit being a definition
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
    pcall(function() t = d:getAnimalType() end)
    pcall(function() female = tostring(d.female) end)
    pcall(function() male   = tostring(d.male) end)
    pcall(function() baby   = tostring(d.babyType) end)
    return t, female, male, baby
end

function HBSexCheck.dumpDefs(tag)
    tag = tag or (isServer() and "server" or "client")
    local defs
    pcall(function() defs = getAllAnimalsDefinitions() end)
    if not defs then
        print("[HBSexCheck] (" .. tag .. ") getAllAnimalsDefinitions() unavailable")
        return
    end
    local n = 0
    pcall(function() n = defs:size() or 0 end)
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
        local sex = "?"
        pcall(function() sex = a:isFemale() and "FEMALE" or "MALE" end)
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
