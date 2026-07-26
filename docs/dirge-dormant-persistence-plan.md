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

## 1. Engine facts (verified against decompile at `C:\VSCodeProjects\PZMod\PZ_Engine_Decompiled`)

These are the ground truth this design is built on. Do not re-litigate without re-checking the source.

| Fact | Evidence |
|---|---|
| Zombie modData is **wiped** when the object is pooled | `IsoZombie.resetForReuse()` → `getModData().wipe()` (IsoZombie.java:3545, 3630); reached via `IsoZombie.removeFromWorld()` → `VirtualZombieManager.RemoveZombie()` → `reuseZombie()` (VirtualZombieManager.java:87-100, 649-666) |
| onlineID is reset to -1 on removal and recycled | IsoZombie.java:3527-3529 |
| Chunk unload virtualizes zombies keeping **only** pos (float), direction, `persistentOutfitID`, state-flag int, pathTarget | `ZombiePopulationManager.removeChunkFromWorld()` → `n_addZombie(x, y, z, dir, persistentOutfitID, state, pathTargetX, pathTargetY)` (ZombiePopulationManager.java:343-392, 129) |
| Realize restores the same `persistentOutfitID` | `VirtualZombieManager` reuse path calls `setPersistentOutfitID(outfitID)` (VirtualZombieManager.java:~230) |
| `IsoZombie.save()` (which would include modData) is only used for reanimated-player zombies | Zombies are removed from squares before the chunk save job queues (IsoChunk.java:2888-2960); `ReanimatedPlayers.java` is the only live-zombie serialization consumer |
| Dedicated servers don't even virtualize `indoorZombie` room-population zombies - they're discarded and re-minted per `RoomDef.indoorZombies` on cell load | ZombiePopulationManager.java:361; ServerMap.java:858-861 → `tryAddIndoorZombies` |
| `global_mod_data.bin` is a **full atomic rewrite** each save (tmp → copy). No tombstones; nil'd keys vanish from disk at next autosave | GlobalModData.java:221-267; saved from SP world save (GameWindow.java:1108) and server periodic save (ServerMap.java:393) |

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

- `addZombiesInOutfit` → `zombie.dressInPersistentOutfit(name)` (LuaManager.java:~8353
  impl) → `PersistentOutfits.pickOutfit(outfitName, female)` (PersistentOutfits.java:167)
  → sets `persistentOutfitId`.
- That ID is the one rich field `n_addZombie` preserves through virtualization, and
  realize re-dresses from it. `getOutfitName()` is readable from Lua.
- ⚠ `dressInNamedOutfit(String)` does **NOT** set the persistent ID (IsoZombie.java:3835
  - visuals only). Must use `dressInPersistentOutfit`.

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

*Prepared 2026-07-23 from the BP-vs-Dirge comparison session. Engine citations refer to
`C:\VSCodeProjects\PZMod\PZ_Engine_Decompiled` (B42 decompile).*
