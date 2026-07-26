-- RPContextMenu — adds a debug right-click ground option that asks the server
-- to run an immediate full scan (all bloom detection layers on demand).
-- Sandbox option RFTDReaper.DebugContextMenu gates whether the option appears.

if isServer() then return end

local MODULE = "RFTDReaper"

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    local s = SandboxVars.RFTDReaper or {}
    if s.Enabled == false then return end
    if s.DebugContextMenu ~= true then return end
    if test then return end

    context:addOption(
        "Reaper: Force full scan",
        nil,
        function()
            local player = getPlayer()
            sendClientCommand(player, MODULE, "forceScan", {})
            if player then
                player:Say("Reaper full scan dispatched")
            end
        end
    )
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
