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
| Map-overlay editor | Ours (LSGridOverlay); its map-widget setup ritual was previously flagged as derived from PhunZones' ui_map.lua | **LM-EDIT-1 — RESOLVED 2026-08-04.** Re-authored. The bring-up sequence turned out to be **vanilla's own**, not PhunZones': `ISUI/Maps/ISMiniMap.lua:709-723` walks `getLotDirectories()` → `addData` → `endDirectoryData` → `addImages` → `setBoundsFromWorld`, and `ISMapDefinitions.lua:22-30` repeats it — eight vanilla call sites in total. PhunZones copied The Indie Stone; so did we, now from the source. The zoom-fit search loop, which *was* theirs, is replaced by a direct solve from the published projection (`MapProjection.java:26-28`, `WorldMapRenderer.java:373-377`): `z₂ = z₁ + log₂(needed ÷ have)`, one `setZoom`, exact fractional zoom instead of half-step rounding. `hookNow` is restructured around a `takeOver` helper with the forwarding rule stated per hook. No `LS-DERIVED` markers remain in the tree. |

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
- **Field registry:** consumers declare `{type, default, clamp, owner, side}` before boot
  completes; unknown keys in loaded data are preserved verbatim (forward compat)
  but warned on. The registry is what the editor renders — the PhunZones idea, with
  types instead of stringly everything.
- **Field `side` — `"server" | "client" | "both"` (default `"both"`).** Declares where a
  field is *consumed*, not where it lives. Loot tables and dirge weights are read only by
  server code (§7.5, §7.1); titles and the cognition/hearing modulation are read only by
  client code (§7.4). The tag exists so LMSync can **strip server-only fields from the
  baseline and delta** (§6): smaller join payload, and zone loot tables and difficulty
  stop sitting in every client's memory where a curious player can read them — a leak
  PhunZones has and we decline to inherit. Unregistered fields ship (the forward-compat
  path must never silently drop data).
  **This is a field property, never a zone property.** Zone *types* were considered and
  rejected: one physical place — a gun store — wants a client title, server loot shaping,
  and server no-build at once, so typing the zone would force the admin to draw the same
  rectangle twice, double the geometry the lookup scans, and fracture the single-record
  `getLocation` contract the whole zero-wire design rests on.

### 5.1 Zone lifecycle events

`Limes.onChanged(fn)` reports *that* the store moved (revision only). Consumers with
**standing side effects** need to know *which zone* changed and *how*, because their undo
path is a zone exit that will never fire if the zone stops existing underneath the player:

- LMStats modulates **global sandbox values** per the local player's zone and restores on
  exit (§7.4). Disable or delete that zone while a player stands in it and the restore
  never runs — the sandbox stays modulated for the rest of the session. This is the
  motivating leak.
- LMWidget keeps announcing a title for a zone that is gone.
- LMZeds' standing sweep (§7.3) should stop; already-converted sprinters stay converted
  unless a consumer chooses to revert them (`doShambler()` exists; a design call per
  feature, not a store concern).

```
Limes.onZoneEvent(fn)   -- fn(event, name, zone, rev)
                        -- "added" | "edited" | "enabled" | "disabled" | "deleted"
```

**Derived, never transmitted.** The events are computed by diffing inside `rebuild()`,
which both `Limes.apply` and `Limes.applyDelta` already funnel through — so server and
client derive identical events from the same engine-free shared code, and no event ever
touches the wire (§6 rule 1). `zone` is the resolved record for every event except
`deleted`, where it is the last-known record so consumers can unwind by geometry.

Keep the admin's three editor verbs — **On / Disable / Delete** — distinct from these
five observations. The verbs are editor operations that produce a delta (`disabled` field
flip, or a `removed[]` entry); the events are what consumers see afterwards.

