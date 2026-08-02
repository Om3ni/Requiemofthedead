# Design determination — RFTDLimes, the family's zone system (42.20.0)

*Engine surfaces verified against `PZ_Engine_Decompiled_42.20.0-a2947723ca`, 2026-08-02,
by three dedicated sweeps (loot fill, per-zombie stats, restriction veto points). Every
`file:line` below is that tree. Companions: `engine-mod-networking-42.20.md`,
`engine-lua-file-io-42.20.md`.*

**Short version: Limes replaces the entire Phun stack — PhunZones, PhunSprinters, and
PhunLewt's role — with one RFTD-native zone substrate: server-authoritative store,
join-baseline + delta sync over RDNet, all reads local, zero steady-state wire cost.
The engine verification changed three things we believed: per-zombie
cognition/hearing/sight is NOT reachable from Lua (zone stats ride lore modulation
instead), there is NO Lua veto anywhere in the engine (restrictions are a three-tier
honesty model, not a wall), and Dirge's shipped Boss-sprinter recipe references an
animation variable that does not exist (action item, §10).**

This document supersedes the "reuse zone frameworks, never reinvent them" principle
(cited as DESIGN §6 in `RCPhunZones.lua`'s header). That principle was written when the
alternative was building an editor and a sync layer from nothing. Both now exist in the
family, and "reuse" had degraded to co-maintaining a fork we don't control while paying
its wire costs. The principle's *spirit* survives as §2 below: we take ideas, never code.

---

## 1. Goals and non-goals

**Goals**

- One zone substrate for the whole family. Dirge, Reclamation, Sprint risk, loot
  shaping, restrictions, and future consumers all read the same zones through one API.
- Retire PhunZones2, PhunSprinters 2, and PhunLewt from the server's mod list.
- Wire profile per the networking determination: server-push only, join baseline +
  event-driven deltas, no periodic per-client pulls, no per-player modData churn.
  Client→server traffic (editor saves) is rare, capability-gated, and rides RDNet's
  default-deny dispatcher.
- Admin-editable three ways: in-game map editor (Longstrider-style), in-game form
  panel, and a hand-editable `.ini` on disk.
- Modularity as a first-class order: every feature is a satellite module consuming
  LMCore's API; deleting a feature file disables that feature and nothing else
  (the DFPatch pattern, promoted to architecture).

**Non-goals**

- PvP safety zones (engine `NonPvpZone` already exists; verified it gates PvP damage
  only — `zombie/CombatManager.java:1518-1521` — and vanilla admin tooling manages it).
- Anti-cheat guarantees the engine cannot give. §7's honesty column is the contract:
  where the engine offers no server authority, Limes gates the honest client, logs the
  dishonest one (RDGuardian), and never pretends otherwise.
- PhunZones data-format compatibility. We import their data once (§9); we do not speak
  their format at runtime.

## 2. Provenance covenant — ideas only

We take **concepts**, never lines. The concepts and their sources, named so the debt is
visible:

| Idea | Source | What we take |
|---|---|---|
| Multi-rectangle zones | PhunZones (`points` lists in live data) | The concept. Our storage, resolution, and editor are original. |
| Template inheritance (`inherits`) | PhunZones | The concept of layered zone defaults. Our resolver is original (§5). |
| Per-consumer field registry | PhunZones (`PZ.fields`) | The concept of consumers registering fields. Our registry is typed and load-order-safe (§6). |
| Difficulty tiers as a scalar | More Difficult Zones | The concept of one number driving multiple dials. |
| Zero-steady-state sync | More Difficult Zones (by accident — its zonesData pull loop is the counterexample) | The discipline, done deliberately. |
| Zone-keyed loot | PhunLewt (`lewtkey`) / OZD-Zones | The concept. Mechanism is §7.5's verified injection path, which PhunLewt does not use. |
| Map-overlay editor | Already ours (LSGridOverlay) — but its map-widget setup ritual is flagged as derived from PhunZones' ui_map.lua | **Obligation:** the LSMap/LSGridOverlay hook-and-transform ritual must be re-authored from the decompile before Limes ships an editor. Tracked as LM-EDIT-1. |

No file in RFTDLimes may contain code transcribed from PhunZones, PhunSprinters,
PhunLewt, or More Difficult Zones. Where a mechanism can only be expressed one way
(an engine call sequence), the authority to cite is the decompile, not the mod that
called it first.

## 3. Requirements (locked 2026-08-02)

1. Define and control Dirge per zone (spawn chance, five weights, five spacings —
   the schema already living in production PhunZones data).
2. Per-zone zombie stats: sprinters, cognition, hearing (§7.4 for what "per-zone"
   honestly means for each).
3. The full restriction set: building, destruction, movable pickup/place, scrap,
   safehouse claiming, vehicle dismantle (Reclamation's field), fire, player entry,
   zone announce suppression — "anything PhunZones can restrict."
4. Zombie removal on zone entry (`zeds = remove` / `none` semantics).
5. Per-zone loot **on zombies** (injection).
6. Per-zone container loot **both directions** — deplete below vanilla (PhunLewt's
   only trick) and enrich above it (the trick it structurally lacks).
7. First-class hooks for family mods (field registry + read API + events).
8. One-way import of the live PhunZones dataset (fixtures:
   `docs/dirge-phunzones.md`, ~90 zones with inheritance).
9. Persistence as a human-editable `.ini` (allowlist-verified, §8).
10. Zone term registration into RQSuppress (already shipped on the Dirge side).

## 4. Architecture — module map

Mod id `RFTDLimes`, file prefix `LM`, wire token `RFTDLimes` (= mod id, per
conventions), `require=RFTDCore`. Everything moves through Core: RDNet for the wire,
RDJson for any structured persistence, RDLog for forensics, RDAccess for capability
gates. No `Events.OnClientCommand.Add` of our own, ever — RDNet's single-dispatcher
rule from birth.

```
shared/ LMCore.lua       zone store, inheritance resolver, point lookup, field registry,
                          Limes.getLocation(x,y) — THE public surface
shared/ LMConfig.lua     sandbox reads + defaults (RFTDLimes sandbox page)
server/ LMPersist.lua    .ini read/write, boot load, save-on-edit
server/ LMSync.lua       join baseline + edit deltas over RDNet; the only writer
server/ LMZeds.lua       remove/none standing sweep (§7.3)
server/ LMLoot.lua       OnFillContainer shaping + addItemToSpawnAtDeath injection (§7.5)
server/ LMRestrictSv.lua server-side tier of restrictions (§7.2)
client/ LMRestrictCl.lua client-side gates: context menus, build menu, entry bounce
client/ LMStats.lua      lore modulation by local player's zone; owner-side sprinter calls (§7.4)
client/ LMWidget.lua     zone announce / title HUD (noannounce-aware)
client/ LMEditor*.lua    Dragonfly tab: LSGridOverlay rectangles + form panel
shared/ LMDirge.lua      Dirge override bridge (replaces RQPhunZones' lookup, keeps
                          getEffectiveRules semantics: zone wins when set, blank inherits)
shared/ LMSuppress.lua   registers the "zone" term group into RQSuppress
shared/ LMImport.lua     one-way PhunZones custom-layer importer (§9)
```

Consumer contract: satellites never touch the store. They call `Limes.getLocation`,
register fields (`Limes.fields.register(owner, name, spec)`), and subscribe to
`Events` the family already standardizes through RDEvents. Reclamation's
`phunZoneBlocks` becomes a one-line lookup swap; Dirge's three `getEffectiveRules`
call sites don't change at all.

## 5. Data model

A zone is a named record: multi-rect geometry + named fields + `inherits` chain.

- **Geometry:** list of world-coordinate rectangles. Lookup is linear scan with
  per-zone bounding box first; ~90 zones × few rects is microseconds. If it ever
  isn't, a 256-tile grid index drops in behind the same API. Overlap resolution:
  smallest-area zone wins (the nested-zone intuition both ancestors approximate),
  explicit `priority` field as the tiebreak.
- **Inheritance:** resolved at load into flattened records (cycle-guarded,
  `_default` root), so runtime lookup never walks a chain. Templates (zones with no
  geometry — `Hard`, `Very_Easy`, `StartingZone` in the live data) are first-class.
- **Field registry:** consumers declare `{type, default, clamp, owner}` before boot
  completes; unknown keys in loaded data are preserved verbatim (forward compat)
  but warned on. The registry is what the editor renders — the PhunZones idea, with
  types instead of stringly everything.

## 6. Sync — under the verified constraints

Per `engine-mod-networking-42.20.md`: client→server Lua commands share one
300/sec-per-connection budget and broadcast re-serializes per player, three walks
each. Therefore:

- **Join:** server pushes one baseline to the joining connection only (RDNet.reply).
- **Edit:** editor client sends one capability-gated RDNet command; server validates,
  persists, applies, then broadcasts one delta (changed zones only) to all. Edits are
  human-rate; this is the only broadcast in the design.
- **Runtime:** zero packets. Every consumer read — `getLocation`, Dirge overrides,
  suppression terms, restriction gates — is a local table lookup on both sides.
- **No periodic anything.** The RQReconcile gap-recovery pattern (revision counter,
  client pull on detected gap only) is adopted verbatim as a pattern; zone edits are
  rare enough that a gap is a curiosity, not a correctness problem.

## 7. Feature matrix — verified mechanisms and honest authority

Authority legend: **S** = server-authoritative (engine-verified veto/execution point),
**C** = client-cooperative (honest clients comply; hacked clients logged, not stopped),
**R** = post-hoc revert (server detects and undoes).

### 7.1 Dirge per zone — S
Overlay onto the RQConfig snapshot at the three existing call sites. Server-side
consumers (`svCheckZombie`) read server-local zone data. Nothing new on the wire.

### 7.2 Restrictions

| Flag | Mechanism | Authority |
|---|---|---|
| `nobuilding` | Server executes builds in Lua: `OnProcessAction "build"` fires server-side with player + exact x/y/z *before* object creation (`zombie/core/BuildAction.java:120`); the server-side handler is where the object is made, so Limes wraps it and refuses in-zone. Client UI gate hides the option for honest UX (client saw local accept — the refusal must also send a corrective state, or the ghost object persists until reload; LMRestrictSv owns that send). Packet layer validates nothing spatial (`BuildActionPacket.java:38-60`, PlayerID only — `zombie/core/Action.java:97-102`). | **S** |
| `nodestruction` | No server veto exists: `SledgehammerDestroyPacket` re-checks only the global server option (`:38-51`) and `OnObjectAboutToBeRemoved` (`RemoveItemFromSquarePacket.java:144`) is void — the engine even throws if the handler removes the object itself (`:146-148`). Tier: client context-menu gate (`ISWorldObjectContextMenuLogic.java:412-418` feeds the menu) + RDGuardian forensic on the server event + admin-facing revert tooling later. | **C**+log |
| `nopickup` / `noplacing` / `noscrap` | One transaction funnel, no spatial validation (`TransactionManager.isConsistent`, `zombie/core/TransactionManager.java:115-212`). Server-side `OnProcessTransaction` events (`pickUpMoveable` `Transaction.java:132`, `placeMoveable` `:175`, `scrapMoveable` `:128`) fire with coordinates but are void. Tier: client gate on the moveables UI + server post-hoc revert — the transaction result is server-side state, so LMRestrictSv can undo a forbidden pickup (return item to square) in the same tick window. | **C**+**R** |
| `nosafehouse` | No pre-claim Lua hook (`SafehouseClaimPacket.processServer` → `SafeHouse.canBeSafehouse`, all Java — `SafeHouse.java:352-463`). But `OnSafehousesChanged` fires server-side post-claim (`SafeHouse.java:84`) and `SafeHouse` is Lua-exposed (`LuaManager.java:2049`): LMRestrictSv removes non-compliant claims immediately + notifies the player. Client gate hides the claim option. Note verified quirk: the spawn-region exclusion runs client-side only (`SafeHouse.java:374-403`) — our zone check is server-side, strictly stronger. | **R** (tight) |
| `nofire` | Clients cannot inject `StartFire` (packet is client-processing only — `StartFirePacket.java:23`, unreachable server path per `PacketTypes.java:670`). Campfire ignition flows through the `"campfire"` global-object system's Lua `OnClientCommand` (`SGlobalObjectSystem.java:119-125`) — a genuine pre-mutation server veto Limes wraps. Backstop: `OnNewFire` fires server-side in the IsoFire constructor (`IsoFire.java:251`) → in-zone extinguish via Lua-exposed `IsoFireManager` (`LuaManager.java:2067`). | **S** (campfire) + **R** (spread/other) |
| `noplayers` (entry) | No engine concept of forbidden presence except safehouse trespass, whose bounce (`SafeHouse.checkTrespass` → `GameServer.sendTeleport`, `SafeHouse.java:465-475`) is not generically reachable: `GameServer` is not Lua-exposed, and Lua teleport globals are client-side sends (`LuaManager.java:9770-9779`). Movement is client-authoritative. Tier: client-side self-bounce on zone data (honest clients), server-side periodic trespass detection → RDNet command to the client to relocate + forensic log. Same ceiling PhunZones lived under; ours logs. | **C**+log |
| `noannounce` / titles | Pure client widget (LMWidget) off local zone lookup. | local |
| Vehicle dismantle | Already server-checked in Reclamation (`RCJanitor`/`RCShared`); swaps lookup source. | **S** |

### 7.3 Zombie removal (`zeds = remove` / `none`) — S, standing
Canonical idiom, ordering verified: `NetworkZombiePacker.getInstance():deleteZombie(z)`
**then** `z:removeFromWorld()` + `z:removeFromSquare()` — delete captures `onlineId`
before removal nulls it to -1 (`IsoZombie.java:3569`; reversed order silently loses the
client broadcast). Delete packets are relevance-filtered (`ZombieDeleteOnClientPacket.java:30`).
Population respawn is density-driven (`ZombiePopulationManager.updateRealZombieCount`,
`:449-473`), so removal is a **standing sweep** on the server zombie tick, not a
one-shot — deleted zombies will be replaced on the respawn schedule and swept again.
Budgeted per tick (Reaper's `MaxRemovalsPerScan` discipline).

### 7.4 Zombie stats per zone — the honest split
- **Sprinters — per-zombie, S.** The only Lua-reachable per-zombie stat levers are
  `doSprinter()/doFastShambler()/doShambler()` (`IsoZombie.java:4747/4758/4787`), which
  set both `speedType` and `walkType`. `walkType` is what the ~3.8s zombie packet
  carries (quantized enum, `NetworkVariables.java:103-116`) and every receiver
  re-derives `speedType` from it (`NetworkZombiePacker.java:251-252`,
  `NetworkZombieAI.java:264-265`) — so the override survives the wire **iff set on the
  owning client** (owner state overwrites server state per packet). Application point:
  `OnZombieCreate`, which verifiably fires on server spawn (`VirtualZombieManager.java:325`)
  *and* on the client when a zombie first becomes visible (`NetworkZombieSimulator.java:182`),
  after position is valid and after the stat roll — nothing re-rolls behind it except
  load/reuse/crawl/inactivity transitions (`IsoZombie.java:979/3628/4084/4360`), which the
  standing zone check re-asserts. Zone sprinter risk = roll per zombie against the
  zone's min/max at create + re-assert on the owner. Replaces PhunSprinters.
- **Cognition / hearing (/sight) — zone-ambient, C by construction.** The int fields
  have **no Lua surface**: Kahlua exposes methods, not instance fields
  (`LuaJavaClassExposer.java:314-320`); no setters exist engine-wide; nothing syncs
  them; each machine rolls its own in `DoZombieStats()` (`IsoZombie.java:3163-3205`,
  sight/hearing unconditionally, `:3201-3202`). The implementable mechanism: LMStats
  modulates the **global** lore values via `getSandboxOptions()` (`LuaManager.java:4789`,
  `SandboxOptions.getOptionByName` `:546`) on each machine according to the *local
  player's* current zone; zombies rolling stats thereafter (client-visibility creates,
  loads, reuse, inactivity flips) inherit the zone's values. Zone-approximate, per-machine,
  converges over minutes. The AI consuming these stats runs on the owning client, so
  client-side modulation is in fact the *effective* side. Sandbox-restore on zone exit
  and on game exit, always through one guarded setter in LMStats.

### 7.5 Loot — bidirectional, S
All fill machinery is server/SP-only (`ItemPickerJava.java:576` hard-returns on client).
Hook `OnFillContainer` — 15 trigger sites mapped, signature always
`(roomName, containerType, container)`; **three sites pass an internal
`ItemPickerContainer`, not an `ItemContainer`** (`ItemPickerJava.java:603/1030/1244`;
field decl `:2081`) — the handler leads with the `instanceof ItemContainer` guard that
DFPatch_PhunLewt already proved necessary.

- **Deplete:** remove rolled items by zone factor after fill. Removals during the fill
  event need no sync (fill syncs the final container: `LoadGridsquarePerformanceWorkaround.java:69-73`,
  `RequestItemsForContainerPacket.java:42-54`); anything after explored-time needs
  `sendRemoveItemFromContainer` (`GameServer.java:2250`, Lua `LuaManager.java:9740`).
- **Enrich:** inject from zone-keyed tables in the same event, same free-sync window.
  `AddItem` does not network by itself (verified: zero net calls in `ItemContainer`
  add/remove paths) — post-window additions use `sendAddItemToContainer`
  (`GameServer.java:2220`, Lua `LuaManager.java:9712`).
- **Respawn compounds correctly:** `LootRespawn` re-fires `OnFillContainer` with a
  **null player** (`LootRespawn.java:160`) and delta-syncs (`:175`) — zone shaping
  automatically governs respawn cycles; the handler must tolerate the null.
  `MaxItemsForLootRespawn` (`:155`) interacts with enrichment: an enriched container
  can exceed the threshold and stop respawning — documented admin knob interaction.
- **Zombie loot:** `zombie:addItemToSpawnAtDeath(item)` (`IsoZombie.java:4103-4113`) —
  public, guarded, vanilla's own key-spawning mechanism, consumed by `DoZombieInventory`
  (`:3149-3160`) so injected items ride the corpse's normal fill + sync. Apply at
  `OnZombieDead` (fires after inventory population, before the corpse object —
  `IsoZombie.java:4601-4612`) or at create for pre-seeded loot. The
  `OnFillContainer("Zombie", outfitName, …)` site (`ItemPickerJava.java:622`) covers
  outfit-roll-time shaping.

### 7.6 Suppression — S (shipped)
RQSuppress's `"zone"` term group is live in Dirge; LMSuppress registers
`function(player) return zone.weaponDebuffMult end`. Multiplicative stacking with the
aura term is the locked design.

## 8. Persistence — `RFTDLimes.ini`

Per `engine-lua-file-io-42.20.md`: `ini` is on the 42.20 `getFileWriter` allowlist
(`LuaManager.java:9884`), lowercase mandatory, jailed to `Zomboid/Lua/`. The extension
is a human/tooling signal — exactly the point: admins hand-edit it, editors highlight
it. Format: one `[ZoneName]` section per zone, `key = value` fields, `rects = x1,y1,x2,y2 ; ...`,
`inherits = Name`. Parser is ~40 lines of anchored patterns in LMPersist, writer is
deterministic (sorted sections/keys — RDJson's diffability discipline). Boot order:
defaults ← `.ini` ← editor deltas; every edit rewrites the file atomically
(write temp + rename is unavailable in the jail — truncate-overwrite with a
`writeLog` journal line first, so a crash mid-write is diagnosable). The zone audit
stream (`who edited what`) goes through `writeLog` — the engine's own rotating logs.

## 9. Importer — one-way, once

`LMImport.parsePhunZones(text)` consumes the persisted custom layer
(`{version=2, data={ key = {points={{x1,y1,x2,y2}...}, inherits, difficulty,
dirge*, minSprinterRisk, maxSprinterRisk, flags...} }}`) — fixtures:
`docs/dirge-phunzones.md` (~90 zones) and the live export. Mapping: `points` →
rects verbatim; `inherits` → native inheritance (kept, not flattened);
`difficulty` → `tier`; `dirge*` strings → typed Dirge fields; sprinter risks →
LMStats fields; `no*` flags → restriction fields; `zeds` → §7.3; `lewtkey` →
loot-table key; `title`/`subtitle`/`noannounce`/`order` → widget fields;
`disabled` honored. Unknown keys preserved with a warning. Import runs from an
admin command, writes the `.ini`, and is then done forever — Limes never reads
PhunZones formats at runtime.

## 10. Dirge action items surfaced by verification

1. **`applyBossSprinter` is broken on the dedi** (`RQSvShared.lua:291-299`): it sets
   `setVariable("bSprinter", true)` — an animation variable with **zero occurrences in
   the engine tree** — plus `setWalkType("Run")`, not a valid walkType (`"1".."5"`,
   `"sprint1..5"`, `"slow1..3"`; unknown strings quantize to normal on the wire,
   `NetworkVariables.java:128-134`). And `setVariable` on zombies is a hard no-op on
   a dedicated server anyway (`IsoGameCharacter.java:11325-11326`). Fix: ownership-aware
   `doSprinter()` on the owning client — the exact `svSetZombieHP` command pattern
   Dirge already has. Ship with the next Dirge batch, independent of Limes.
2. `OnZombieUpdate` never fires for indoor zombies on a dedicated server
   (`IsoZombie.java:2723-2726`) — audit Dirge for any reliance on it.
3. Custom-stat zombies can be silently culled by `ZombieCountOptimiser`
   (`ZombieCountOptimiser.java:22-43`) when a connection's send list exceeds
   `ZombiesCountBeforeDeletion` — the live server runs that option at 0 (disabled),
   which is why Dirge specials survive; document the coupling.

## 11. Rollout

1. **M0** — LMCore + LMPersist + LMSync + `Limes.getLocation` + LMImport. Parallel
   install with PhunZones (read-only shadow; log divergence).
2. **M1** — LMDirge + LMSuppress bridges; Dirge reads Limes when present, PhunZones
   otherwise (both bridges are soft-deps; flip is server-side).
3. **M2** — LMStats (sprinters first), LMZeds, LMWidget. PhunSprinters retires.
4. **M3** — LMLoot both directions. PhunLewt retires.
5. **M4** — LMRestrict tiers + LMEditor (after LM-EDIT-1 re-authoring). PhunZones
   retires; legacy-item deprecation per `docs/legacy-items/DEPRECATION.md` practice.

Each milestone is uploadable alone (lockstep version bump per conventions), each
feature file removable alone, and every Lua file passes `tools\check-lua.bat` before
any upload.

## 12. Open questions (deliberately unresolved)

- Whether `noplayers` should also gate via vehicle-exit like safehouses do
  client-side (`BaseVehicle.java:6086`) or accept foot-entry-only enforcement.
- Whether enrichment should mark containers `hasBeenLooted=false` to re-arm respawn,
  or leave vanilla lifecycle untouched (leaning untouched — least surprise).
- Grid index threshold (ship linear scan; measure on the live box first).
- Whether the widget adopts PhunZones' difficulty-stars idiom or the family's own
  visual language (art direction question, not engineering).

-- Copyright Project_Omen
