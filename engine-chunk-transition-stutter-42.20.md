# Engine determination — Cell-transition stutter, and why dense→sparse is the bad direction (42.20.0)

*Verified against `PZ_Engine_Decompiled_42.20.0-a2947723ca`, 2026-08-02. Companion to
`engine-zombie-cull-42.20.md`.*

**Short version: the "zombies loading and unloading" instinct is correct, with one
refinement — the expensive edge is the TRAILING one. Leaving a dense area is the
worst case the pipeline has, it all runs on the server main thread, and a driver
crossing chunk boundaries re-triggers it continuously. With
`ZombiesCountBeforeDelete` at its default 300, the cull storm stacks on top of the
same frames. One player's transition stalls the tick for every connected client.**

## The transition pipeline

### Leading edge (chunks loading) — cheap when entering sparse areas

The native popman materializes virtual zombies for newly loaded chunks;
`updateMain` drains **all** pending spawns in a single frame with no per-frame budget
([ZombiePopulationManager.java:485-517](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L485)).
Entering a dense area spikes; entering a sparse area costs little. So the leading edge
is not what you're feeling on dense→sparse moves.

### Trailing edge (chunks unloading) — the expensive direction, main thread

Chunk-grid scroll unloads a full row/column of chunks per boundary crossing
([IsoChunkMap.java:694](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/iso/IsoChunkMap.java#L694)
and siblings). Each unloading chunk runs `IsoChunk.removeFromWorld`
([IsoChunk.java:2922](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/iso/IsoChunk.java#L2922)),
which does, in order:

1. **Per-zombie virtualization walk**
   ([ZombiePopulationManager.removeChunkFromWorld:348](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L348)):
   iterate every square (8×8×levels); for each real zombie, acquire `saveLock`, call
   `n_addZombie`, then the full `IsoZombie.removeFromWorld` teardown (pathfind-request
   cancel, group removal, online-id retirement, ownership-list mutation). Cost scales
   with how many zombies are on the chunk — **leaving Louisville is the worst case by
   construction**.
2. **A whole-cell save request per chunk**
   ([IsoChunk.java:2940](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/iso/IsoChunk.java#L2940) →
   [requestSaveCell:180](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L180)):
   scans the **entire server-wide real-zombie list** under `saveLock` to snapshot one
   popman cell (256×256 tiles), and queues the save — **unconditionally, no dedup**.
   Driving across one popman cell (32 chunks) unloads ~a dozen chunks per boundary ×
   32 boundaries: dozens of O(all-zombies) scans and dozens of mostly-duplicate cell
   saves queued.
3. Pathfind/collision chunk removal, then per-square teardown.

### The worker-thread coupling

The queued cell saves are drained on the **MapCollisionData worker thread**
([MapCollisionData.java:507](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/MapCollisionData.java#L507)),
inside one `renderLock` block that also runs the collision path-tasks, `n_update`,
and the popman's own thread step. Each save holds `saveLock` through
`n_saveRealZombies` + `n_saveCell` (native serialization + zpop cell write,
[ZombiePopulationManager.java:218](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L218)).
Two consequences:

- The **main thread blocks** on `saveLock` mid-unload (it takes that lock per zombie
  in the virtualization walk) whenever the worker is writing a cell.
- The worker's other duties — collision data for **newly loading chunks** and the
  popman step that **generates the next spawns** — wait behind the save. Slow saves
  on the trailing edge literally delay zombie materialization on the leading edge.
  That is the "stutter in cell loading" signature.

## What the default-300 cull added on top

Same frames, same main thread
([MovingObjectUpdateScheduler.java:39](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/MovingObjectUpdateScheduler.java#L39)):

- A driver passing through town **accumulates ownership** of zombies within ~64 tiles
  as they go. In any dense area the owned count blows past 300 immediately.
- Everything falling behind (>60 tiles Euclidean, outdoors, targetless) is culled at
  ~10% per frame per zombie — each cull is another `removeFromWorld` teardown plus a
  `ZombieDeleteOnClient` packet, and each **mutates the owned list**, so the
  connection's `ZombieList` hash changes and full list-refresh packets go out
  ([NetworkZombiePacker.java:140](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombiePacker.java#L140)) —
  potentially every frame for the whole drive.
- The client is the simulation authority for its owned zombies; the server deleting
  them out from under the client mid-simulation forces continuous reconciliation on
  the driver's connection. "Black-boxed on a desync" is a fair description.
- And every deletion is a permanent population debit along the route (see the cull
  report) — the depopulation and the stutter are the same event.

## Blast radius: every client, yes

All of the above except the zpop write runs on the **server main thread**. One
player's dense→sparse transition lengthens the tick for the entire server: every
connection's player sync, zombie sync, and `OnClientCommand` processing waits.
Two observational notes:

- **"Larger mod packets" is more plausibly an effect than a cause.** RFTD wire
  traffic rides `OnClientCommand`/`sendServerCommand` on the same loop; a stalled
  tick backs sends up so they arrive in bursts. The dense→sparse directionality
  fingerprints the popman pipeline, not Lua — no mod hook runs per-chunk-unload.
- Other players' zombies can also vanish visibly during someone else's transition
  (the cull's cross-connection blind spot, documented in the cull report).

## Levers and diagnostics

| Action | Effect |
|---|---|
| `ZombieConfig.ZombiesCountBeforeDelete = 5000` | Removes the cull storm (packets + teardowns + permanent erasure) from transitions; keeps a backstop against true mega-hordes. **Recommended first move.** |
| `= 0` | Same, plus no backstop. Note the trade: `requestSaveCell` scans scale with total real-zombie count, so unbounded hordes make the *unload* scans more expensive — the stutter you're chasing worsens during blooms. |
| Lower zombie population multipliers | Directly shrinks both the virtualization walk and the O(N) snapshot scans. |

Diagnostics on the dedi:

- The engine's `Trigger_Zombie.xml` popman debug toggle is **dead on a dedicated
  server** — the file watcher is initialized
  ([GameServer.java:1334](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/GameServer.java#L1334))
  but only client game states ever poll it. Don't bother.
- No Lua event fires for culls or virtualization, and the network-statistics classes
  aren't Lua-exposed. What RFTD *can* do: RDMeter already measures tick gaps —
  correlate tick-time spikes with players crossing **popman cell boundaries**
  (`floor(x/256)` or `floor(y/256)` changing). If spikes line up with cell crossings
  rather than chunk crossings, that's the `requestSaveCell`/zpop-write path
  confirmed live; if they line up with every ~8-tile chunk edge while driving away
  from density, that's the virtualization walk.
- Server-side Lua can poll `getWorld():getCell():getZombieList():size()` cheaply;
  a sawtooth that drops as a driver leaves town quantifies cull volume (with the
  slider raised, the sawtooth should flatten).
