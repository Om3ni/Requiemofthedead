-- test_lrbandageswap.lua - Last Rites' one-step bandage swap.
--
-- Pins the contract LRBandageSwap.lua depends on: the option appears only on a
-- bandaged part with a CLEAN bandage in reach, never on a menu vanilla hid, and
-- a pick queues vanilla's own actions in fetch -> strip -> dress order with the
-- panel's doctor/patient split (ISHealthPanel.lua:1137-1143) preserved.

local ROOT = arg[1] or "."
local SRC = ROOT .. "/RequiemOfTheDead/Contents/mods/RFTDLastRites"
             .. "/42/media/lua/client/LRBandageSwap.lua"

local pass, fail = 0, 0
local function eq(name, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print("FAIL " .. name)
        print("  got:  " .. tostring(got))
        print("  want: " .. tostring(want))
    end
end

-- ── engine / vanilla stand-ins ────────────────────────────
local function arrayList(t)
    return {
        size = function() return #t end,
        get  = function(_, i) return t[i + 1] end,
    }
end

local function container(items)
    local c = {}
    c.items = items
    c.getItems = function() return arrayList(c.items) end
    for _, it in ipairs(items) do it.container = c end
    return c
end

local function item(fullType, power)
    local it = { fullType = fullType, power = power }
    it.getFullType      = function() return it.fullType end
    it.getType          = function() return (it.fullType:gsub("^[^.]*%.", "")) end
    it.getName          = function() return it.fullType end
    it.getBandagePower  = function() return it.power end
    it.IsInventoryContainer = function() return it.bag ~= nil end
    it.getInventory     = function() return it.bag end
    it.getContainer     = function() return it.container end
    return it
end

local function bagItem(inner)
    local b = item("Base.Bag_Schoolbag", 0)
    b.bag = inner
    return b
end

local function character(num)
    local ch = { num = num }
    ch.getPlayerNum = function() return ch.num end
    ch.getInventory = function() return ch.inventory end
    return ch
end

local function bodyPart(bandaged, worn)
    return {
        bandaged       = function() return bandaged end,
        getBandageType = function() return worn end,
    }
end

-- The context menu vanilla hands back (ISContextMenu.lua:1166-1167).
local function menu()
    local m = { options = {}, visible = true }
    function m:addOption(name, target, fn, arg)
        local o = { name = name, target = target, fn = fn, arg = arg }
        self.options[#self.options + 1] = o
        return o
    end
    function m:getNew() return menu() end
    function m:addSubMenu(option, sub) option.sub = sub end
    function m:getIsVisible() return self.visible end
    return m
end

local context
getPlayerContextMenu = function() return context end

local doctorContainers
ISInventoryPaneContextMenu = {
    getContainers = function() return arrayList(doctorContainers) end,
}

-- Queue model after ISTimedActionQueue.lua:203-222 - addAfter is a no-op when
-- the anchor is not queued, and that is the behavior the chain must survive.
local queue = {}
ISTimedActionQueue = {
    add = function(a) queue[#queue + 1] = a end,
    addAfter = function(prev, a)
        for i, q in ipairs(queue) do
            if q == prev then table.insert(queue, i + 1, a); return a end
        end
        return nil
    end,
}

HealthPanelAction = {
    new = function(_, ch, handler, a1)
        return { kind = "panel", character = ch, handler = handler, arg = a1 }
    end,
}
ISApplyBandage = {
    new = function(_, doctor, patient, it, part, doIt)
        return { kind = doIt and "dress" or "strip", doctor = doctor,
                 patient = patient, item = it, part = part }
    end,
}
ISInventoryTransferUtil = {
    newInventoryTransferAction = function(ch, it, from, to)
        return { kind = "fetch", character = ch, item = it, from = from, to = to }
    end,
}

local origCalls = 0
ISHealthPanel = { doBodyPartContextMenu = function() origCalls = origCalls + 1 end }

isServer   = function() return false end
getText    = function(k) return k end
instanceItem = function(t) return { worn = t } end
require    = function() end

dofile(SRC)

-- ── fixtures ──────────────────────────────────────────────
local function setup(opts)
    queue = {}
    context = menu()
    context.visible = opts.visible ~= false

    local me, other = character(0), character(1)
    local clean  = item("Base.Bandage", 4)
    local dirty  = item("Base.BandageDirty", 1)
    local inner  = container({ clean })
    local inv    = container({ dirty, bagItem(inner) })
    me.inventory = inv
    if opts.cleanInMain then
        inv.items[#inv.items + 1] = item("Base.AlcoholBandage", 6)
        inv.items[#inv.items].container = inv
    end
    doctorContainers = { inv }

    -- Treating someone else: panel.character is the patient, otherPlayer the
    -- doctor (ISHealthPanel.lua:1137-1143).
    local panel = opts.other and { character = other, otherPlayer = me }
                             or  { character = me }
    local part = bodyPart(opts.bandaged ~= false, "Base.BandageDirty")
    return panel, part, me, other, clean
end

local function open(panel, part)
    ISHealthPanel.doBodyPartContextMenu(panel, part, 0, 0)
    for _, o in ipairs(context.options) do
        if o.name == "IGUI_LR_ReplaceBandage" then return o end
    end
    return nil
end

-- ── wrap ──────────────────────────────────────────────────
local panel, part = setup({})
local before = origCalls
local opt = open(panel, part)
eq("vanilla menu still built", origCalls, before + 1)
eq("option offered on a bandaged part", opt ~= nil, true)
eq("icon is the worn bandage", opt and opt.itemForTexture.worn, "Base.BandageDirty")
eq("only the clean bandage is offered", opt and #opt.sub.options, 1)
eq("the offered type reaches into bags", opt and opt.sub.options[1].arg, "Base.Bandage")

panel, part = setup({ bandaged = false })
eq("no option on an unbandaged part", open(panel, part), nil)

panel, part = setup({ visible = false })
eq("no option on a menu vanilla hid", open(panel, part), nil)

-- ── pick: self, bandage in a bag ──────────────────────────
local me, clean
panel, part, me, _, clean = setup({})
opt = open(panel, part)
local pick = opt.sub.options[1]
pick.fn(pick.target, pick.arg)
eq("pick queues one HealthPanelAction", #queue, 1)
local hpa = queue[1]
eq("action runs as the doctor", hpa.character, me)
eq("handler validates", hpa.handler:isValid(hpa.arg), true)

hpa.handler:perform(hpa, hpa.arg)
eq("chain length", #queue, 4)
eq("1 fetch",  queue[2].kind, "fetch")
eq("2 strip",  queue[3].kind, "strip")
eq("3 dress",  queue[4].kind, "dress")
eq("fetch moves the chosen bandage", queue[2].item, clean)
eq("fetch lands in the doctor's inventory", queue[2].to, me.inventory)
eq("dress uses the fetched bandage", queue[4].item, clean)
eq("strip takes the old one off, no item", queue[3].item, nil)
eq("fetch is shown on the part's row", panel.actions[queue[2]], part)

-- ── pick: bandage already in the main inventory ───────────
panel, part, me = setup({ cleanInMain = true })
opt = open(panel, part)
local mainPick
for _, o in ipairs(opt.sub.options) do
    if o.arg == "Base.AlcoholBandage" then mainPick = o end
end
mainPick.fn(mainPick.target, mainPick.arg)
queue[1].handler:perform(queue[1], queue[1].arg)
eq("no fetch when already carried", #queue, 3)
eq("strip first", queue[2].kind, "strip")
eq("then dress", queue[3].kind, "dress")

-- ── pick: treating another player ─────────────────────────
local other
panel, part, me, other = setup({ other = true })
opt = open(panel, part)
pick = opt.sub.options[1]
pick.fn(pick.target, pick.arg)
queue[1].handler:perform(queue[1], queue[1].arg)
eq("doctor is the one holding the panel", queue[3].doctor, me)
eq("patient is the panel's character", queue[3].patient, other)
eq("dress patient matches", queue[4].patient, other)

-- ── the bandage vanished before the action ran ────────────
panel, part = setup({})
opt = open(panel, part)
pick = opt.sub.options[1]
pick.fn(pick.target, pick.arg)
doctorContainers = {}
eq("isValid fails once the bandage is gone", queue[1].handler:isValid(queue[1].arg), false)

-- ── reload does not stack a second wrap ───────────────────
local wrapped = ISHealthPanel.doBodyPartContextMenu
dofile(SRC)
eq("reload keeps the single wrap", ISHealthPanel.doBodyPartContextMenu, wrapped)

print(string.format("Last Rites bandage swap: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
