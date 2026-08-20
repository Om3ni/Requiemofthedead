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
local applyOutcome = { ok = true, partial = false, phase = "complete" }
local applyCalls = 0
MMSnapshotCodec = { applyToCharacter = function()
    applyCalls = applyCalls + 1
    return applyOutcome
end }
package.preload.MMSnapshotCodec = function() return MMSnapshotCodec end
MMlog = function() end
local warnings = {}
MMwarn = function(message) warnings[#warnings + 1] = tostring(message) end

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
local modelResets = 0
local localPlayer = {
    isDead = function() return false end,
    resetModelNextFrame = function() modelResets = modelResets + 1 end,
}
getPlayer = function() return localPlayer end
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

serverCommand("RFTDMemoir", "result", {
    ok = true,
    applyData = { snap = {}, chosen = {}, xpMode = "overwrite" },
})
eq("successful result mirror-applies once", applyCalls, 1)
eq("successful mirror schedules a model refresh", modelResets, 1)
eq("successful mirror emits no warning", #warnings, 0)

applyOutcome = { ok = false, partial = true, phase = "body", error = "weight failed" }
serverCommand("RFTDMemoir", "result", {
    ok = true,
    applyData = { snap = {}, chosen = {}, xpMode = "overwrite" },
})
eq("failed result mirror still attempts once", applyCalls, 2)
eq("failed mirror remains observable", #warnings, 1)
eq("failed mirror warning names the phase", warnings[1]:find("phase=body", 1, true) ~= nil, true)
eq("failed mirror warning requires relog", warnings[1]:find("relog to resync", 1, true) ~= nil, true)

print(string.format("Memoir client: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