**Disable and Delete are genuinely different states and both must be reachable.**
`disabled` is already modelled: registered field, resolved onto the record, and `rebuild`
declines to index a disabled zone while `Limes.getZone` still returns it so the editor can
see it. Delete removes the record outright (`applyDelta` nils it from the raw store).
PhunZones conflated the two — its "delete" only writes `disabled = true` and the dead zone
persists and re-transmits forever — which is precisely how a zone store becomes
append-only (Appendix A).

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
- **Raw, not resolved, on the wire.** The resolver is shared code, so the unflattened form
  ships and both sides expand identically. Smaller payload, and identical resolution is
  provable rather than hoped for.
- **Server-only fields are stripped** from baseline and delta per the `side` tag (§5).

### 6.1 Invariants — the rules the editor must not break

M4 is the first feature that *generates* traffic, and a map editor is the worst possible
shape for it: drag-resize fires at frame rate. These are hard rules, each one bought with
a verified failure in Appendix A.

1. **State replicates; events derive.** Never send "zone X was disabled" as a message.
   Send state; both sides compute transitions in shared code (§5.1). This is why the
   lifecycle hook lives in LMCore and not LMSync.
2. **The editor edits a local working copy and sends one command on explicit Save.**
   Never on drag, never on field-blur, never on a timer. The 300/sec client-command budget
   is shared with every other mod on the server and **fails silently** — no error, just
   missing packets.
3. **No optimistic local apply.** The editing client learns about its own edit from the
   server echo, like every other client. Mutating the store under a drag would fire every
   local consumer at frame rate and show the admin a preview of state nobody else has.
   Marginally less snappy; provably consistent; zero special-case paths in the editor.
4. **One announcement per edit.** `broadcastDelta` is the only path out of a save. There
   is no "and re-baseline to be safe" reflex — that reflex, in one line, is the whole of
   PhunZones' 62.8% wire share (A.3).
5. **Prune on save.** A field cleared in the editor is *removed* from the raw record, never
   written as a sentinel or an empty value. Merge-never-prune is how a store silently
   becomes append-only (A.2).
6. **The replicated store holds zones and nothing else.** No edit history, no undo stack,
   no per-player state, no orphaned records. Editor history and audit trails live
   server-side, unreplicated. Better packets around a ratcheting table only reach the same
   wall more slowly — unbounded growth *through* a good protocol was PhunZones' actual
   killer, not the protocol alone.
7. **Optimistic concurrency on save.** The editor sends the revision it was editing
   against; the server rejects a stale save with a notice rather than applying it. Server
   Lua is single-threaded so revisions cannot interleave, but two admins in the tab at
   once is otherwise a silent lost update.
8. **Rate-gate the save command** at the RDNet registration, as the import routes already
   are (`rate = 1`).

Compliance is measurable: RDMeter/RDWire is the instrument that caught PhunZones, and a
violation of (2), (4), or (6) shows up as payload growth in a capture. Caveat for anyone
re-reading captures taken before 2026-08-02: those under-report the tail and mislabel any
key travelling both directions — re-aggregate raw JSONL on `dir|key` first.

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

### 8.1 Shipped seed — templates yes, geography no

Limes ships a small **template library** (geometry-less zones) plus an explicit
`_default` root, seeded **only when the store is empty** — first boot, no `.ini`, no
import candidate.

- **Why templates:** they are already first-class in the model, and the live PhunZones
  data proves the idiom (`Hard`, `Very_Easy`, `StartingZone` carry no geometry). Shipping
  them gives the editor something to inherit from on day one, turns `_default` into a
  documented answer to "how does an unzoned tile behave" instead of an implicit root, and
  demonstrates the inheritance contract rather than describing it. A template with no
  rects cannot affect anyone who does not reference it, so the risk is nil.
