-- RCEternalTorch - the "Eternal Torch" admin cheat.
--
-- UNLIMITED-AMMO SEMANTICS (owner's spec): while the cheat is ON, every
-- blowtorch the admin is carrying simply never runs dry - no matter WHAT is
-- draining it (RC dismantles, vanilla welding/metalwork, other mods). There
-- is no engine "unlimited drainable" flag to set and Java drain paths can't
-- be wrapped from Lua, so this is a REFILL engine: a throttled tick keeps
-- every carried torch topped up to max uses (setCurrentUses/getMaxUses,
-- DrainableComboItem.java:75/80). Any drain snaps back within ~half a
-- second. RCDismantleAction additionally skips its own 10-use wear outright
-- (no bar flicker + the ledger's cheat=eternal-torch tag).
--
-- Per-tick discipline (the house no-per-tick-scans rule): when the cheat is
-- OFF the tick hook is a single boolean test and returns. The inventory
-- sweep runs only while ON, only for the LOCAL player, only every ~30 ticks,
-- and only for staff - an opt-in, bounded, self-throttled cheat, not a scan
-- loop.
--
-- UI: a checkbox on the vanilla "Admin Powers" cheat panel via
-- ISAdminPowerUI.AddOption (the same registration vanilla's own cheats use;
-- labels resolve from the panel's IGUI_CheatPanel_<id> scheme), gated by the
-- UseMechanicsCheat capability. Tick it and press SAVE. Toggling gives halo
-- feedback so a saved change is visibly confirmed. The flag persists in
-- player modData (survives relog); enforcement re-checks staff status LIVE,
-- so a de-admined player's leftover flag is inert.

if isServer() and not isClient() then return end

RCEternalTorch = RCEternalTorch or {}
RCEternalTorch.cheat = false

local KEY = "RC_EternalTorch"
local REFILL_TICKS = 30   -- ~0.5s at 60fps

-- Any blowtorch, no minimum uses (an already-dry torch refills too - that IS
-- the cheat now). Tag OR type, the vanilla predicate pair.
local function predicateTorch(item)
    return item ~= nil and (item:hasTag(ItemTag.BLOW_TORCH) or item:getType() == "BlowTorch")
end

-- Asked by RCDismantleAction: skip torch wear for this character? Staff-gated
-- at USE time, not just at toggle time.
function RCEternalTorch.active(character)
    return RCEternalTorch.cheat == true and RCShared.isAdmin(character)
end

-- Top up every carried torch (nested bags included) to max uses. Writes only
-- when a torch actually lost fuel, so the idle steady state syncs nothing.
local function refillTorches(playerObj)
    local list = playerObj:getInventory():getAllEvalRecurse(predicateTorch)
    for i = 0, list:size() - 1 do
        local it = list:get(i)
        if it:getCurrentUses() < it:getMaxUses() then
            it:setCurrentUses(it:getMaxUses())
        end
    end
end

local acc = 0
local function onPlayerUpdate(playerObj)
    if not RCEternalTorch.cheat then return end
    if playerObj ~= getPlayer() then return end
    acc = acc + 1
    if acc < REFILL_TICKS then return end
    acc = 0
    if not RCShared.isAdmin(playerObj) then return end
    pcall(refillTorches, playerObj)
end
Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- ---------------------------------------------------------------------------
-- Admin Powers panel registration + persistence
-- ---------------------------------------------------------------------------
local function setCheat(playerObj, selected)
    RCEternalTorch.cheat = selected == true
    if playerObj then
        playerObj:getModData()[KEY] = (selected == true) or nil
        -- immediate, visible confirmation that SAVE took (the 0.4.3 version
        -- failed silently - never again)
        if selected then
            RCShared.halo(playerObj, "Eternal Torch ON - your blowtorches will not drain.", false)
            pcall(refillTorches, playerObj)   -- top up right now, not in 0.5s
        else
            RCShared.halo(playerObj, "Eternal Torch OFF.", true)
        end
    end
end

local function registerOption()
    if not (ISAdminPowerUI and ISAdminPowerUI.AddOption) then
        error("ISAdminPowerUI.AddOption missing")
    end
    if ISAdminPowerUI.OptionById and ISAdminPowerUI.OptionById.EternalTorch then return end
    ISAdminPowerUI.AddOption("EternalTorch", "right", Capability.UseMechanicsCheat,
        function(self)
            return RCEternalTorch.cheat
        end,
        function(self, selected)
            setCheat(self.player or getPlayer(), selected)
        end
    )
end

local function onGameStart()
    -- restore the toggle from the character (modData persists across relogs)
    local p = getPlayer()
    if p then RCEternalTorch.cheat = p:getModData()[KEY] == true end

    local ok, err = pcall(registerOption)
    if ok then
        print("[RC] Eternal Torch registered on the Admin Powers panel (cheat="
            .. tostring(RCEternalTorch.cheat) .. ")")
    else
        print("[RC] Eternal Torch registration FAILED: " .. tostring(err))
    end
end

Events.OnGameStart.Add(onGameStart)
