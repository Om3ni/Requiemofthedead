# Requiem of the Dead — working rules

Monorepo for the RFTD Project Zomboid **B42 / 42.20** server-mod family.
Twelve mod ids, one Workshop item, shipped atomically.

`README.md` owns release conventions (lockstep versioning, layout, wire tokens,
sandbox-namespace rule, spelling). **This file owns the rules that are expensive
to learn twice.** Read it before touching Lua.

---

## 1. Never guess an engine API

The full 42.20.2 decompile is in the repo root
(`PZ_Engine_Decompiled_42.20.2-ffe7a8a4b1/`, gitignored). **Open the Java body
and read it.** A grep hit on a symbol is not a reading of the method.

- `tools\check-lua.bat` is **syntax only** — a call to a method that does not
  exist parses clean and throws in game.
- Vanilla Lua (`D:\Steam\steamapps\common\ProjectZomboid\media\lua\`) is not in
  the decompile and cannot be verified against it. Treat it as unverifiable.
- Cite what you read as `Class.java:line` in the comment you leave behind.

That habit is why `setLx`/`setLy` were caught (they do not exist in 42.20.2) and
why `getName()` is barred from the pcall safe-list.

## 2. pcall policy

**No guard without a failure mode you read in the decompile.** The suite once
carried 1,299 guards, two thirds of them wrapping field returns.

Run `python tools\check-pcall.py` before upload. Two rules, both enforced:
1. A guard whose every engine call is in `tools/pcall-safe.json` fails the build.
2. Per-mod counts ratchet down only. Raising a baseline is deliberate — document
   the guard's reason in the code, then `--update`.

Adding to `pcall-safe.json` is a decompile job. The file's own header explains
the shared-name rule; obey it.

**A guard earns its place by GRANULARITY, not protection.** Verified 2026-08-15:

- `Event.java:53-63` — every event listener already runs through
  `protectedCallVoid` inside a per-listener `try/catch`. A throw in your handler
  **cannot** reach another mod's listener. "Must not take the event down with
  it" is not a reason; it was wrong in three files and cost 16 guards.
- `UIManager.render()` does the same per UI element.
- `KahluaThread.java:865` and `:1100` log at **throw time**, before any Lua
  pcall sees the error. A guard never buys silence — it only hides the value.

So: does this let one bad row fail without costing the whole pass? Keep it.
Does it only stop an error escaping a callback? The engine already did that.

### The decision procedure

`pcall` means **this verified operation may legitimately fail, and this exact caller can
recover usefully**. It never means "this call looks engine-y" or "the test mock might not
implement it."

Before using one, in order:

1. Read the current Java or vanilla Lua body and identify the throw path.
2. Establish ordinary preconditions directly: nil-check nullable owners/scripts/squares,
   validate wire data, run on the correct side, and fix `require` order.
3. Prefer a deterministic seam: resolve authoritative state first, normalize the input,
   or split a batch into independent operations.
4. If a real failure remains, protect only that operation and define the recovery. Good
   boundaries are foreign callbacks, one row of an independent batch, optional
   integrations, and secondary file/network sinks whose failure must not undo the primary
   authoritative action.
5. Inspect `ok`/error, use a real fallback or bounded diagnostic, and leave unrelated work
   outside the guard.

If a required value becomes `0`, `nil`, or an empty table only because a guard swallowed a
programming error, remove the guard and fix the contract. Likewise, fixtures must implement
the verified engine surface they stand in for. Do not make a fake method throw merely to
force production to carry a `pcall` the engine cannot justify.

## 3. Kahlua is a SUBSET of Lua 5.1

`tools\run-tests.bat` runs **real** Lua 5.1 and therefore **cannot catch these**:

- No `next()`. `next(t) == nil` passes tests, throws in game.
- No Java collection views — `Item:getTags()` returns a Set that cannot be
  iterated; resolve the tag and use `hasTag`.
- More than ~200 locals in one function kills the whole file silently.
- Check `BaseLib`'s registered globals before using any stdlib global.
  `pairs`/`ipairs` are fine (registered elsewhere).

## 4. Client/server load order is asymmetric

The **dedicated server** resolves `require=` into mod order (Core first).
The **client** walks each Lua tier alphabetically **across all mods**, so
`MMSvShared.lua` runs before Core's `RDShared.lua`.

- Any file touching an `RD*` global at file scope must `require "RDShared"`
  (cross-mod `require` works; the walk skips already-required files).
- The client also loads `media/lua/server`, where Core's files return early on
  `if not isServer()`. Guard on **context** (`isServer()`), never on existence.

## 5. Where code lives

- **Two or more consumers → `RFTDCore/42/media/lua/shared/`.** Everything
  hard-requires Core, so this adds no new dependency.
- **One consumer → stays in that mod**, written dependency-free so promotion to
  Core is a file move.
- Placement is about **disableability and ownership**, never deployment reach —
  packaging is mono-item, so every mod id reaches every player regardless.
- Leaf features do not belong in Core: anything there can never be switched off.
- New player-facing capability → its own mod at the grain of Reclaimation
  (vehicles) or Husbandry (animals). Small self-contained modules →
  `RFTDOddsAndEnds`, the catch-all.
- Admin surfaces live in Dragonfly, and Dragonfly is never depended upon in
  return — consumers degrade without it, not the reverse.

**Do not duplicate a helper across files.** If you are about to write a second
copy, it has two consumers: promote it. `tools\check-helpers.bat` enforces
this, and ignores the name when comparing, so renaming a copy does not hide it.

## 6. Traits are registry ids

`getName()` strips the namespace, so a mod trait shadows a vanilla one.
`tostring(trait)` is the unique id. Script definitions take the namespaced form
(`character_trait_definition YourMod:YourTrait`). Mods cannot register into
`base:`.

## 7. Gates, before any upload

```
tools\check-lua.bat          syntax; silence = clean
tools\check-pcall.bat        guard policy + per-mod ratchet
tools\check-helpers.bat      copied helpers + per-mod ratchet
tools\run-tests.bat          real Lua 5.1, RDJson only — see §3 for the limit
```

None of these is a runtime test. Nothing here proves a hot path works; boot
Mosaic for anything touching an event hook or a per-tick path.

## 8. Hard "don't"s

- Never commit player data (`Dragonfly/snapshot.txt` and friends are live).
- Never rename an existing mod id.
- Never name "Reflections" in Core code, README, or anything player-visible.
  Speak in infrastructure terms — chronicle, schema.
- Never write a file whose extension is outside `ini/cfg/txt/log`.
  `getFileWriter` returns **nil** otherwise and fails **silently**
  (`LuaManager.java:9884`).
- Do not use `PZAPI.ModOptions`. Client toggles go on the vanilla Client panel.