- **The ladder is the family's existing six rungs** — `_default`, `Very_Easy`, `Easy`,
  `Medium`, `Intermediate`, `Hard`, `Very_Hard` — *corrected 2026-08-04*. The first cut
  shipped a namespaced `Tier_Calm/Normal/Harsh/Lethal` set on a 0-10 scale to avoid
  colliding with imported PhunZones names. That collision cannot happen (the seed only
  lands in an empty store; an import replaces the store wholesale), and the prefix bought
  a worse problem: a fresh install and a migrated install would speak different
  vocabularies for the same concept. Measured against the live layer, **all six rungs are
  in real use** — 0:4 zones, 1:3, 2:6, 3:4, 4:7, 5:4 — so collapsing the ladder would
  discard distinctions the admin already made. `tier` stays registered 0-10; the ladder
  occupies 0-5 and the headroom is free, whereas narrowing a registered range silently
  eats stored values.
- **Known wart:** `Medium` (2) and `Intermediate` (3) are English synonyms on adjacent
  rungs — very likely why `Intermediate` was deleted from the live layer, orphaning five
  zones. Renaming means rewriting every child's `inherits`, so it waits for the M4 editor,
  which can rename and rewrite atomically.
- **Why not geography:** it would be deleted by the first thing we tell an admin to do.
  `finishImport` calls `Limes.apply(res.zones)`, which *replaces* the store wholesale — so
  any shipped rectangles vanish on import. Baked coordinates also assume a map set.
- **Seed only when empty, never merge on boot.** A merge would resurrect templates an
  admin deliberately deleted — the tombstone trap from the other direction.

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
   install with PhunZones (read-only shadow; log divergence). **Built 2026-08-02**
   (LMCore, LMImport, LMSync, LMPersist, LMShadow, LMImportTab + three suites, green);
   deviations from this document recorded in §11.2.
2. **M1** — LMDirge + LMSuppress bridges; Dirge reads Limes when present, PhunZones
   otherwise (both bridges are soft-deps; flip is server-side). **Built 2026-08-04**
   (`shared/LMDirge.lua`, `client/LMSuppress.lua`, suite `test_lmdirge.lua`, 29 assertions).
   Three decisions worth carrying forward:
   - **The bridge lives in Limes, not in Dirge.** `RQPhunZones.getEffectiveRules` is taken
     over from this side, so RQServer's three call sites (`:319`, `:609`, `:637`) are
     untouched and deleting `LMDirge.lua` restores the previous behaviour with no other
     edit.
   - **An empty store does not take over.** Authority is conditional on Limes actually
     having zones, so a server that installs Limes before importing keeps the per-zone
     rules PhunZones was still supplying instead of silently losing them. Cached off
     `Limes.onChanged` — this sits on the zombie spawn path.
   - **Installation is deferred and idempotent.** Mod load order decides whether Dirge
     parsed first, and the server's `Mods=` line is not ours to depend on; both bridges
     install immediately if their host is present and retry on boot otherwise.
   The registry now does the coercion and clamping that `getEffectiveRules` used to do per
   lookup — PhunZones persisted these as strings, and registering them as typed numbers is
   what turns `"15"` into `15` once at resolve time. The spawn path deliberately carries no
   clamp of its own.
3. **M2** — LMStats (sprinters first), LMZeds, LMWidget. PhunSprinters retires.
4. **M3** — LMLoot both directions. PhunLewt retires.
5. **M4** — LMRestrict tiers + LMEditor (after LM-EDIT-1 re-authoring). PhunZones
   retires; legacy-item deprecation per `docs/legacy-items/DEPRECATION.md` practice.

Each milestone is uploadable alone (lockstep version bump per conventions), each
feature file removable alone, and every Lua file passes `tools\check-lua.bat` before
any upload.

### 11.1 M4 editor — embedded map, not the vanilla map screen

**Decided 2026-08-04: the editor draws on an embedded map widget inside the Dragonfly
Zones tab**, not on the vanilla M-key world map.

- **The pattern is already built and shipping.** `LSMap` wraps `ISMiniMapInner` in an
  `ISPanel` and owns the one-time bring-up ritual; `LSGridOverlay` is already a rectangle
  editor — world↔screen transforms, draw-all-with-only-selected-showing-handles, corner
  resize, shift-drag body move, hit testing, cell lattice, a max-cells refusal, and a
  `locked` mode that keeps pan/zoom alive while edits are off. Swap "tour" for "zone" and
  that is the whole interaction model, already debugged against a real map widget.
