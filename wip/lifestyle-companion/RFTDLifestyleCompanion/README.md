# Requiem of the Dead: Lifestyle Companion (`RFTDLifestyleCompanion`)

Server-side hardening companion for **Lifestyle: Hobbies** (`LifestyleHobbies`). It
does not add gameplay; it loads *after* Lifestyle and overrides only its networking
and a couple of known bugs, routing everything through **RFTDCore**'s `RDNet`
single-dispatcher permission wall.

Requires `RFTDCore` and `LifestyleHobbies`. Build 42. Dedicated-MP focused; a no-op
hardening-wise in single player (falls back to Lifestyle's original local dispatch).

## Why

Lifestyle registers all ~86 of its `"LS"` client commands on one unguarded
`OnClientCommand` listener with **no** authority, ownership, proximity, rate, or
type checks. Any modded client can forge any command with any args: spawn items,
grant XP/traits, teleport or freeze other players, edit the world anywhere, corrupt
global save data, freeze the server with an unbounded-loop packet, and duplicate
items. (Full findings: see the adversarial review.)

## How it works

The engine fires `OnClientCommand` to every listener unconditionally and discards
return values, so Lua cannot veto delivery of a command — **but** it can lock down
its own token. This Companion:

1. **Shadows** `server/LSservercommands.lua`. Because we load after Lifestyle and PZ
   loads only one file per relative lua path, our file runs and Lifestyle's does not.
   Ours re-registers every command through `RDNet` instead of a raw listener.
2. `RDNet.adopt("LS")` makes the token **default-deny**: only registered commands
   run; anything a cheater invents is rejected and logged (`rdnet` forensic stream).
3. Each command gets a **per-command rate limit** (`RDRate`) and, where relevant, a
   **capability gate** (`RDAccess`) and **proximity / by-id / clamp** checks.
4. The item-dup / item-mint path (`TransferHelper.transferItem`) is corrected in a
   separate global overlay (`server/RDLS_TransferHelperFix.lua`).
5. The NeuralHat reading crash (`Read.lua` scope bug) is fixed by shadowing that file.

Single player / listen host: `RDNet`'s dispatcher only runs under `isServer()`; when
it doesn't, the shadow falls back to Lifestyle's original local dispatch, unhardened
(offline needs no gating), so the mod plays identically. If `RFTDCore` is somehow
absent, it degrades the same way rather than breaking Lifestyle.

## Files

```
42/media/lua/server/LSservercommands.lua      SHADOW: hardened RDNet dispatcher (all commands)
42/media/lua/server/RDLS_TransferHelperFix.lua overlay: anti-dupe / anti-mint transfer
42/media/lua/shared/TimedActions/hooks/Read.lua SHADOW: NeuralHat getDuration crash fix
42/media/lua/shared/RDLSShared.lua             identity + constants
```

## Gating policy (summary)

| Class | Commands | Gate | Body hardening |
|---|---|---|---|
| Admin/global-state | `UpdateAmbt`, `UpdateServerBeauty`, `ImportServerBeauty`, `CompleteTargetAmbt`, `ResetTargetAmbt` | staff (RDNet) + top-admin (body) | sanitized file writes |
| Item grants | `AddItemToPlayer`, `AddItems_Player`, `AddWorldItem`, `CreateArtworkItem` | open | amount cap (64), art beauty/quality clamp, forensic-logged |
| Transfers / item ops | `TransferItem*`, `RemoveItems`, `ModifyItemData`, `AdjustFluidItem`, … | open | resolve real item by id; refuse if absent |
| World edits | `ModifySprite`, `RemoveObject`, `SyncSqrData`, `RemoveDirtTile*`, dirt/disco/juke | open | proximity to caller; `RemoveDirtTileDebug` range clamped ≤8 |
| Self stats | `AddXP` (≤10k/call), `ChangeTrait`, `ChangeMaxWeight` (1–100), moods, `SavePlayerData` (≤300 keys) | open | type-check + clamp; `UpdateOuthouseRangeMap` requires numeric coords (fixes crash) |
| Cross-player | `ChangeAnimVar*` (proximity), dance/social/music relays | open | rate + proximity on impactful/adjacent ones |
| **Unregistered (default-deny)** | `TeleportSittingLocation`, `makeNauseous`, `ModifyItemStat`, `JukeTurnedOn` | rejected + logged | — no legitimate client caller / dead+leaky |

All per-command rates and gates live in the `POLICY` table at the bottom of
`LSservercommands.lua`. Bonus: the port also fixes upstream typo-bugs (`bad`/`bag`,
`movableData`/`movabledata`, `traitName`, `mood`/`upMood`, an implicit global).

## Maintenance — keeping it current

The three shadowed/overlaid files are copies, so they do **not** auto-update when the
author changes Lifestyle. Before publishing a Companion update (or after Lifestyle
updates), run the staleness guard:

```
tools/lifestyle-companion/check-upstream.sh
```

It sha256-compares the current upstream files against the snapshot they were ported
from and tells you which (if any) changed and need a re-port. After re-porting,
refresh the snapshot and bump `RDLSShared.UPSTREAM_MODVERSION` (procedure printed by
the script).

**End goal:** upstream these fixes into Lifestyle itself (the author has been
approached about bundling). Once the dispatcher fix lands upstream, the
`LSservercommands.lua` / `Read.lua` shadows can be retired; the `TransferHelper`
overlay and RDNet routing can remain as the family integration.

## Verification status

- All Lua files parse (luaparser 4.0).
- Command coverage checked against upstream: 82 registered + 4 intentional
  default-deny = all real commands, zero accidental drops.
- Server→client relay arg-mappings verified position-by-position against upstream.
- **Not yet done:** live dedicated-server testing (forge-packet abuse, dupe repro,
  normal-play regression). Do this before shipping.
