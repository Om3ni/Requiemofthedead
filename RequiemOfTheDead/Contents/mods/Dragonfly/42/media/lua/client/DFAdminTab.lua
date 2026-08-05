-- DFAdminTab - a reserved slot in the roster. Nothing behind it yet.
--
-- WHY REGISTER AN EMPTY TAB AT ALL. Tab order is sorted (DFRegistry.getTabs),
-- so the position a tab lands in is decided by every OTHER tab's `order` as
-- much as its own. Adding a real tab later would shuffle whatever currently
-- sits at 30+ sideways, and the roster is something admins learn by muscle
-- memory. Claiming the slot now means the day Admin ships, nothing else moves.
--
-- It is inert by construction: no `build`, so there is no panel to keep
-- working, no scan to keep cheap, and no state to keep in sync. The whole cost
-- of this file is one greyed word in the nav.
--
-- BOTH SHELLS ALREADY KNEW HOW TO GREY A ROW - the classic panel via
-- ISButton.enable and the deck by drawing !enabled rows in scar instead of ash
-- - because a per-player `capability` check needed exactly that. `disabled`
-- rides the same path; see DFRegistry.isSelectable for why the two are kept
-- distinct rather than folded together.

if isServer() then return end

Events.OnGameStart.Add(function()
    if not DFRegistry then return end
    local ok, err = pcall(function()
        DFRegistry.registerTab{
            id       = "admin",
            label    = "Admin",
            -- Between Players (20) and Longstrider (60). Sits with the
            -- server-management half of the roster rather than the
            -- per-subsystem tabs at 5-6.
            order    = 30,
            disabled = true,
            -- No build. Adding one is the entire remaining task, and until
            -- then the shells refuse to select this id at all.
        }
    end)
    if not ok then
        print("[Dragonfly] DFAdminTab registerTab error: " .. tostring(err))
    end
end)
