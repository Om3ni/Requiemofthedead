-- RQRegistry - client-side special zombie roster
-- Keyed by onlineID integer, not zombie object.
-- Server is the only writer (via RQCore broadcast handlers).
-- Survives chunk unloads and teleports.

RQRegistry = RQRegistry or {}

-- All valid naturally-spawning special zombie types (excludes Boss)
RQRegistry.TYPES = { "Screamer", "Juggernaut", "EMP", "Glutton", "Scavenger" }

-- modData key constants
RQRegistry.KEY_TYPE      = "RQType"
RQRegistry.KEY_CONVERTED = "RQConverted"

-- onlineID (int) -> zType string
-- plain table, no weak keys (IDs are integers, not objects)
RQRegistry.activeZombies = RQRegistry.activeZombies or {}

function RQRegistry.register(onlineID, zType)
    RQRegistry.activeZombies[onlineID] = zType
end

function RQRegistry.unregister(onlineID)
    RQRegistry.activeZombies[onlineID] = nil
end

function RQRegistry.getType(onlineID)
    return RQRegistry.activeZombies[onlineID]
end

function RQRegistry.isSpecial(onlineID)
    return RQRegistry.activeZombies[onlineID] ~= nil
end

function RQRegistry.resetAll()
    RQRegistry.activeZombies = {}
end

Events.OnGameStart.Add(RQRegistry.resetAll)

-- Copyright Project_Omen
