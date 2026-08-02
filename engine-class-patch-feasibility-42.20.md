# Engine determination — Class-patching for file I/O: possible, but mostly unnecessary (42.20.0)

*Verified against `PZ_Engine_Decompiled_42.20.0-a2947723ca` and the live install at
`D:\Steam\steamapps\common\ProjectZomboid`, 2026-08-02. Companion to
`engine-lua-file-io-42.20.md`.*

**Short version: yes, a class patch is mechanically trivial — the launcher puts `./`
ahead of the jar on the classpath, so a loose `zombie/Lua/LuaManager.class` shadows the
shipped one with no jar surgery at all. But it would buy almost nothing, because the
capability inventory below shows the request is already ~90% satisfied by existing
exposed API: subfolders, dated filenames, and directory listing all work today. The only
genuinely missing verbs are DELETE and RENAME inside `Zomboid/Lua/` — and a sidecar
process (which SpyMaster needs anyway) has both for free.**

## The mechanism, if we wanted it

[ProjectZomboid64.bat] and [ProjectZomboidServer.bat] both set:

```
SET PZ_CLASSPATH=./;projectzomboid.jar
```

Current directory **first**. Java's classpath is first-match-wins, so
`<install>/zombie/Lua/LuaManager.class` on disk wins over the jar's copy. No jar
repacking, no `-javaagent`, no bytecode weaving required for the crude version.

Why it still isn't cheap:

- **Compile target.** You cannot recompile CFR output — the decompile has artifacts and
  `LuaManager` is enormous. A real patch means ASM/Javassist surgery on the original
  class, which means a build step and a tool.
- **Version fragility.** The patched class must match the engine's internals exactly.
  42.20 is **stable** (`public`, buildid 24449161, since 2026-07-29 — Steam deleted the
  `unstable` branch), so this is ordinary point-release maintenance rather than chasing a
  moving beta. But stable still ships hotfixes, and every one risks `NoSuchMethodError`
  or silent behavioral drift.
- **The silent-survival hazard.** A loose class in the install root is *untracked* by
  Steam: an engine update replaces `projectzomboid.jar` and **leaves the patch in
  place**, still shadowing, now compiled against internals that moved. It fails quietly
  rather than loudly. This is why a startup version assertion is not optional — the
  patch must refuse to load against an engine build it doesn't recognize.
- **Undistributable → server-side only.** Workshop mods ship `media/lua` trees. There is
  **no mod Java loading in 42.20** — the only `ClassLoader` reference in the entire
  `zombie` tree is the guard that blocks it. Clients would each hand-copy a class into
  their install root, so client-side patching is off the table for a Workshop suite.
  **The Mosaic server install is the one place it's viable**, because we own the box and
  the install. Note the consequence: a server patch changes *server* Lua's capabilities
  only — clients run stock engines, so nothing added this way can be relied on
  client-side.
- **IS is actively hardening this exact boundary.** `validateReflectionAccess`
  ([LuaManager.java:1616](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L1616))
  requires `Core.debug` *and* explicitly throws on `Class`, `ClassLoader`, and
  `MethodHandles.Lookup` — literally `throw new IllegalStateException("Nope")`. They
  have thought about the reflection escape hatch and closed it deliberately.

## Corrected capability inventory — what already works

Most of the wishlist is not missing. Verified exposed API:

| Want | Status |
|---|---|
| Write into `Zomboid/Lua/` | `getFileWriter` (allowlisted ext), `getFileOutput` (binary, any ext) |
| Read back | `getFileReader`, `getFileInput` ([:5608](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L5608)) |
| **Put files in a subfolder** | Already works — `getFileWriter` accepts `sub/dir/name.txt` and auto-creates dirs |
| **Name files by date** | `SimpleDateFormat` is exposed ([:1661](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L1661)); build the filename and write it |
| **Cycle/rotate** | Rotation-by-naming: write to `metrics-2026-08-02.txt`, start a new name when the stamp changes. **Rename is only needed if you name files wrong at creation.** |
| **Enumerate existing files** | `listFilesInZomboidLuaDirectory(dir)` ([:4950](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L4950)) — jailed to `Zomboid/Lua/`, blocks `..` and absolute paths. `listFilesInModDirectory(modId, dir)` ([:4961](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L4961)) scans commonDir **and** versionDir. |
| Free dated rotation into folders | `writeLog` — `LoggerManager.backupOldLogFiles` renames the previous session's logs into `logs_<datestamp>/` at init ([LoggerManager.java:36](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/logger/LoggerManager.java#L36)) |
| **Delete a file in `Zomboid/Lua/`** | **MISSING** — truncate-via-overwrite is the only substitute (leaves a 0-byte tombstone) |
| **Rename/move an existing file** | **MISSING** — copy-then-truncate approximates it |

So the entire prize for a class patch is **delete + rename**, i.e. pruning old rotated
files. Everything else described is available through the front door today.

## The better answer: the sidecar already has these rights

SpyMaster's design already includes a sidecar process on the Mosaic box (the static file
server). That process runs as a normal OS program with full filesystem access — it can
delete, rename, move, compress, and prune the metrics folder on any schedule, with no
engine involvement whatsoever. File *lifecycle* belongs there; the game only ever needs
to **append and enumerate**, which it can already do.

That split is also the safer architecture: the game keeps the smallest possible write
surface, and the risky verbs live in a process we fully control and can change without
touching a mod or an engine class.

## Recommendation

Don't patch. Rotation-by-naming + `listFilesInZomboidLuaDirectory` + a sidecar janitor
covers the whole requirement with zero engine risk, zero version fragility, and no
install-root artifacts on player machines. Revisit only if a future need genuinely
requires the game itself to delete files — and even then, prefer `writeLog`'s
engine-managed rotation first.

If a patch is ever built anyway, scope it to the Mosaic **server** install only (never
shipped to clients), keep it to a single additive method rather than weakening the
allowlist, and pin it to a known engine build with a startup version assertion.
