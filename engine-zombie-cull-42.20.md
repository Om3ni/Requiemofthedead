# Engine determination — The "5000 zombie cap" and map depopulation (42.20.0)

*Verified line-by-line against `PZ_Engine_Decompiled_42.20.0-a2947723ca`, 2026-08-02.*

**Short version: there is no server-wide 5000 cap. The mechanic is
`ZombieConfig.ZombiesCountBeforeDelete` — default 300, slider max 5000, applied
per client connection, evaluated every server frame — and it PERMANENTLY ERASES
zombies from the world's population instead of returning them to the virtual
popman. The depopulation your server sees is real, and it is by construction.**

## What the mechanic actually is

[ZombieCountOptimiser.java](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombieCountOptimiser.java)
runs every server frame (`prepareZombiesForDeletion` in
[MovingObjectUpdateScheduler.java:39](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/MovingObjectUpdateScheduler.java#L39),
`deleteZombies` at
[:135](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/MovingObjectUpdateScheduler.java#L135)).

Per connection, it takes that client's **owned-zombie list** (`zombiesToSend`,
rebuilt each tick from the ownership table in
[NetworkZombiePacker.java:138](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombiePacker.java#L138))
and if it exceeds the cap, marks the excess for deletion. A zombie is deletable when
**all** of these hold
([ZombieCountOptimiser.java:37](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombieCountOptimiser.java#L37)):

- ~10% dice roll per frame (`Rand.Next(AdjustForFramerate(10)) == 0`) — an eligible
  zombie survives roughly a third of a second
- not a reanimated player
- **no current target** (actively chasing zombies are safe; idle/wandering ones are not)
- **outdoors** (no room, no roof —
  [:70](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombieCountOptimiser.java#L70))
- farther than `(relevantRange − 2) × 10` tiles (Euclidean) from every player **of the
  owning connection only**
  ([:57](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombieCountOptimiser.java#L57))

The cap itself:
[SandboxOptions.java:1975](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/SandboxOptions.java#L1975)
— `ZombieConfig.ZombiesCountBeforeDelete`, **min 0, max 5000, default 300**.
The devs' "5000" is the slider maximum, not the shipped value. **`0` disables the
mechanic entirely** (early return at
[:27](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombieCountOptimiser.java#L27)).

## Why it's permanent — the asymmetry that causes depopulation

Two ways a real zombie leaves the world, with opposite population outcomes:

1. **Chunk unload** —
   [ZombiePopulationManager.removeChunkFromWorld:348](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L348)
   calls `n_addZombie(...)` for every real zombie **before** removing it: the zombie is
   handed back to the native popman as a virtual zombie. Population preserved.
2. **The cull** — `deleteZombie()` + `removeFromWorld()` + `removeFromSquare()`,
   **no `n_addZombie`**. `IsoZombie.removeFromWorld`
   ([IsoZombie.java:3550](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/characters/IsoZombie.java#L3550))
   routes to `VirtualZombieManager.RemoveZombie`, which for a living zombie just pools
   the object for reuse
   ([VirtualZombieManager.java:652](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/VirtualZombieManager.java#L652)).
   The population ledger is never credited. The zombie is **gone from the map's
   population** — the only counter that notices is the `zombiesCulled` server statistic.

## The kill-zone geometry (why raids trigger it)

Ownership: a zombie is owned by the nearest connection within `relevantRange`
(assigned in
[NetworkZombieManager.updateAuth:60](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombieManager.java#L60),
with 1.618× hysteresis on handoffs and a 2 s churn cooldown). `relevantRange` =
`clamp(clientChunkGridWidth, 12, 20) / 2 + 2`
([GameServer.java:2571](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/network/GameServer.java#L2571))
→ **8** for a default client (grid 13).

Mixed units create a permanent overlap band:

- Ownership acquisition: within `relevantRange × 8` = **64 tiles Chebyshev**
  ([UdpConnection.java:232](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/raknet/UdpConnection.java#L232) —
  B42's 8-tile chunks)
- Ownership retention: inside the client's whole **loaded-area box** (±52 tiles for
  grid 13) or ≤60 tiles Chebyshev
  ([UdpConnection.RelevantTo:254](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/raknet/UdpConnection.java#L254) —
  the connect-area test ignores the radius argument)
- Deletion eligibility: >`(8−2) × 10` = **60 tiles Euclidean** — the optimiser still
  multiplies by B41's 10-tile chunk size

Result: a zombie 45 tiles north and 45 east of the raider is Chebyshev-45 (owned, inside
the loaded box, streamed to the client) but Euclidean-63.6 (**deletable**). The four
diagonal corners of every player's loaded area — roughly 9% of it — are a standing
erasure zone that activates whenever that player's owned count exceeds the cap, and it
**sweeps across the map as the player moves**.

At the correctional facility or Louisville mall, a lone raider's owned count blows past
300 immediately. Every outdoor zombie in the corner zones, every kited horde that loses
aggro (target becomes null → protection gone), every wanderer past 60 tiles: erased at
~10%/frame, permanently. This is exactly the "raid the POI, the surroundings go quiet"
signature.

## The multiplayer blind spot

`canBeDeletedUnnoticed` checks distance **only against the owning connection's
players**. A zombie still owned by raider A (handoff hysteresis, the 2 s cooldown, or
A dying/teleporting) that is standing next to player B is "unnoticed" by A's check —
and B watches it vanish (clients are sent an explicit `ZombieDeleteOnClient` packet,
[NetworkZombiePacker.java:198](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombiePacker.java#L198)).

## How one raid drains the rest of the map

Verified: every cull is a permanent population debit at the raid site (no virtual
handback, unlike death — which at least leaves a corpse and feeds respawn logic).

Native-side (inferred — the popman core is C++, not in the decompile): the virtual
population periodically **redistributes** (`RedistributeHours`, passed to native at
[ZombiePopulationManager.java:308](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L308)).
Redistribution refills the emptied POI by draining neighboring cells, which drain
their neighbors. With respawn slow or disabled (typical MP settings), each raid's
deletions propagate outward as a map-wide population deficit. That is the mechanism
behind "one player raids the mall, the rest of the map depopulates."

## Levers

| Setting | Effect |
|---|---|
| `ZombieConfig.ZombiesCountBeforeDelete = 0` | Disables the cull completely. Population integrity restored; cost is server CPU/bandwidth when someone kites a mega-horde (the original "zombie explosion" this mechanic was built to stop). |
| `= 5000` (max) | Cull only fires on truly extreme hordes; corner-zone erasure becomes rare. |
| Default (300) | Every serious POI raid permanently erases outdoor population. |

Notes for RFTD tooling:

- No Lua event fires on a cull — Guardian/RDMeter cannot observe it directly, only by
  polling zombie counts. The only engine-side trace is the `zombiesCulled` statistic.
- Indoor/roofed zombies are immune, so interior-heavy POIs (the mall proper) keep
  their population; it's the streets, parking lots, and yards that drain.
- The cull deletes silently and cleanly on clients — no corpse, no sound, no loot.
  Player reports of "zombies popping out of existence" at range are this mechanic,
  not lag.

## Addendum — is the lever a packet valve? (and the Reaper interplay)

**No.** `ZombiesCountBeforeDelete = 0` stops the cull loop; the only packets that stops
are the `ZombieDeleteOnClient` bursts announcing cull deletions. Total zombie traffic
goes **up**, not down, with the cull off: the mechanic's network savings came entirely
from shrinking the number of living zombies being synced. The sync machinery itself is
untouched by the option and scales with the horde — `ZombieList` refreshes
(hash-triggered + overdue timer,
[NetworkZombiePacker.java:140](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombiePacker.java#L140)),
per-zombie update packets uploaded by the owning client (client-authoritative — the
server validates ownership in `parseZombie`
[:87](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombiePacker.java#L87))
and relayed to other relevant clients, drained at up to 300 per packet
([:179](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombiePacker.java#L179)).

`ZombieDeleteOnClient` also stays in service from three paths the lever does not touch:
the admin `RemoveZombiesCommand`, disconnect cleanup
([NetworkZombieManager.java:237](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/NetworkZombieManager.java#L237)),
and native-popman-commanded despawns
([ZombiePopulationManager.java:588](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/popman/ZombiePopulationManager.java#L588)).

**Reaper and the cull are orthogonal.** Reaper (RPCore's `cullZombie`) fingerprints
zombies (tile + outfit + inventory signature) and reaps **duplicates** from the
pool-reseed bloom bug — phantom zombies the population ledger never counted, so its
permanent `removeFromWorld()` is exactly correct. The vanilla cull deletes *real,
ledger-backed* population for performance. Setting the lever to 0 doesn't hand the
cull's job to Reaper; it declines that job (bounding kited-horde cost) entirely. The
remaining exposure is performance, not population: a kited mega-horde stays fully
simulated and synced until it disperses or dies.

One nuance in Reaper's method: Lua `removeFromWorld()` never sends
`ZombieDeleteOnClient` — that packet only leaves via the packer paths above. Clients
that had a Reaper-culled zombie streamed clean it up via the client-side stale-zombie
GC (removes remote zombies unheard-from for >5 s,
[IsoZombie.java:2712](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/characters/IsoZombie.java#L2712))
or the next `ZombieList` hash refresh. A Reaper cull within a client's streamed range
can therefore leave a ~5-second non-interactive ghost on that client's screen — worth
knowing if a near-player twin ever gets reaped.
