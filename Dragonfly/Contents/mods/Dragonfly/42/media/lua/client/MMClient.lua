-- MMClient.lua — owning-client half: send requests, mirror-apply results, feedback.
-- The client NEVER mutates authoritatively; it only asks the server and then mirrors
-- the server-sent result locally (dual-apply). Mirror-apply is SAFE because the
-- earnable merge is max() toward a target — idempotent, so server and client
-- converge to the same values instead of stacking.

if isServer() then return end

require "MMSvShared"
require "MMSnapshotCodec"

MMClient = MMClient or {}

-- ---- request senders (called by the context menu) ----
function MMClient.requestWrite(player, item)
    sendClientCommand(player, MMShared.MODULE, MMShared.CMD.WRITE_REQUEST, { itemID = item:getID() })
end
function MMClient.requestRead(player, item)
    sendClientCommand(player, MMShared.MODULE, MMShared.CMD.READ_REQUEST, { itemID = item:getID() })
end
function MMClient.requestDump(player, item)
    sendClientCommand(player, MMShared.MODULE, MMShared.CMD.DUMP, { itemID = item:getID() })
end

local function say(text)
    local p = getPlayer()
    if p and text then p:Say(text) end
end

-- The inventory pane caches its item-stack list, so an item renamed server-side
-- (Memoir <-> "Memoirs of X") doesn't redraw until the container changes or relog.
-- Force a rebuild a couple ticks after the result, once the name sync has landed.
local function refreshInventorySoon()
    local ticks, done = 0, false
    local fn
    fn = function()
        ticks = ticks + 1
        if not done and ticks >= 2 then
            done = true
            local pd = getPlayerData and getPlayerData(0)
            if pd then
                if pd.playerInventory and pd.playerInventory.inventoryPane then
                    pcall(function() pd.playerInventory.inventoryPane:refreshContainer() end)
                end
                if pd.lootInventory and pd.lootInventory.inventoryPane then
                    pcall(function() pd.lootInventory.inventoryPane:refreshContainer() end)
                end
            end
        end
        if done or ticks > 10 then Events.OnTick.Remove(fn) end
    end
    Events.OnTick.Add(fn)
end

-- =====================================================================
--  HOOK (future): record/recall presentation. No-op now — the mechanic is
--  intentionally instant/OOC. This is the single seam to hang a crystal-ball
--  animation / VFX / sound off later without touching the apply logic.
--    kind = "saved"    (journal was just written)
--         = "recalled" (character was just restored/rebuilt from the journal)
--  Fires AFTER the authoritative result has been mirror-applied locally.
-- =====================================================================
function MMClient.playFX(player, kind)
    -- intentionally empty; fill in when the animation/icon system lands
end

local function onServerCommand(module, command, args)
    if module ~= MMShared.MODULE then return end

    if command == MMShared.CMD.RESULT then
        if args.ok and args.applyData then
            -- MIRROR-APPLY the same change the server made, on our local player.
            -- pcall-armored so a mirror failure is loud (MMwarn) instead of half-updating
            -- the UI silently — server state is already applied; a broken mirror heals on
            -- relog, but it must never die quietly.
            local p = getPlayer()
            if p and not p:isDead() then
                local okApply, err = pcall(function()
                    -- fullRestore rides along for admin disaster-recovery restores
                    -- (MMRestore) so the mirror bypasses the XP knob exactly like
                    -- the server apply did; nil/absent for normal memoir reads.
                    MMSnapshotCodec.applyToCharacter(p, args.applyData.snap, args.applyData.chosen,
                        args.applyData.xpMode, args.applyData.fullRestore)
                end)
                if not okApply then
                    MMwarn("mirror-apply FAILED (server state is applied; relog to resync): " .. tostring(err))
                end
                p:resetModelNextFrame()
                if sendVisual then sendVisual(p) end
                MMlog("mirror-applied result locally")
            end
        end
        if args.ok then
            local p = getPlayer()
            if p then MMClient.playFX(p, args.applyData and "recalled" or "saved") end
            refreshInventorySoon() -- so the Memoir <-> "Memoirs of X" rename shows immediately
        end
        if args.say then say(getText(args.say) or args.say) end
        if not args.ok then MMlog("server denied: " .. tostring(args.reason)) end
    end
end
Events.OnServerCommand.Add(onServerCommand)

MMlog("MMClient ready")
