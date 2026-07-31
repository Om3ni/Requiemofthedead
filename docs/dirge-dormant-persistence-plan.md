# Dirge - Dormant Special Persistence Plan

**Goal:** Specials survive chunk unload/reload (and full server restarts) instead of
de-specialing in front of players or re-rolling when someone re-enters a cell.

**Context:** Server wipe scheduled in ~2 weeks → we go straight to live testing.
Low risk: Phase 1 is inert data collection, Phase 2 feeds an already-proven code path.

**Status (2026-07-23):** Phase 1 BUILT (RQSvDormant.lua + all RQServer.lua wiring,
adoption NOT enabled - svCheckZombie only runs the log-only probe) plus the §8.1
`zombieKilled` isDead() guard. Phase 0 instrumentation is folded in: per-tick
outfitID stability check (`WARN outfitID changed` line) and `probe WOULD-ADOPT`
drift lines, all behind `RQSvDormant.DEBUG = true`. Dirge 1.0.3. Pending dedi
verification → then Phase 2.

---

## 1. Engine facts (re-verified 2026-07-29 against the **42.20** decompile at `c:\VSCodeProjects\RequiemoftheDead\PZ_Engine_Decompiled_42.20.0-a2947723ca`)

These are the ground truth this design is built on. Do not re-litigate without re-checking the source.

**Re-verification status: all 9 facts HOLD on 42.20.** Nothing below changed behaviourally.
Line numbers drifted and one file moved package, so the citations were rewritten; the
42.19.1 numbers are kept in parentheses because they are what the original design was
argued from. 42.20 refactored zombie *networking* (new `NetworkZombieComponent`), which
looked like a threat to this design - it is not: that component carries network authority
ownership (`authOwner` / `NetworkZombieAI`) and touches neither `modData` nor `onlineId`.

Regenerate the tree with `tools/decompile-engine.ps1` before re-checking any of this.

| Fact | Evidence (42.20) |
|---|---|
| Zombie modData is **wiped** when the object is pooled | `IsoZombie.resetForReuse()` (IsoZombie.java:3585, was 3545) → `getModData().wipe()` (:3672, was 3630); reached via `IsoZombie.removeFromWorld()` → `VirtualZombieManager.RemoveZombie()` (VirtualZombieManager.java:652, was 649-666) → `reuseZombie()` (:88, was 87-100) |
| `onlineId` is reset to -1 on removal and recycled | IsoZombie.java:3567-3569 (was 3527-3529); field declared :325, re-minted from `ServerMap.instance.getUniqueZombieId()` :2780-2781. **Field is `onlineId`, lowercase d** - the casing trap |
| Chunk unload virtualizes zombies keeping **only** pos (float), direction, `persistentOutfitID`, state-flag int, pathTarget | `ZombiePopulationManager.removeChunkFromWorld()` (:348, was 343-392) → `n_addZombie(x, y, z, dir, persistentOutfitID, state, pathTargetX, pathTargetY)` - native decl :133 (was 129), call sites :371/:378/:403. The 8-arg signature is **unchanged**, so the virtualized payload is still exactly this |
| Realize restores the same `persistentOutfitID` | `VirtualZombieManager` reuse path calls `setPersistentOutfitID(outfitID)` (VirtualZombieManager.java:221 and :230; was ~230) |
| `IsoZombie.save()` (which would include modData) is only used for reanimated-player zombies | Zombies are removed from the world before the chunk save job queues - `removeChunkFromWorld(this)` (IsoChunk.java:2936) precedes `requestSaveCell(...)` (:2940), both inside the old 2888-2960 window; `ReanimatedPlayers.java` (now `zombie/ReanimatedPlayers.java`) is still the only live-zombie serialization consumer |
| Dedicated servers don't even virtualize `indoorZombie` room-population zombies - they're discarded and re-minted per `RoomDef.indoorZombies` on cell load | `GameServer.server && ...indoorZombie` skip at ZombiePopulationManager.java:365 (was 361), and also :189, :580, :835; ServerMap.java:868 (was 858-861) → `tryAddIndoorZombies` |
| `global_mod_data.bin` is a **full atomic rewrite** each save (tmp → copy). No tombstones; nil'd keys vanish from disk at next autosave | **File moved: `zombie/GlobalModData.java` → `zombie/world/moddata/GlobalModData.java`.** `save()` :221, writes `global_mod_data.tmp` :259, `Files.copy` → `global_mod_data.bin` :265-266; saved from SP world save (GameWindow.java:1101, was 1108) and server periodic save (ServerMap.java:397, was 393) |
| `addZombiesInOutfit` → `dressInPersistentOutfit(name)` → `PersistentOutfits.pickOutfit(outfitName, female)` | LuaManager.java:8381+ (six overloads, unchanged from 42.19.1), `zombie.dressInPersistentOutfit(outfit)` in the shared body; `PersistentOutfits.pickOutfit(String, boolean)` at zombie/PersistentOutfits.java:162 (was 167) |
| ⚠ `dressInNamedOutfit(String)` does **NOT** set the persistent ID | IsoZombie.java:3876 (was 3835) - body re-read in full on 42.20, it calls `getHumanVisual().dressInNamedOutfit(...)` and never `setPersistentOutfitID` |

