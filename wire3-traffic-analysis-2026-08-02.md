# Wire traffic analysis — wire3.txt (8.96 h live capture, 2026-08-02)

*Source: `C:\Users\micha\Downloads\wire3.txt` — 790 RDWire JSONL events (722 `RD.WIRE_TOP`
30-second windows + 68 `RD.WIRE_OVERSIZED`), span 32,239 s = 8.96 h, a couple of clients
connected. Engine claims verified against `PZ_Engine_Decompiled_42.20.0-a2947723ca`.
Companion to `engine-mod-networking-42.20.md`.*

**Headline: PhunZones is 62.8% of all mod wire traffic. Its global ModData table grew
from 29.6 KB to 239.7 KB during the capture, and the engine re-serializes that entire
table once per connected client on every transmit. RFTD is 6.6% of traffic. Your read
was right.**

## Totals

| Direction | Keys | Calls | Bytes | Rate |
|---|---|---|---|---|
| C2S | 60 | 6,035 | 1,135,452 | 35.2 B/s |
| S2C | 55 | 15,866 | 3,438,645 | 106.7 B/s |
| MDATA (global ModData) | 1 | 40 | 5,841,147 | 181.2 B/s |
| **TOTAL** | | **21,941** | **10,415,244** | **323.1 B/s** |

| Owner | Bytes | Share |
|---|---|---|
| PhunZones (incl. its ModData) | 6,539,193 | **62.8%** |
| All `Phun*` mods | 6,793,400 | 65.2% |
| **RFTD suite (all 13 mods)** | **682,575** | **6.6%** |
| Everything else | 2,939,269 | 28.2% |

Packet rates are nowhere near the `MaxPacketsPerSecond` ceiling (0.68 calls/s aggregate
against 1000/s per type per connection). **This is a payload-size and
serialization-cost problem, not a packet-count problem.** Raising the limiter further
buys nothing.

## The finding: an unbounded global ModData table

`ModData:PhunZones` — 40 transmissions, 5.84 MB, mean 146 KB, peak **239,728 bytes**.

Per-transmission size (`maxSingle`) over the capture, in ~29.7 KB steps:

```
t=74.6 min   29,650      t=86.4  149,330      t=97.9   239,728   <- peak
t=79.4       59,446      t=93.9  178,818      t=109.4  180,162   <- drops (restart?)
t=79.8       89,202      t=94.9  209,104      t=113.0  181,554
t=84.8      119,332      t=96.4  209,685      t=119.5  181,560   <- plateau
```

The step size (~29.7 KB) matches the `PhunZonesPlayerSetup` payload size
(29,678–30,288 bytes across 23 oversized events) almost exactly — something is folding a
full zone dataset into the custom-overrides layer repeatedly rather than replacing it.

