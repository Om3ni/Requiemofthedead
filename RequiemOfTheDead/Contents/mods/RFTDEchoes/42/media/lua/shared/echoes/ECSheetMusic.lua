-- Echoes: sheet music song assignment. PZ calls OnCreate every time an item
-- is initialized - including on load, and before modData is applied - so a
-- fresh sheet can't be told from a loaded one at OnCreate time. Items queue
-- here and get a song on the next tick, only if no song arrived with their
-- modData. (Inherited workaround from the fork source; the engine quirk is
-- unchanged in 42.20.)

require "echoes/ECCore"

local toInitializeItems = {}
local isChecking = false

local function checkQueuedSheets()
    for i = #toInitializeItems, 1, -1 do
        local item = toInitializeItems[i]
        local md = item:getModData()
        if not md["EC_Song"] then
            EC_RandomizeSheetMusic(item)
        end
        table.remove(toInitializeItems, i)
    end
    if #toInitializeItems == 0 then
        isChecking = false
        Events.OnTick.Remove(checkQueuedSheets)
    end
end

function EC_OnCreate_SheetMusic(item)
    table.insert(toInitializeItems, item)
    if not isChecking then
        isChecking = true
        Events.OnTick.Add(checkQueuedSheets)
    end
end

function EC_RandomizeSheetMusic(item)
    local randomSong = ECCore:getRandomFindableSong()
    item:getModData()["EC_Song"] = randomSong.name
end