**Conclusion:** identity cannot live on the zombie. It must live in global ModData,
world-anchored, and be **re-bound** to fresh zombie objects on realize using the two
things that survive: exact position + `persistentOutfitID`.

---

## 2. Design overview

New server-only global ModData table **`"RQDormant"`** (its own table - NEVER nested in
`RQZombieState`, which is transmitted to every connecting client; `RQDormant` must never
be transmitted or requested).

```
RQDormant = {
    schemaVersion = 1,
    nextPid       = 1,
    records = {
        [pidStr] = {
            zType    = "Screamer",
            x, y, z  = last known position (floats ok),
            outfitID = getPersistentOutfitID() at record time,
            hp       = last known health (clamped ≤ 30, see MAX_NETWORK_HP),
            lastSeen = getTimestampMs(),
        },
    },
}
```

Lifecycle:

1. **Record** at conversion (`svMarkZombie`). Position/hp refreshed each tick alongside
   the existing `svRememberZombie` update.
2. **Demote** when the cleanup loop evicts a *live* special via the stale-ref path
   (`gid == -1` / vanished-without-death). The record stays; the object is gone.
3. **Adopt**: in `svCheckZombie`, before any fresh roll, an unmarked zombie within
   `ADOPT_RADIUS` of a dormant record (with `outfitID` as tiebreaker) gets the record's
   identity written into its modData and falls through to the **existing** `RQConverted`
   recovery branch (RQServer.lua:504-532) - which already re-adopts, applies boss
   sprinter, and backfills `RQJuggMaxHP` / `RQGluttonBaseHealth`. Delete the record.
4. **Delete** on genuine death of an adopted/active special (`onZombieDead` path).
5. **Sweep** on the existing `deathCleanupTimer` cadence: expiry + hard cap.

Client side: **zero changes**. Adopted specials flow through the existing
zombieConverted broadcast / snapshot / delta channels like any conversion.

---

## 3. Touch points

### New file: `Contents/mods/RFTDDirge/42/media/lua/server/RQSvDormant.lua` (~150 lines)

API surface:

```lua
RQSvDormant.record(pid, zType, x, y, z, outfitID, hp)   -- create/update
RQSvDormant.touch(pid, x, y, z, hp)                     -- per-tick position refresh
RQSvDormant.demote(pid)                                 -- mark eligible for adoption (it may just be lastSeen bookkeeping)
RQSvDormant.findMatch(x, y, z, outfitID) -> pidStr, rec -- nearest record within ADOPT_RADIUS, outfit match preferred
RQSvDormant.remove(pid)
RQSvDormant.sweep()                                     -- expiry + cap eviction
RQSvDormant.isEmpty() -> bool                           -- cheap early-out for svCheckZombie
```

Load-time sanitation in `Events.OnInitGlobalModData`:
- `ModData.getOrCreate("RQDormant")`; if `schemaVersion` mismatch or malformed rows
  (non-table, NaN coords via `v ~= v` check), rebuild/clear. This is the self-cleaning
  layer - the .bin shrinks automatically at the next autosave.

### `RQServer.lua` edits (~40 lines total)

1. **`svMarkZombie` (line ~102):** mint pid (`RQDormant.nextPid`), store in a new
   parallel weak table `svPids[zombie] = pid` (do NOT change the value shape of
   `svActiveZombies` - every iteration site stays untouched). Call
   `RQSvDormant.record(...)` with `getPersistentOutfitID()`.

2. **Per-tick loop (line ~1063, next to `svRememberZombie`):** `RQSvDormant.touch(pid, ...)`
   for each live special. hp read is already available in the loop.

3. **Cleanup/eviction block (lines ~1048-1117):** in the stale-ref branch
   (`ok2 and (not gid or gid == -1)` and NOT dead) - this is the virtualization case,
   i.e. the current de-special moment - keep the dormant record (it already has the
   last `touch`ed position). In the dead branch, `RQSvDormant.remove(pid)`.
   ⚠ Use the **cached** position (`svDeathCache` / last touch), never the object's
   current position - per our own pooling doc the ref may already be a recycled,
   different zombie.