- **No vanilla surface to contend for.** The M-key screen is shared ground with every
  player and every other UI mod. Dragonfly is admin-gated, ours, and the Zones tab is
  already where the importer lives.
- **The editor is more than a map.** Zone editing is map + zone list + the typed field
  form rendered from `Limes.fields.list()` + save. In Dragonfly that is a split pane in an
  existing tab; on the vanilla map it is a floating window over a fullscreen map.
- **Cost accepted:** less screen area than a fullscreen map, against a live layer of ~75
  zones. Mitigation is an expand/maximise mode on the map pane, designed in from the
  start rather than retrofitted.
- **Build it as `LMMapEditor(host)`**, the way `LSGridOverlay:new(lsmap)` already takes its
  host, so the choice of frame — tab pane now, fullscreen window later — stays a
  parenting decision rather than a rewrite.
- **Not a network consideration.** Map bring-up is pure local cost — `getLotDirectories()`,
  `fileExists`, `api:addData` / `api:addImages` against local `media/maps/*`, zero packets
  — and it is already solved by caching the widget per player index and re-parenting it
  across tab rebuilds. Restart-to-apply was considered and rejected: it would buy only the
  §5.1 transition handlers (~30 lines) and would cost a server restart per zone tweak on a
  live dedi. `Limes.apply` already rebuilds live, and every consumer read is a local
  lookup, so live application is free for all but the three standing-effect features.
  The real safety requirement — never apply half-drawn state — is §6.1 rules 2 and 3.
  If large batch edits later warrant it, the answer is a staged Save/Publish split, not a
  restart.
- **LM-EDIT-1 still gates this.** The `LSMap`/`LSGridOverlay` hook-and-transform ritual is
  PhunZones-derived (§2) and must be re-authored from the decompile before Limes ships an
  editor. The embedded route does not increase that debt materially: the bring-up ritual
  is the most-cribbed part, but the transform and hook mechanics are flagged as derived
  too, so the vanilla-map route would owe the same re-authoring minus one function.

### 11.2 M0 deviations from this document

Recorded 2026-08-02 at build time; the doc above is amended, these are the *changes*.

