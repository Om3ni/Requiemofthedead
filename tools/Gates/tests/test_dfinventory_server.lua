-- DFInventory_Server fixture - a resolved player inventory mutation must
-- directly transmit its ModData after the authoritative container update.

local ROOT = arg[1] or "."
local SOURCE = ROOT .. "/RequiemOfTheDead/Contents/mods/Dragonfly/42/media/lua/server/DFInventory_Server.lua"

local passed, failed = 0, 0
local function check(ok, message)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL DFInventory_Server: " .. message)
    end
end

isServer = function() return true end
-- Engine container-sync globals (GameServer:2220/:2250). Real ones null-guard
-- every branch; the stubs just record that the call was made.
local addedToContainer = {}
sendAddItemToContainer = function(c, i) addedToContainer[#addedToContainer + 1] = i end
RDChunk = nil
Capability = { InspectPlayerInventory = "inspect", EditItem = "edit" }
local registered, onServerStarted = {}, nil
DFServer = { registerHandler = function(def) registered[def.action] = def end }
Events = { OnServerStarted = { Add = function(fn) onServerStarted = fn end } }
local audits = {}
DFCore = {
    MODULE = "Dragonfly",
    audit = function(action, player, text)
        audits[#audits + 1] = { action = action, player = player, text = text }
    end,
}

local item = { fullType = "Base.Apple" }
local items = {
    size = function() return 1 end,
    get = function(_, index) return index == 0 and item or nil end,
}
local cleared, transmitted, removed = 0, 0, {}
local inventory = {
    getItems = function() return items end,
    clear = function() cleared = cleared + 1 end,
}
local target = {
    getInventory = function() return inventory end,
    transmitModData = function() transmitted = transmitted + 1 end,
}
getPlayerFromUsername = function(username)
    return username == "Moth" and target or nil
end
getOnlinePlayers = function() return nil end
sendRemoveItemFromContainer = function(container, removedItem)
    removed[#removed + 1] = { container = container, item = removedItem }
end

DFInventory = nil
local ok, err = pcall(dofile, SOURCE)
check(ok, "module loads: " .. tostring(err))
check(type(onServerStarted) == "function", "registers deferred handlers")
onServerStarted()

local dump = registered.playerInventoryDump
check(type(dump) == "table" and type(dump.run) == "function", "registers dump handler")
local result = dump.run({ getUsername = function() return "Admin" end }, { username = "Moth" })
check(result.ok and result.message == "Dumped 1 items from Moth.", "dump completes")
check(cleared == 1 and #removed == 1 and removed[1].container == inventory and removed[1].item == item,
    "dump clears and sends each removed item")
check(transmitted == 1, "resolved target ModData sync is sent directly")
check(#audits == 1 and audits[1].action == "playerInventoryDump", "dump remains audited")

-- ---------------------------------------------------------------------------
-- Per-item isolation in playerInventorySnapshot.
--
-- InventoryItem.isHidden() is `return this.scriptItem.isHidden()` with NO null
-- check (InventoryItem.java:3849-3851), and scriptItem IS null on a legacy item
-- whose script has been removed from the game.
--
-- That NPE never reaches Lua. isHidden is an exposed method, so MethodCaller
-- swallows the throw and the call returns nil (MethodCaller.java:33-56), which
-- the row reads as not-hidden. Every other engine call on the row answers a
-- faulted item the same way, and every nil lands in a declared fallback:
-- `ft or "?"`, `name or ft or "?"`, `count or 1`.
--
-- So the contract is NOT isolation-by-skipping. It is that a malformed item
-- contributes a VISIBLE "?" row instead of vanishing - which is what an
-- inspecting admin actually needs. The skip counter and circuit breaker this
-- fixture used to pin were built for throws the dispatch lanes cannot deliver;
-- production removed them and says so at DFInventory_Server.lua:271-292.
-- ---------------------------------------------------------------------------

local function mkItem(name, broken)
    local it
    it = {
        -- A faulted engine call arrives in Lua as NIL, never as a throw: these
        -- are exposed methods, so MethodCaller catches the NPE, stack-traces it
        -- to the console and pushes no return value (MethodCaller.java:33-56).
        -- Corrected 2026-08-19; these used to call error().
        isHidden          = function() if broken == "hidden" then return nil end return false end,
        getFullType       = function() if broken == "type" then return nil end return "Base." .. name end,
        getName           = function() if broken == "name" then return nil end return name end,
        getCondition      = function() return 10 end,
        getConditionMax   = function() return 10 end,
        getCount          = function() return 1 end,
        -- resolveLocation reads the hotbar slot on every item;
        -- -1 is the engine's 'not attached' answer.
        getAttachedSlot   = function() return -1 end,
    }
    return it
end

RDItemKind = {
    classify   = function() return "bucket", "cat", false end,
    typeLabel  = function() return "label" end,
}
RDChunk = nil

local snapshotRows, snapLog = nil, {}
local realPrint2 = print
local function runSnapshot(list)
    local inv = {
        getItems = function()
            return { size = function() return #list end,
                     get  = function(_, i) return list[i + 1] end }
        end,
    }
    local player = {
        getInventory      = function() return inv end,
        getUsername       = function() return "Moth" end,
        getPrimaryHandItem   = function() return nil end,
        getSecondaryHandItem = function() return nil end,
        getWornItems      = function() return nil end,
        transmitModData   = function() end,
    }
    getPlayerFromUsername = function(u) return u == "Moth" and player or nil end
    snapLog = {}
    print = function(x) snapLog[#snapLog + 1] = tostring(x) end
    local def = registered["playerInventorySnapshot"]
    local sent = {}
    sendServerCommand = function(_, _, _, payload) sent[#sent + 1] = payload end
    local rok, res = pcall(def.run, player, { username = "Moth" })
    print = realPrint2
    return res, sent
end

if registered["playerInventorySnapshot"] then
    local healthy = { mkItem("Apple"), mkItem("Bread"), mkItem("Nails") }
    runSnapshot(healthy)
    local line = table.concat(snapLog, "\n")
    check(line:find("items=3", 1, true), "a healthy inventory lists every item")
    check(not line:find("skipped", 1, true),
          "no skip counter: it counted throws the lanes cannot deliver")

    -- A legacy item whose scriptItem is gone. isHidden returns nil, which reads
    -- as not-hidden, so the item is LISTED rather than skipped - the admin sees
    -- it exists and is broken, instead of it silently vanishing from the pane.
    local mixed = { mkItem("Apple"), mkItem("Ghost", "hidden"), mkItem("Nails") }
    runSnapshot(mixed)
    line = table.concat(snapLog, "\n")
    check(line:find("items=3", 1, true),
        "an item with a dead scriptItem still gets a row - visible beats vanished")

    -- getFullType returning nil is the case the OLD guards never covered at all.
    -- The row survives on the `ft or "?"` fallback.
    local lateBreak = { mkItem("Apple"), mkItem("Rot", "type"), mkItem("Nails") }
    runSnapshot(lateBreak)
    line = table.concat(snapLog, "\n")
    check(line:find("items=3", 1, true),
        "a nil getFullType costs no row either - it falls back to the ? placeholder")

    -- ------------------------------------------------------------------
    -- WORN CLOTHING IS IN BOTH LISTS, AND THE WORN ROW MUST WIN.
    -- A worn garment's container IS the character's inventory
    -- (Clothing.java:1096-1100), so it appears in the main walk AND in
    -- getWornItems(). Until 2026-08-25 main enumerated first and the dedupe
    -- swallowed the worn pass whole: a fully dressed player snapshotted as
    -- worn=0 with every garment reading "Main". These pins model the real
    -- engine shape - the SAME item object in both lists - because a fixture
    -- that keeps them disjoint cannot see the bug.
    -- ------------------------------------------------------------------
    local shirt, jeans = mkItem("Shirt"), mkItem("Jeans")
    local wornEntries = {
        { getItem = function() return shirt end, getLocation = function() return "Torso" end },
        { getItem = function() return jeans end, getLocation = function() return "Legs" end },
    }
    do
        -- A dressed player: two garments worn AND in the main list, one loose item.
        local list = { shirt, mkItem("Apple"), jeans }
        local inv = {
            getItems = function()
                return { size = function() return #list end,
                         get  = function(_, i) return list[i + 1] end }
            end,
        }
        local player = {
            getInventory      = function() return inv end,
            getUsername       = function() return "Moth" end,
            getPrimaryHandItem   = function() return nil end,
            getSecondaryHandItem = function() return nil end,
            getWornItems      = function()
                return { size = function() return #wornEntries end,
                         get  = function(_, i) return wornEntries[i + 1] end }
            end,
            transmitModData   = function() end,
        }
        local rows = DFInventory.listAddressableItems(player)
        check(#rows == 3, "the dedupe holds: a worn garment gets ONE row, not two: " .. #rows)
        local bySource, locs = {}, {}
        for _, e in ipairs(rows) do
            bySource[e.source] = (bySource[e.source] or 0) + 1
            if e.loc then locs[tostring(e.loc)] = true end
        end
        check(bySource.worn == 2,
            "both garments are WORN rows, not main - the regression this order exists for: "
            .. tostring(bySource.worn))
        check(bySource.main == 1, "the loose item stays a main row")
        check(locs["Torso"] and locs["Legs"],
            "and the worn rows carry their body locations for the Location column")
    end

-- ---------------------------------------------------------------------------
-- REGRESSION PINS (live dedicated-server report, 2026-08-18).
--
-- The first per-item boundary shipped three defects at once:
--   1. getName was folded INTO the boundary, so a cosmetic display-string
--      failure dropped the entire row and the admin silently lost items;
--   2. the diagnostic printed once per failing item - a flood, not a report;
--   3. per-item isolation over a SYSTEMATIC failure multiplied the engine's
--      own throw-time stack traces by the size of the inventory.
--
-- Defect 1 is the one that still has a live failure mode, and it is pinned
-- below. Defects 2 and 3 were consequences of the per-item boundary itself,
-- which is gone - so the bounded-diagnostic and circuit-breaker assertions
-- that used to live here went with it (corrected 2026-08-19). What replaces
-- them is the property that made them unnecessary: no engine fault on one row
-- can affect any other row, because no engine fault reaches Lua at all.
-- ---------------------------------------------------------------------------
if registered["playerInventorySnapshot"] then
    local function namedItem(name, breakName)
        return {
            isHidden        = function() return false end,
            getFullType     = function() return "Base." .. name end,
            getName         = function()
                -- nil, not a throw - see the mkItem header.
                if breakName then return nil end
                return name
            end,
            getCondition    = function() return 10 end,
            getConditionMax = function() return 10 end,
            getCount        = function() return 1 end,
            getAttachedSlot = function() return -1 end,
        }
    end

    -- 1. a broken getName must NOT cost the row - it falls back to fullType.
    runSnapshot({ namedItem("Apple"), namedItem("Ghost", true), namedItem("Nails") })
    local line = table.concat(snapLog, "\n")
    check(line:find("items=3", 1, true),
          "a garment whose getName throws still appears in the listing - cosmetic "
          .. "failure, cosmetic fallback, row preserved")
    check(line:find("nameFallback=1", 1, true), "the fallback is counted and visible")

    -- The counter must track NILS, not throws. An old version counted a failure
    -- mode that could not happen, so it never moved off zero and the diagnostic
    -- was dead the day it shipped.
    runSnapshot({ namedItem("Apple"), namedItem("Bread"), namedItem("Nails") })
    check(table.concat(snapLog, "\n"):find("nameFallback=0", 1, true),
          "and stays at zero when every name resolves - a live counter, not a dead one")

    -- A wholly systematic failure. Every item broken, and the snapshot still
    -- completes with every row present: there is no circuit breaker because
    -- there is nothing to break - not one of these faults reaches Lua.
    local many = {}
    for i = 1, 40 do many[i] = namedItem("Broken" .. i, true) end
    runSnapshot(many)
    line = table.concat(snapLog, "\n")
    check(line:find("items=40", 1, true),
          "40 broken items still produce 40 rows - no aborting, no skipping")
    check(line:find("nameFallback=40", 1, true), "and all 40 are reported as fallbacks")
    check(not line:find("ABORTED", 1, true),
          "no circuit breaker: it existed for a throw storm that cannot occur")

    -- One bad item among good ones changes nothing for its neighbours.
    local mostlyGood = {}
    for i = 1, 12 do mostlyGood[i] = namedItem("Good" .. i) end
    mostlyGood[5] = namedItem("Bad", true)
    runSnapshot(mostlyGood)
    line = table.concat(snapLog, "\n")
    check(line:find("items=12", 1, true) and line:find("nameFallback=1", 1, true),
          "one bad item among many costs no row and is counted exactly once")
else
    check(false, "playerInventorySnapshot handler is registered")
end


-- ---------------------------------------------------------------------------
-- AddItem: the nil return IS the contract.
--
-- ItemContainer.AddItem(String) returns null for an unfindable type
-- (ItemContainer.java:511-513), an obsolete script, or a factory failure - it
-- does not throw, so the old guard was reading a failure mode that does not
-- exist. What must be preserved is that a bad type still reports refusal.
-- ---------------------------------------------------------------------------
if registered["playerInventoryAdd"] then
    local addLog = {}
    local addInv = {
        AddItem = function(_, ft)
            if ft == "Base.Nope" then return nil end          -- engine's refusal
            return { fullType = ft, getContainer = function() return nil end }
        end,
        getItems = function() return { size = function() return 0 end,
                                       get = function() return nil end } end,
    }
    local addTarget = {
        getInventory = function() return addInv end,
        getUsername  = function() return "Moth" end,
        transmitModData = function() end,
    }
    getPlayerFromUsername = function(u) return u == "Moth" and addTarget or nil end
    local def = registered["playerInventoryAdd"]

    local r = def.run(addTarget, { username = "Moth", fullType = "Base.Apple", count = 3 })
    check(r and r.ok == true, "a good type adds and reports success")
    check(r.message:find("Added 3 x Base.Apple", 1, true), "and names the count it added")

    r = def.run(addTarget, { username = "Moth", fullType = "Base.Nope", count = 2 })
    check(r and r.ok == false, "the engine's nil return is still reported as a refusal")
    check(r.reason:find("AddItem refused", 1, true), "with the bad-type reason intact")

    -- the packet-flood clamp must survive the rewrite
    r = def.run(addTarget, { username = "Moth", fullType = "Base.Apple", count = 9999 })
    check(r.message:find("Added 100 x", 1, true), "the MAX_ADD clamp of 100 still holds")
else
    check(false, "playerInventoryAdd handler is registered")
end

-- ---------------------------------------------------------------------------
-- Repair All: a garment whose ClothingItem asset is absent or not READY makes
-- getVisual() return null (InventoryItem.java:2070-2075), and fullyRestore
-- dereferences it unguarded (Clothing.java:996-1014). One such garment must
-- not cost the others their repair - and the failure must be REPORTED, because
-- a silent one is indistinguishable from a repair that did nothing.
--
-- THE STUB MODELS A PRECONDITION, NOT A GUARD (corrected 2026-08-19). This
-- fixture used to make fullyRestore call error(). It cannot: fullyRestore is an
-- exposed method, so the NPE was swallowed by MethodCaller AFTER condition,
-- dirt and blood had already been applied, and the half-restored garment was
-- counted as repaired (MethodCaller.java:33-56). Production now asks
-- getVisual() FIRST and skips the garment whole, which is deterministic and
-- makes the failure count honest. So `broken` here means "getVisual returns
-- nil" - the real, checkable condition - and fullyRestore never throws.
-- ---------------------------------------------------------------------------
if registered["playerInventoryRepairAll"] then
    local function garment(name, broken)
        local visual = not broken and {} or nil
        return { fullType = "Base." .. name,
                 getCondition = function() return 1 end,
                 getAttachedSlot = function() return -1 end,
                 getVisual = function() return visual end,
                 fullyRestore = function() end }
    end
    local list = { garment("Shirt"), garment("Ghost", true), garment("Jeans") }
    local repTarget = {
        getInventory = function()
            return { getItems = function()
                return { size = function() return #list end,
                         get = function(_, i) return list[i + 1] end } end }
        end,
        getUsername = function() return "Moth" end,
        getPrimaryHandItem = function() return nil end,
        getSecondaryHandItem = function() return nil end,
        getWornItems = function() return nil end,
        transmitModData = function() end,
    }
    getPlayerFromUsername = function(u) return u == "Moth" and repTarget or nil end
    RDClothing = RDClothing or {}
    RDClothing.isClothing = function() return true end
    RDClothing.sync = function() end

    local repLog = {}
    local realP = print
    print = function(x) repLog[#repLog + 1] = tostring(x) end
    local r = registered["playerInventoryRepairAll"].run(repTarget, { username = "Moth" })
    print = realP

    check(r and r.ok == true, "the repair pass completes despite a bad garment")
    check(r.message:find("Repaired 2 item(s)", 1, true),
          "the two healthy garments are still repaired")
    local joined = table.concat(repLog, "\n")
    check(joined:find("1 garment(s) could not be restored", 1, true),
          "the failure is REPORTED, not swallowed - a silent one looks like success")
    local lastAudit = audits[#audits]
check(lastAudit and lastAudit.action == "playerInventoryRepairAll"
      and tostring(lastAudit.text):find("failed=1", 1, true),
      "and the audit record carries the failed count")
else
    check(false, "playerInventoryRepairAll handler is registered")
end

else
    check(false, "playerInventorySnapshot handler is registered")
end


print(string.format("DFInventory_Server: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