4. **`svCheckZombie` (line ~470):** insert BEFORE the `RQConverted` recovery block:

```lua
-- Dormant re-adoption: a realized zombie near a virtualized special's last
-- position inherits its identity instead of being a fresh roll candidate.
if not md["RQConverted"] and not RQSvDormant.isEmpty() then
    local okOid, outfitID = pcall(zombie.getPersistentOutfitID, zombie)
    local pid, rec = RQSvDormant.findMatch(zombie:getX(), zombie:getY(), zombie:getZ(),
                                           okOid and outfitID or nil)
    if pid then
        md["RQType"]      = rec.zType
        md["RQConverted"] = true
        md["RQRolled"]    = true
        RQSvDormant.remove(pid)
        -- restore HP through the owner-client broadcast (svSetZombieHP clamps ≤ 30)
        if rec.hp then RQSvShared.svSetZombieHP(zombie, rec.hp) end
        zombie:transmitModData()
        -- fall through: the RQConverted branch below re-adopts into svActiveZombies,
        -- reapplies boss sprinter, backfills JuggMaxHP / GluttonBaseHealth.
    end
end
```

   Note: `svMarkZombie` must run for adopted zombies too so a NEW pid + record is
   minted (the recovery branch calls `svActiveZombies[zombie] = savedType` directly -
   easiest is to mint the pid inside the recovery branch when `svPids[zombie]` is nil).

5. **`deathCleanupTimer` block (line ~1003):** add `RQSvDormant.sweep()`.

6. **`zombieKilled` handler:** where a server-confirmed special death is processed,
   `RQSvDormant.remove(pid)` (lookup via `svPids[obj]`; if nil - e.g. death of a
   never-tracked special - no-op is fine, sweep catches strays).

### `RQSvShared.lua`

No changes required (`svSetZombieHP`, `svIsAdminPlayer` reused as-is).

---

## 4. Defaults / tuning knobs

| Knob | Default | Rationale |
|---|---|---|
| `ADOPT_RADIUS` | 8 tiles | Stationary zombies realize in place; walkers drift along pathTarget. Tune from Phase 1 drift data. |
| Outfit tiebreak | prefer exact `outfitID` match; fall back to nearest-in-radius | outfitID is not guaranteed unique; position does most of the work. Specials use vanilla models so a near-miss adoption is gameplay-identical and invisible. |
| Expiry | 120 real minutes | ~250 B/record - we can afford generous. |
| Hard cap | 500 records, evict lowest `lastSeen` | Bounds the table even if expiry ever breaks. ~125 KB worst case in `global_mod_data.bin`. |
| Sweep cadence | piggyback `DEATH_CLEANUP_INTERVAL` (~5 min) | Existing timer, zero new plumbing. |

---

## 5. Phases (each independently shippable)

**Phase 0 - 5-minute preflight (do first, in-game):**
- Verify `zombie:getPersistentOutfitID()` is callable from server Lua and returns a
  stable non-zero int across a virtualize/realize cycle (debug print in the tick loop).
  This is the only load-bearing unverified assumption.

**Phase 1 - Inert registry (zero gameplay change):**
- Ship `RQSvDormant.lua` + record/touch/demote/sweep wiring. NO adoption yet.
- Add a temporary debug line on demote and on would-have-matched realize events.
- **Deliverable data:** real dormant counts, position drift between demote and realize,
  outfitID stability. This calibrates `ADOPT_RADIUS` before it can misfire.

**Phase 2 - Adoption:**
- Enable the `svCheckZombie` insert. Specials now survive unload/reload and restarts.

**Phase 3 - Tune & clean:**
- Set radius/expiry from Phase 1 data, remove debug lines, bump `schemaVersion` if the
  record shape changed during testing (sanitation auto-clears stale saves).

---

## 6. Live test checklist (dedicated server)

1. Convert a special (admin convert is fine - it takes the same `svMarkZombie` path),
   note position. Walk 3+ cells away, wait for unload, return → **same type at ~same
   spot, HP restored** (expect adoption log line, no fresh-roll line).
2. Same test with a special that was mid-walk (worst drift case).
3. Same test across a **full server restart** while away → record persists in GMD,
   zombie realizes from zpop → adoption should still hit. This is the headline feature.
4. Kill an adopted special → record deleted (check via adminInspect/debug), no ghost.
5. Let one expire (drop expiry to 5 min temporarily) → record swept, zombie rolls fresh
   as today. Confirm `global_mod_data.bin` shrinks after next autosave.
6. Regression: normal conversion funnel, screamer summons, adminReroll all unchanged.

---

## 7. Known edge cases / accepted trade-offs

