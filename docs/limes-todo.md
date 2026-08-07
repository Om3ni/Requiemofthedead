# RFTDLimes — what is left to build

Handoff written 2026-08-05, updated the same evening for the 1.1.0 upload. Companion to
`docs/limes-design.md`, which holds the *reasoning*; this file holds the *queue*. Where the
two disagree, the design doc wins and this file is stale.

**State of play** (updated 2026-08-06): M0 (store, sync, persistence, import) and M1
(Dirge + suppression bridges) are shipped and live on Mosaic. M4a (the editor) has now
been driven in game, and the batch of fixes that came out of that is in `b4009c3` along
with the first enforcing restriction field, `zeds` (LMZeds). DFForm grew the `text` and
`choice` kinds, so every registered string field is editable from the panel. **M2, M3 and
the rest of M4b do not exist yet.**

**Released as suite 1.1.0**, staged to the Workshop item `3772176444` on 2026-08-05
(commit `d548d01`). Risk of shipping the unverified editor was raised and accepted: this is
a mod for the RotD server and its subscribers know what they are running. So §0 below is no
longer "verify before shipping" — it is "verify against the build that is live".

---

## 0. Verify M4a in game — do this before building anything else

None of the editor has been driven by a human. Every item below assumes it works.

Before debugging anything, run `tools\check-deploy.bat -Once`. Steam re-validates the
workshop item on launch and silently rewrites both trees with the PUBLISHED build — a
symptom that looks like a code bug is often a tree that quietly stopped being your code.
Now that 1.1.0 is published, the deployed build and the repo should finally agree.

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
- [x] `zeds = remove` / `none` (`server/LMZeds.lua`, §7.3) — built 2026-08-06 and shipped
      in `b4009c3`. Suppress-at-birth on `OnZombieCreate`, sweep on zone added/edited/
      enabled. **Removal is silent**: `die()` runs `becomeCorpse()`, so a walled safe zone
      would slowly fill with bodies for zombies that should never have existed. The census
      replaces the visual proof — it counts from the world, reports `unloaded` rather than
      an unearned zero, and reconciles its own totals. Editable from the panel since the
      `choice` kind landed (§4).

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

- [x] **`text` kind in DFForm** — done 2026-08-06. The typing happens in `DFEntry`, a
      popout, not in a widget inside the form: DFForm rows are drawn chrome inside a
      DFScroll stencil, and child widgets ignore that stencil, so an entry box scrolled
      out of view would keep drawing and stay clickable. One widget exists at a time
      however many text rows a schema has.
- [x] **`choice` kind in DFForm** — done at the same time, and it is what `zeds` actually
      needed. `enum` stores an INDEX, which would have written `2` where LMZeds looks for
      `"remove"` — stored, replicated, displayed, and enforcing nothing. `choice` stores
      the string and cycles a closed set, so "Remove" with a capital R is unreachable
      rather than silently inert. Text is for prose nobody validates; choice is for a set
      somebody does.
- [ ] **`colour` kind in DFForm** — asked for explicitly for the Details panel. Still the
      only kind `LMFieldForm.kindOf` refuses, and `skipped()` still exists to report it.
- [x] The registry now carries `labels`, `rule`, `empty` and `maxLen` alongside `ui`,
      `values`, `step`, `unit`, `zero`, `group`. `test_lmcore` pins the whole carry-through
      because a key `register()` forgets to copy is invisible until a dial loses its
      options in game.

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

## 6. Release mechanics — learned the hard way on the 1.1.0 upload

- **`stage-upload.ps1` mirrors the FILESYSTEM, not git.** A gitignored `RFTDLimes.zip` was
  sitting in `Contents/mods/` and would have shipped inside the Workshop item. Before every
  upload, look at `Contents/mods/` with your eyes — `git status` will not tell you.
- **The version is lockstep**: one number across all 14 mods, 28 `mod.info` files, bumped
  once per upload and sized by the batch's biggest change. There is no per-mod version.
- **`workshop.txt` carries a mod COUNT in prose** ("all fourteen mod IDs arrive together")
  as well as the list. The count went stale when Echoes was pulled and nothing caught it.
  Check both whenever the family gains or loses a member.
- **Publishing is a manual in-game step** — Workshop → Manage Workshop Items → Update.
  Staging is only a local mirror, so it is safe to re-run and re-check.
- Order that works: gates (`check-lua`, `stamp-license.py --check`, `run-tests`) → version
  bump → `stage-upload.ps1 -DryRun` → real mirror → verify the staged tree → publish.

## 7. Retirement — the point of all of this

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