The engine is not the culprit: `ModData.add(tag, table)` is a plain replace
(`this.modData.put(tag, table)`,
[GlobalModData.java:107](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/world/moddata/GlobalModData.java#L107)).
The growth is Lua-side, in PhunZones' own `custom` table
(`process.lua:503-513` `saveChanges`, `:540-565` `addDeletion`, `:479` `loadAdminConfig`).

**It persists.** `saveChanges` writes the grown table to disk via
`Core.tools.saveTable(Core.const.modifiedLuaFile, ...)`, and `loadAdminConfig` reads it
back into ModData at boot — which is exactly why the size plateaus at ~181 KB after the
drop rather than resetting to zero. **Check `PhunZones.lua` in the live server's
`Zomboid/Lua/` folder; if it's ~180 KB, that's the on-disk proof.** (Not present on
Mosaic — this capture is from live.)

## Why this is the >10-population wall

`GlobalModData.transmit(tag)` on the server **loops every connection and re-serializes
the whole table for each one**
([GlobalModData.java:126-133](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/world/moddata/GlobalModData.java#L126)),
each pass taking that connection's `bufferLock` around its single 1 MB buffer.

Cost is **O(table size × player count)**, on the main thread, in one burst:

| Players | Per transmit @ 240 KB |
|---|---|
| 2 (this capture) | ~480 KB |
| 10 | ~2.4 MB |
| 20 | ~4.8 MB |

Also note 240 KB is ~24% of the entire 1 MB per-connection buffer in a single write. This
is the mechanism behind "the networking surface is narrow above 10 players" — it isn't
the surface, it's one table being multiplied by the player count.

## Secondary offenders

| Key | Dir | Calls | Bytes | Note |
|---|---|---|---|---|
| `newmusic_device:zombie_visual_targets` | S2C | 4,897 | 790 KB | highest call count in the capture |
| `PhunZones:PhunZonesPlayerSetup` | 30 KB | 56 | 693 KB | duplicates what `ModData.transmit` already sends |
| `newmusic_device:registry_update` | S2C | 515 | 518 KB | 1 KB average |
| `newmusic_device:state` | S2C | 476 | 367 KB | 770 B average |
| `RQDB:ActiveIdentityUpdate` / `IdentityGateUpdate` | S2C | 304 each | 452 KB | ~840 B and ~650 B each |
| `that_damn_lib:playPartAnimation` | S2C | 2,422 | 229 KB | high frequency, small payload |
| `PhunSprinters:isSprinter` | both | 3,901 | 245 KB | 11–12 KB burst outliers |

`newmusic_device` is the clear #2 at 1.76 MB total across 7 keys.

## RFTD's own numbers (for the record)

682,575 bytes total, 6.6%. Largest single contributor is `RFTDDirge:zombieDelta`
(795 calls, 356 KB, max 1,790 B). `RFTDReaper:SnapshotChunk` shows 4 calls / 89.5 KB with
a 28,893 B max — that's the byte-budgeted chunker working as designed (it only ran when
requested). Nothing in the suite is close to the top offenders.

## Recommended actions

1. **PhunZones is the whole game.** Inspect the live `Zomboid/Lua/PhunZones.lua`; if it's
   ~180 KB, trim/reset the custom layer and the transmit cost drops by ~85% immediately.
   Then report the accumulation upstream — the merge in `saveChanges`/`addDeletion` is
   where a full dataset is getting folded into the overrides layer.
2. **Drop the redundant `PhunZonesPlayerSetup` payload** if the mod can be configured to
   rely on `ModData.transmit` alone — clients currently receive the same table twice.
3. **Never let a global ModData table grow unbounded** — the O(table × players) transmit
   is the sharpest scaling edge in the whole Lua networking surface. Worth a standing rule
   for RFTD too.
4. **`newmusic_device`** deserves a second look at 1.76 MB / 7,030 calls, particularly
   `zombie_visual_targets` at 4,897 sends.
5. **RDMeter fixes — DONE 2026-08-02.** Both instrumentation defects found by this
   analysis are fixed in `RDMeter.lua`:
   - **Direction merging (real bug).** `stats` was keyed by `key` alone, so a command
     travelling both ways collapsed into one row: bytes summed across directions and
     `dir` reported whichever side recorded last. That is exactly why
     `PhunZonesPlayerSetup` read as a 693 KB **C2S** key here while its own oversized
     events — which take `dir` straight from the call — correctly said S2C. Now bucketed
     by `dir .. "|" .. key`, with `key` carried as its own field for the label.
   - **Truncation.** `WireProbeTopN` default raised 12 → 25 (in both `RDMeter.lua` and
     `sandbox-options.txt`); 194 of 722 windows were dropping rows, and one window held
     37 distinct keys. Ceiling stays 50.
   - New `tools/tests/test_rdmeter.lua` (18 assertions) pins both. Verified against a
     pre-fix copy: 8 of the 18 fail, including `S2C est = 30040` — the 40-byte request
     summed into the 30,000-byte response, the live pathology reproduced exactly.

   **Consequence for the numbers above:** the per-direction splits in this report were
   computed by re-aggregating the raw JSONL on `dir|key`, so they are correct. Byte
   totals per *mod* were always direction-agnostic sums and are unaffected. The
   truncation under-count stands — totals here are floors, not ceilings.
