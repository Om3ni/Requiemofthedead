# Engine determination — Observing the popman from Lua, and Reaper efficiency (42.20.0)

*Verified against `PZ_Engine_Decompiled_42.20.0-a2947723ca`, 2026-08-02. Companion to
`engine-zombie-cull-42.20.md` and `engine-chunk-transition-stutter-42.20.md`.*

**Short version: Trigger_Zombie.xml is an input trigger, not a metrics file, and it's
dead on a dedi anyway. But the engine gives server Lua everything needed to *derive*
popman activity: `OnZombieCreate` (fires for every materialization), `OnZombieDead`,
and the single server-wide zombie list. Births + deaths + list size recovers the
trailing-edge virtualization volume — the exact quantity that correlates with the
stutter. Reaper also has a big win available: its per-player cell walk is redundant.**

## Trigger_Zombie.xml — wrong tree, confirmed dead

It's an **input** file: the engine watches for it and reacts (`spawnHorde`, toggle
native popman debug logging —
[ZombiePopulationManager.java:244](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L244)).
There are no metrics in it to poll. And on a dedicated server the watcher is
initialized but never pumped — `DebugFileWatcher.update()` is called only from client
game states ([IngameState.java:1347](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/gameStates/IngameState.java#L1347)).
The handler and the logging flag are private with no Lua exposure. Dead end, twice over.

The gold-standard data *does* exist — the native popman exports per-cell
current/desired population and repop events, read by
[MPDebugInfo.java:91](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/MPDebugInfo.java#L91) —
but `MPDebugInfo` is not Lua-exposed, and its request flow only activates when a
**debug-mode client** sends `ServerDebugInfo` packets (the zombie population debug
renderer). Useful interactively from an admin client running `-debug`; unusable for
chronicle metrics.

## The Lua-visible surface that works

- **`OnZombieCreate`** — fired inside `createRealZombieAlways`
  ([VirtualZombieManager.java:325](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/VirtualZombieManager.java#L325)),
  the single funnel for every real-zombie materialization: popman chunk-load spawns,
  hordes, sadistic-AI events, Lua `createZombie`. Properly AddEvent-registered
  ([LuaEventManager.java:651](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaEventManager.java#L651)),
  so no first-trigger swallow. **Landmine #1:** it fires *before* the onlineId is
  assigned (:325 vs :335) — `getOnlineID()` in the handler returns −1; queue the ref
  and read the id next tick. **Landmine #2:** the same funnel runs client-side for
  remote-zombie instantiation — guard with `isServer()`.
- **`OnZombieDead`** — server-side deaths.
- **`getCell():getZombieList():size()`** — the total loaded real-zombie count.
  There is exactly **one IsoCell server-wide**; its list holds every loaded zombie
  regardless of which player's area loaded it (engine proof: `requestSaveCell`
  filters the single list by cell coords
  [ZombiePopulationManager.java:187](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L187);
  `clearTargetAuth` iterates it for all connections
  [NetworkZombieManager.java:212](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombieManager.java#L212)).
- **No event fires for virtualization or culls** — but it's recoverable by
  difference:

```
virtualized ≈ prevSize + births − deaths − reaperCulls − curSize
```

Sampled per second, that difference IS the trailing-edge churn — the stutter driver.
A "popman" sensor emitting `{size, births, deaths, reaperCulls, virtualized}` plus
per-player boundary crossings (`floor(x/8)` chunk, `floor(x/256)` popman cell,
timestamped) joined against RDMeter tick-gap spikes pinpoints these problems:
*"tick spike at T; player P crossed popman cell at T−0.2 s; 340 virtualized that
second"* — diagnosis without a debugger.

## Reaper efficiency findings

1. **The per-player cell walk is redundant.** RPCore's `forEachLoadedZombie` assumes
   each player's `getCell()` exposes a different area and dedupes by onlineId. On a
   dedi every `p:getCell()` returns the same singleton cell, whose zombie list is
   already server-wide (see proof above). The walk costs `players × zombies`
   iterations to visit `zombies`. One pass over
   `getWorld():getCell():getZombieList()` gives identical coverage — a 20× scan
   reduction on a 20-player server.
2. **Go event-driven on newborns.** `OnZombieCreate` replaces the 200-tick sweep as
   the twin detector — fingerprint at birth (deferred one tick for the onlineId).
   Keep a slow full sweep (minutes, not ~7 s) as the safety net.
3. **Two-stage fingerprinting.** `inventorySig` walks every item with per-item
   pcalls; compute tile+outfit first and only escalate to the inventory signature on
   a cheap-key collision.
4. **What's already right** (verified against the engine): the bounded cull queue
   (removals broadcast packets; the per-tick budget is what keeps Reaper from
   becoming the stutter source now that it's the only population deleter), and the
   drain-time onlineId re-check (IsoZombie objects really are pool-recycled —
   `resetForReuse`/`reuseZombie`).
