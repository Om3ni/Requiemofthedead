# RFTDLimes — what is left to build

Handoff written 2026-08-05. Companion to `docs/limes-design.md`, which holds the
*reasoning*; this file holds the *queue*. Where the two disagree, the design doc wins and
this file is stale.

**State of play:** M0 (store, sync, persistence, import) and M1 (Dirge + suppression
bridges) are shipped and live on Mosaic. M4a (the editor: draft model, save wire, map
overlay, Zone Selector | Details tabs) is built and **green on the gates but never
verified in game**. M2, M3 and the enforcement half of M4 do not exist yet.

---

## 0. Verify M4a in game — do this before building anything else

None of the editor has been driven by a human. Every item below assumes it works.

- [ ] **Join baseline.** A client logging in to a populated store must receive it.
      *This has never been proven.* Every observation so far was either an empty store or
      one filled by an import broadcast, which is a different code path
      (`RDNet.broadcast` vs `RDNet.reply`). If the tree is empty on join with zones on the
      server, start here: `LMSync`'s client half sends `pull` on `OnGameStart`, the server
      replies `baseline`. Both ends are `pcall`-wrapped, so a failure is currently silent —
      instrument before guessing.
- [ ] **Save round trip.** `saveZones` has never been exercised. Draw a rect, Save, watch
      for the delta echo and the `.ini` rewrite. Optimistic concurrency (stale revision
      refused) and the server-only field merge are both untested.
- [ ] **Deck resize** — grip drag, live reflow, the rebuild fallback on release, remembered
      size, and the font step at 1500px / 1900px.
- [ ] **Tree** — spatial nesting only, alphabetical at every level, double-click frames.
- [ ] **Details forms** — Zone basics / Dirge / Weapon suppression render and write.
- [ ] **Containment reparenting** — draw a zone inside another, confirm it adopts; drag it
      out, confirm it detaches; confirm a *template* parent is never overwritten by a drag.

---

## 1. M4b — LMRestrict: make the restriction flags do something

**The vocabulary is registered and nothing enforces it.** LMCore declares the eight `no*`
flags plus `zeds`, and every one carries a help note saying no module reads it. That note
is honest today and becomes a lie the moment anyone assumes otherwise.

- [ ] `server/LMRestrictSv.lua` + `client/LMRestrictCl.lua`, per §7.2's three-tier honesty
      model (server-authoritative / client-gated / post-hoc revert). The per-flag mechanism
      and its tier are already researched in the §7.2 table — build from it, do not
      re-derive.
- [ ] Remove the `NOT_YET` help suffix from each flag as its enforcement lands.
- [ ] `zeds = remove` / `none` (`server/LMZeds.lua`, §7.3) — standing sweep, and it must
      unwind on `Limes.onZoneEvent` disable/delete or a disabled zone keeps clearing
      zombies forever.

## 2. M2 — LMStats: sprinters and zone difficulty

- [ ] `client/LMStats.lua` (§7.4). `minSprinterRisk` / `maxSprinterRisk` are registered and
      unenforced, same as above.
- [ ] **Read §7.4 first.** Per-zombie cognition/hearing/sight is *not reachable from Lua* —
      verified against the decompile. Zone stats ride lore modulation instead, which
      modulates **global sandbox values** and must restore on zone exit. `Limes.onZoneEvent`
      exists precisely so a disable/delete under a standing player unwinds it.
- [ ] `client/LMWidget.lua` — the zone announce HUD. `title`, `subtitle`, `noannounce` and
      `order` are all registered already.

## 3. M3 — LMLoot: both directions

- [ ] `server/LMLoot.lua` (§7.5). `lewtkey` is registered (`side = "both"`, so the editor
      can set it) and unenforced.
- [ ] Deplete *and* enrich — the second is the trick PhunLewt structurally lacks and the
      reason we are not just wrapping it.
- [ ] When the loot **tables** arrive (as opposed to the key), they are the genuine case
      for `side = "server"`: large, server-read, and not something the editor needs.

## 4. Core work the editor is blocked on