- **LMSync lives in `shared/`, not `server/`** (§4's map said server). It follows RDNet's
  one-file-owns-the-channel precedent, both halves behind `isServer()` branches, so "LMSync
  is the only writer on the wire" is true by construction on both sides and deleting the
  file severs the channel whole rather than leaving a half-registered client. Nothing else
  about the §6 contract moved. The file header documents it.
- **The primary import route is the Dragonfly "Zones" tab** (`client/LMImportTab.lua`, tab
  id `limes`), not a file probe: the admin pastes the export text, previews locally with
  the shared parser, and an RDNet `pasteImport` command ships the text for the
  server to re-parse authoritatively (the preview is UX, never trust). File-probe boot and
  the `import`-by-filename command remain as fallbacks. The M4 editor lands in this same
  tab.
- **CORRECTION, 2026-08-04 — the paste route has a 32767-byte engine ceiling and the
  live layer does not fit.** `ByteBufferReader.getUTF` reads a string's length as a
  **signed short** (`short length = this.bb.getShort()` then `new byte[length]`,
  `ByteBufferReader.java:52`), so a 38453-byte payload wraps to -27083 and the server
  throws `NegativeArraySizeException` inside `GameServer.receiveClientCommand` — *before*
  any Lua handler runs, so no reply is possible and the admin's status line hangs on
  "waiting for the verdict" forever. Observed on Mosaic, twice, with that exact value.
  The original "~40KB against the 1MB connection buffer" reasoning was wrong: the
  connection buffer is not the binding constraint, the per-string length prefix is, and it
  is 16× smaller. **Fixed by chunking** (`pasteChunk`, shipped 2026-08-04): the client
  splits at 24000 bytes, the server reassembles **by index** — never by arrival order — and
  runs one authoritative parse on the joined text. Assembly is per username, discarded on a
  fresh `seq 1` or on disconnect, and bounded by `MAX_ASSEMBLY` (512KB) and `MAX_CHUNKS`
  (64, which also bounds the completeness scan against a hostile `total`).
  One subtlety worth keeping: the chunk command is registered at **rate 30, not 1**.
  `RDRate` buckets are keyed by *username alone* and shared across every RDNet command,
  compared against whichever command's max is being checked (`RDRate.lua:38-52`) — at rate
  1 the second chunk is rejected and the payload silently loses its tail. The filename
  route and hand-editing `RFTDLimes.ini` remain equally valid ways in.
- **`phunzones.txt` is the real persisted filename** on the 42.20 dedi — the `.txt`
  allowlist forces it. Grabbed off the production box 2026-08-02 along with
  `phunlewt.txt`. Note PhunZones' own constant is `PhunZones.txt` (capitalised);
  `LMPersist.IMPORT_CANDIDATES` probes both casings because the allowlist is
  case-sensitive and the dedi is Linux.
- **The live custom layer is 75 zones and dirty**: three inherit targets exist nowhere in
  it (Intermediate ×12 chains, ProtectedCountryAreas ×3, Greenport ×1) — either PhunZones
  base-layer templates or genuinely dangling after an editor delete. Limes cuts the chain
  and warns; the shadow watch shows whether live answers differ. `docs/dirge-phunzones.md`
  (107 zones) is a **stale** snapshot — 49 zones changed, 7 live-only RP-reservation zones
  — keep it as a frozen test fixture; live is authority. `void` in the production data is
  a zone *name* (a template), not a stray key.
- **`phunlewt.txt`**: 6 loot tables, of which live zones reference 3 (Gun Stores ×19,
  Gun's Unlimited ×3, No Pillows/Ammos ×1); no dangling lewtkeys. An M3 ingredient.
- **No sandbox page in M0** — LMConfig deferred; nothing to configure yet.
- **Zone record shape:** consumers read `zone.fields.X`, not fields flattened onto the
  record; `Limes.fields.get(zone, name)` applies the registry default. Resolved fields
  hold only SET values — the blank-inherits contract.
- **Shadow** uses forensic stream `limes` with events `LM.SHADOW_DIVERGE` / `LM.IMPORT` /
  `LM.SAVE`. `RDLog.forensic` does not gate event names (only `chronicle` does), so no
  Core edits were needed.

## 12. Open questions (deliberately unresolved)

- Whether `noplayers` should also gate via vehicle-exit like safehouses do
  client-side (`BaseVehicle.java:6086`) or accept foot-entry-only enforcement.
- Whether enrichment should mark containers `hasBeenLooted=false` to re-arm respawn,
  or leave vanilla lifecycle untouched (leaning untouched — least surprise).
- Grid index threshold (ship linear scan; measure on the live box first).
- Whether the widget adopts PhunZones' difficulty-stars idiom or the family's own
  visual language (art direction question, not engineering).

## Appendix A — PhunZones2 wire pathology, read from source

*Read 2026-08-04 from the installed Workshop copy (item `3676252660`) for **lessons
only**, under the §2 covenant: no line of it enters RFTDLimes. Engine claims verified
against the decompile; traffic numbers from the 9h live RDWire capture (`wire3`), on which
PhunZones was **62.8% of all mod wire bytes** — 6.54 MB of 10.42 MB, against the whole
RFTD suite's 6.6%.*

**The choice, charitably.** PhunZones needs what Limes needs: zone data resident on every
client so a widget title is not a round trip. It reached for `GlobalModData`, the engine's
own shared-table primitive. That is the sanctioned path — mutate the table, call
`transmit()`, every client has it; join is handled for you. No protocol to design, no
versioning, no delta logic, no gap recovery. It is the path of least resistance and the
one the engine's API surface points at.

**A.1 — `transmit()` has no delta mode.** The server branch loops every connection and
calls `packet.write(bbw)` **inside the loop** (`GlobalModData.java:126-142`) — the entire
tagged table, re-serialized per connection, on the main thread, each under that
connection's bufferLock and 1 MB buffer. Any mutation costs `table × players`. 240 KB × 2
clients was 480 KB per burst in the capture; at 20 players it is 4.8 MB in one burst, which
is the >10-population wall.

**A.2 — Delete is a tombstone, so the store only grows.** `Core.addDeletion(key)`
(`process.lua`) does not remove the zone: it writes `custom[key].disabled = true`, persists
that to disk, and the dead record re-transmits forever. There is no true delete in the mod.
Deleting a zone makes the payload permanently *larger*. `Core.saveChanges` compounds it —
`custom[key][field] = val` merges fields in and never clears one — so the custom layer is
append-only by construction. **Limes' answers: §5.1 (Disable and Delete are distinct
states, Delete nils the record) and §6.1 rule 5 (prune on save).**

**A.3 — The double send, and the clearest lesson in the whole appendix.** On one
`modifyZone` command, `Core.saveChanges` (server branch) **already broadcasts a correct
delta** — `sendServerCommand(zoneUpdated, {changes = changes})` at `process.lua:527`. Then
`server_commands.lua:36` *additionally* calls `ModData.transmit(...)`, blasting the whole
table at every connection. `deleteZone` does the same at `:45`. They wrote the cheap path,
it works, and then paid the expensive one on top of it. The 62.8% is a redundant line.
**Limes' answer: §6.1 rule 4 — `broadcastDelta` is the only path out of a save.**

**A.4 — Join ships the layer twice.** `playerSetup` replies with
`data = ModData.get(modifiedModData)` — the entire custom layer (`server_commands.lua:19-21`)
— and the same client also receives it via `OnReceiveGlobalModData`
(`client_events.lua:280-288`). Two full copies per join. **Limes' answer: one unicast
`RDNet.reply` baseline, server-only fields stripped (§6).**

**A.5 — Two owners for one structure.** The editor writes geometry straight into the
client's ModData copy before any server round trip (`ui_zones.lua:2003-2007`), and a client
can `ModData.transmit` upward (`ui_editor.lua:251`). Their own code carries the scar:
`client_commands.lua:22-24` warns that `ModData.add` with an empty table "can wipe the
client's zone data" and guards against it — a workaround for an architectural problem.
**Limes' answer: §6.1 rule 3, no optimistic local apply.**

**A.6 — Gated, then trusted.** `modifyZone` checks `CanSetupNonPVPZone`
(`server_commands.lua:28`) and then feeds client-supplied `data.changes` into `saveChanges`
unvalidated. **Limes' answer: capability gate *and* authoritative server-side re-parse —
already the shape of `finishImport`.**

**Credit where it is due.** Their editor batches correctly: pending edits accumulate in
`_pendingChanges` and only changed keys are sent (`ui_zones.lua:1988-2021`). That is the
right shape, and §6.1 rule 2 arrived at it independently. The save path is not the problem;
the `transmit` layered on top of it is.

**Not a packet-count problem — the trap for anyone tuning this.** Aggregate was 0.68
calls/sec against a `MaxPacketsPerSecond` already at 1000. Rate limiting, the instinctive
fix, buys nothing. It is payload size × serialization × connections.

**What was not confirmed.** The producer of the ~29.7 KB growth steps in the capture
(29.6 KB → 239.7 KB over 9h, persisting to disk and reloading at ~181 KB after restart).
The editor sends genuine deltas and `Core.updateModData` writes to the *player's* moddata
rather than the global table, so neither is the source. A.2 explains why the table never
shrinks, not what wrote 29.7 KB at a time. Left open rather than guessed.

-- Copyright Project_Omen