- **Walking specials drift** while virtual (popman simulates toward pathTarget). Radius
  handles most; a special that walked out of radius de-specials as today - strictly no
  worse than current behavior.
- **Wrong-zombie adoption** within radius: cosmetically invisible (vanilla models),
  gameplay-identical. Accepted.
- **Per-type volatile state resets on adoption** (screamer cooldowns, glutton eat
  counts): keyed by onlineID which changes. Accepted; can be folded into the record
  later if it matters.
- **Type-specific module state** starts fresh - the existing `RQConverted` recovery
  backfills the load-bearing pieces (JuggMaxHP, GluttonBaseHealth) already.
- **Expiry window**: a special dormant longer than 120 min de-specials. Tunable.

---

## 8. Optional quick wins to batch into the same testing window (separate concerns, small diffs)

From the Blackout Predators comparison review (see chat history 2026-07-23):

1. **`zombieKilled` live-detonation exploit** - the corpse scan (RQServer.lua:934-969)
   never checks `isDead()`; a spoofed report on a *living* EMP special detonates a real
   blast and poisons `svProcessedDeaths`. Fix: require `obj:isDead()` before effects.
   ~3 lines. Do this one regardless.
2. **Rate-limit `zombieKilled` + `eaterArrived`** (currently unlimited; 17×17 scan per
   call / unbounded queue). Token-bucket pattern, ~25 lines.
3. **Periodic baseline resend** (~every 60-120s re-run `svBuildSnapshot` + full
   `ModData.transmit("RQZombieState")`) - heals lost removal deltas (ghost specials).
   Note: the dormant registry makes ID-reuse ghosts slightly more likely to matter, so
   this pairs well with Phase 2.

---

## 9. Upgrade option: per-type persistent outfits (engine-verified 2026-07-23)

The adoption matcher can be made near-deterministic using the engine's own outfit
persistence:

- `addZombiesInOutfit` → `zombie.dressInPersistentOutfit(name)` (LuaManager.java:8381+,
  six overloads sharing one body; was ~8353) → `PersistentOutfits.pickOutfit(outfitName,
  female)` (zombie/PersistentOutfits.java:162, was 167) → sets `persistentOutfitId`.
- That ID is the one rich field `n_addZombie` preserves through virtualization, and
  realize re-dresses from it. `getOutfitName()` is readable from Lua.
- ⚠ `dressInNamedOutfit(String)` does **NOT** set the persistent ID (IsoZombie.java:3876,
  was 3835 - visuals only). Must use `dressInPersistentOutfit`.
- Re-verified on 42.20 (2026-07-29): all three of the above hold unchanged. The overload
  list (`isCrawler`, `isFakeDead`, `isRagdolling`, `onFire`, `health`, `heightOffset`, ...)
  is byte-identical to 42.19.1 - it is NOT new surface, despite looking like it.

Design: register one custom outfit per special type (`RQ_Screamer`, etc. - can be
near-vanilla plus a hidden marker garment: `hidden=true, Weight=0, BodyLocation=ZedDmg`,
see BP's `BP_Volatile` item). Apply at conversion. Adoption then becomes:
unmarked zombie wearing an `RQ_*` outfit → returning special of that type; the dormant
record (position match, generous radius) only restores HP/pid.

Caveats:
- OutfitManager can occasionally assign a registered outfit to a random vanilla zombie
  (BP ships an "impostor repair" loop for exactly this). Mitigation: outfit is a strong
  hint, still require a dormant record within radius; or accept rare false adoptions.
- Converted specials visibly change clothes unless the outfit is designed near-vanilla.
- Adds Phase 0 check: confirm `dressInPersistentOutfit` is exposed to Lua and the outfit
  survives a virtualize/realize round trip with `getOutfitName()` intact.

Recommended sequencing: ship Phases 0-2 with position+outfitID-int matching first (no
content changes needed), then evaluate this upgrade - it's additive, not a rework.

---

*Prepared 2026-07-23 from the BP-vs-Dirge comparison session, against the 42.19.1 decompile
at `C:\VSCodeProjects\PZMod\PZ_Engine_Decompiled`.*

*Engine citations re-verified 2026-07-29 against **42.20.0-a2947723ca** and now refer to
`c:\VSCodeProjects\RequiemoftheDead\PZ_Engine_Decompiled_42.20.0-a2947723ca` (gitignored;
rebuild with `tools/decompile-engine.ps1 -Version <from the debuglog "version=" line>`).
All 9 engine facts in §1 survived the version bump - line numbers only, plus
`GlobalModData` moving to `zombie/world/moddata/`. Citations elsewhere in this document
outside §1 and §9 have NOT been re-checked line-by-line; treat them as 42.19.1.*
