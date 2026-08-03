# Last Cup Coffee — barista starter kit ghost items (patch plan)

Status: **planned, not built.** Investigation 2026-08-03.

## The bug

`Last Cup Coffee` (workshop `3740865682`, mod id `LastCupCoffee`, load position **#146**, last)
grants the barista starting kit from a `shared/` file on `OnCreatePlayer`:

`shared/LastCupCoffee/LCC_Caffeine.lua:631-650`
```lua
local function giveBaristaStarterItems(id, playerObj)
    ...
    local data = player:getModData()
    if data.LCC_BaristaStarterGiven then return end
    ...
    inventory:AddItem("LastCupCoffee.LCC_CupCoffeeFull")
    inventory:AddItem("LastCupCoffee.LCC_BagCoffeeGroundUses")
    inventory:AddItem("LastCupCoffee.LCC_ManualGrinder")
    inventory:AddItem("LastCupCoffee.LCC_Apron")
    data.LCC_BaristaStarterGiven = true
    if player.transmitModData then player:transmitModData() end
end
Events.OnCreatePlayer.Add(giveBaristaStarterItems)   -- L728
```

**`OnCreatePlayer` never fires on a dedicated server.** Verified in the decompile — the only
three trigger sites are all client/local paths:
- `zombie/Lua/LuaManager.java:3467`
- `zombie/gameStates/GameLoadingState.java:434`
- `zombie/util/AddCoopPlayer.java:152` (splitscreen)

So the server never runs this at all. The four items are created **client-side only** and exist
nowhere on the server. Every inventory action sends an item ID; the server's `getItemWithID()`
returns null and the action silently no-ops — the items are unmovable phantoms.

Worse, the guard flag *does* reach the server (`transmitModData()`), so on relog the client
sees `LCC_BaristaStarterGiven = true`, skips, and the barista never gets a real kit.

Engine states the required pattern at `IsoGameCharacter.java:9509`:
> "the server should create item and sent it using the sendAddItemToContainer function."

## The patch

Two files, one new O&E module (house rules: own subfolder + prefix, own sandbox kill switch
via `OEShared.enabled`, no sibling dependency, one wire token dispatched by `RDNet`).

**Client** — runs before LCC because mod load order is handler order. Verified:
`zombie/Lua/Event.java:25` `callbacks` is an `ArrayList`, and `trigger()` iterates it by index,
so registration order == dispatch order. RFTD mods are #133-144, LCC is #146.

```
Events.OnCreatePlayer:
  if not barista            -> return
  if LCC_BaristaStarterGiven -> return          -- already handled (or upstream fixed it)
  set LCC_BaristaStarterGiven = true            -- local only, do NOT transmit
  RDNet.send(OEShared.MODULE, "baristaKit", {})
```

**Server** — `RDNet.register(OEShared.MODULE, "baristaKit", { capability = nil, rate = 2 }, ...)`
(`capability = nil` = open to players, server re-checks; see `RDNet.lua:18`).

```
verify player IS a barista       -- never trust the client
verify not already granted       -- server-side flag
for each of the 4 fullTypes:
    local it = inv:AddItem(t)
    if it then sendAddItemToContainer(inv, it) end
set RFTD_LCCBaristaKitGiven = true
set LCC_BaristaStarterGiven = true
player:transmitModData()
```

`sendAddItemToContainer(container, item)` is a Lua global and internally server-gated —
`zombie/Lua/LuaManager.java:9712`.

## Why this is upgrade-safe

If the author later fixes it server-side, they will set `LCC_BaristaStarterGiven` themselves.
Our client handler returns early when that flag is already set, so it never requests and there
is no double-grant. No version sniffing needed.

## Open decisions

1. **Placement.** O&E is the family catch-all and this fits ("too slight for its own mod id,
   too player-facing for Core"), but it is a *third-party compat patch*, a category the O&E
   house rules do not currently name. Alternative: RFTDCore, or a standalone compat mod.
2. **Report upstream.** The local patch is a workaround; the real fix is the author moving the
   grant to a server-side path. Worth filing regardless.
3. Barista detection must be reimplemented server-side — LCC's `isBarista` is a file-local
   function. Cheapest route is the profession-id string compare against
   `"lastcupcoffee:barista"` that LCC itself falls back to (`LCC_Caffeine.lua:235-241`).

## Scope note

Baristas only, 4 items, once per character. This does **not** cause the server-wide inventory
lag — that remains unexplained (see the investigation findings doc).