- [ ] **`text` kind in DFForm.** `title`, `subtitle`, `zeds` and `lewtkey` are strings;
      DFForm draws bool/int/enum only, so `LMFieldForm` counts them and reports them as
      "not editable here yet". A drawn form needs a real text widget overlaid — this is
      Core work and every form in the family benefits.
- [ ] **`colour` kind in DFForm** — asked for explicitly for the Details panel.
- [ ] Both are already plumbed for: a field spec carries `ui`, `values`, `step`, `unit`,
      `zero`, `group`; `LMFieldForm.kindOf` returns nil for kinds it cannot draw, so adding
      them is additive.

## 5. Known gaps and warts

- [ ] **One backup slot, two destructive operations.** Import and Clear All both snapshot
      to `RFTDLimes.backup.ini`, so the second overwrites the first's undo. This is what
      lost the 76-zone layer on 2026-08-04. The jail has no rename and no delete
      (`docs/engine-lua-file-io-42.20.md`), so more depth means numbered files written
      through `getFileWriter` and a retention rule.
- [ ] **`Medium` vs `Intermediate`** — English synonyms on adjacent rungs of the ladder,
      almost certainly why `Intermediate` was deleted from the live layer once already.
      **Now fixable:** rename rewrites every child's `inherits` in the same operation,
      which is the piece that was missing.
- [ ] **Server-only fields cannot be cleared from the editor.** The save path carries them
      across so a client cannot destroy what it was never sent. Correct, but it means
      clearing one is a `.ini` edit. Revisit if it bites.
- [ ] **Limes is dedicated-server-only.** Every guard is `isServer()` / `not isServer()`,
      and in single-player both `isServer()` and `isClient()` are false — so `LMPersist`
      never loads and the store is empty by construction. Explicitly *not a concern* for the
      current workflow (2026-08-05); revisit only if SP testing is ever wanted.
- [ ] **`LMShadow`** still ships — the PhunZones divergence logger from the parallel-install
      phase. PhunZones is not active on Mosaic ("nothing to diverge from" at every boot).
      Retire it when PhunZones is formally off the mod list.
- [ ] Live-store oddities seen 2026-08-05, admin's call, not bugs in our code:
      `RosewoodCommercial` has a `zlewtkey` typo, and `_default` carries `tier = 2.5`.

## 6. Retirement — the point of all of this

- [ ] PhunZones, PhunSprinters and PhunLewt come off the server's mod list once M2, M3 and
      M4b are enforcing. Legacy-item deprecation per `docs/legacy-items/DEPRECATION.md`.
- [ ] Suite version bump is **lockstep across all mods**, one bump per upload, sized by the
      batch's biggest change.

---

## Conventions that bit us, so they do not again

- **A limit never refuses a gesture.** Longstrider's resize handles stuck silently at a
  cell cap and read as "drag resizing is broken". Limits validate on Save and annotate on
  the map; the drag always moves.
- **Never measure UI in world tiles.** A new rect seeded at 8 tiles was ~2 pixels at region
  zoom — invisible. Seed from the visible extent.
- **The persist grammar is a validation rule.** Sections match `[%w_%-%.]+`, keys match
  `[%w_]+`. A name outside that survives the wire and vanishes on the next boot, silently.
  `LMEdit.nameProblem` refuses it at the keystroke; a test reads `LMIni.lua` as text so the
  duplicated pattern cannot rot.
- **`inherits` is the spatial parent; `tier` is a field.** The tree nests only on parents
  with geometry — a template is not a folder, and nesting on inheritance filed every zone
  under its difficulty.
- **Test fixtures must not borrow real field names.** `lewtkey` and `zeds` were used as
  stand-ins for "server-only" and "unregistered" until LMCore registered them, and four
  assertions went red for reasons unrelated to what they tested.
- **Kahlua is not Lua.** No global `next`. `select`, `math.log`, `string.upper` are all
  present — verified, not assumed. Check the decompile before using anything unusual.

<!-- Suite version is lockstep; see docs/ for the current number. -->
