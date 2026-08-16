-- Memoir refresh: after a successful result, both live inventory panes rebuild
-- after two ticks so the server-side item rename is visible. The pane guards in
-- MMClient are the lifecycle boundary; refreshContainer is vanilla local UI work.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDMemoir"
             .. "/42/media/lua/client/MMClient.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

isServer = function() return false end
MMShared = {
    MODULE = "RFTDMemoir",
    CMD = { RESULT = "result", WRITE_REQUEST = "write", READ_REQUEST = "read", DUMP = "dump" },
}
package.preload.MMSvShared = function() return MMShared end
MMSnapshotCodec = { applyToCharacter = function() end }
package.preload.MMSnapshotCodec = function() return MMSnapshotCodec end
MMlog = function() end
MMwarn = function() end

local serverCommand, tick
Events = {
    OnServerCommand = { Add = function(fn) serverCommand = fn end },
    OnTick = {
        Add = function(fn) tick = fn end,
        Remove = function(fn) if tick == fn then tick = nil end end,
    },
}

local playerPaneCalls, lootPaneCalls = 0, 0
getPlayerData = function()
    return {
        playerInventory = { inventoryPane = { refreshContainer = function() playerPaneCalls = playerPaneCalls + 1 end } },
        lootInventory = { inventoryPane = { refreshContainer = function() lootPaneCalls = lootPaneCalls + 1 end } },
    }
end
getPlayer = function() return {} end
getText = function(text) return text end

dofile(SRC)
eq("registers a server-command listener", type(serverCommand), "function")

serverCommand("RFTDMemoir", "result", { ok = true })
eq("schedules delayed inventory refresh", type(tick), "function")
tick()
eq("does not refresh before the name sync delay", playerPaneCalls + lootPaneCalls, 0)
tick()
eq("refreshes the player inventory pane once", playerPaneCalls, 1)
eq("refreshes the loot inventory pane once", lootPaneCalls, 1)
eq("removes the completed tick listener", tick, nil)

print(string.format("Memoir client: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
