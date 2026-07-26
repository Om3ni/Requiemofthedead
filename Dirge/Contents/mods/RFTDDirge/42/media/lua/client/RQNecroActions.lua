-- RQNecroActions - registers Dirge "Convert to Type" actions on the Necro
-- tab when both Dragonfly and Reaper are installed. Soft-depends on both;
-- without Dragonfly, Dirge's existing right-click admin menu still works
-- as the only conversion surface.
--
-- Each action handler sends Dirge's existing adminConvert command. The
-- server-side svMarkZombie path runs unchanged, so type-specific behavior
-- (Screamer summoning, Juggernaut aura, etc.) initializes the same way it
-- does from the in-world right-click menu.

if isServer() then return end

-- DFRegistry check happens inside the OnGameStart callback below, not here.
-- Top-of-file early return would prevent the OnGameStart hook from ever
-- being registered if Dirge loads before DragonflyAdmin.

-- TYPES is built inside OnGameStart so Capability (defined by Dragonfly Admin)
-- isn't dereferenced at file-load time. Without that guard, any client without
-- Dragonfly installed errors out with "attempted index of nil" the moment this
-- file loads, breaking everything else in the mod.
local TYPE_IDS = { "Screamer", "Juggernaut", "EMP", "Glutton", "Scavenger", "Boss" }

local function convertHandler(zType)
    return function(rowData)
        if not rowData or not rowData.id then return end
        sendClientCommand(getPlayer(), "RQ", "adminConvert", {
            onlineID = rowData.id,
            x        = rowData.x or 0,
            y        = rowData.y or 0,
            z        = rowData.z or 0,
            zType    = zType,
        })
        if DFFeedback then
            DFFeedback.good(string.format("Convert request sent: id=%d -> %s",
                rowData.id, zType))
        end
        -- Local audit echo so the action shows up in the Console tab even
        -- before Dirge replies. Server-side svMarkZombie doesn't emit a
        -- LogBroadcast on its own; if it ever does we'll see a duplicate
        -- here, which is acceptable.
        if DFLog then
            DFLog.push{
                source = "Mod:RFTDDirge",
                level  = "audit",
                text   = string.format("Convert id=%d -> %s by %s",
                    rowData.id, zType, getPlayer():getUsername()),
            }
        end
    end
end

Events.OnGameStart.Add(function()
    if not DFRegistry or not Capability then return end
    for _, id in ipairs(TYPE_IDS) do
        DFRegistry.registerRowAction{
            tabId      = "necro",
            label      = "Convert → " .. id,
            capability = Capability.CanZombify,
            handler    = convertHandler(id),
        }
    end
    print("[Dirge] RQNecroActions: " .. #TYPE_IDS .. " Convert actions registered")
end)
