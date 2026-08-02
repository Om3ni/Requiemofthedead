# Engine determination — What files can Lua write? (42.20.0)

*Verified line-by-line against `PZ_Engine_Decompiled_42.20.0-a2947723ca`, 2026-08-02.*

**Short version: Lua can write four kinds of files, and the famous 42.20 extension
allowlist only guards one of the four doors.**

## The four write paths

### 1. `getFileWriter(filename, createIfNull, append)`
[LuaManager.java:5511](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L5511)

Writes text to `Zomboid/Lua/<filename>` (subfolders allowed, auto-created). This is the
**only** function gated by the allowlist at
[LuaManager.java:9884](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L9884):

```java
ALLOWED_FILE_EXTENSIONS = Set.of("ini", "cfg", "txt", "log");
```

Two sharp edges:

- The check is **case-sensitive** — `getFileExtension` doesn't lowercase, so
  `Report.TXT` silently returns nil.
- **No extension at all fails too** (`""` isn't in the set) — a bare
  `getFileWriter("flags")` that worked in build 41 dies in 42.20.

Returns a `LuaFileWriter` (`write` / `writeln` / `close`), exposed at
[LuaManager.java:9889](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L9889).

### 2. `getFileOutput(filename)` — the loophole
[LuaManager.java:4794](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L4794)

Returns a raw `DataOutputStream` into the same `Zomboid/Lua/` folder with **no extension
check at all**, and `DataOutputStream` is explicitly exposed to Kahlua
([LuaManager.java:1653](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L1653)),
so `writeBytes`, `writeInt`, `close`, etc. are all callable from Lua. Binary writes, any
extension — `.jsonl`, `.bin`, whatever — still jailed to the Lua cache dir. The devs
gated the front door and left this one open.

Caveats: overwrite-only (no append flag), and it's a stream API rather than the friendly
writeln wrapper.

### 3. `getModFileWriter(modId, filename, createIfNull, append)`
[LuaManager.java:5032](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L5032)

Writes into the mod's own **common dir** with **any extension — including `.lua`**. A mod
generating files into itself (even code) is engine-legal. Two catches:

- The writer only targets `commonDir`, while `getModFileReader` checks `versionDir`
  first and falls back to common — an asymmetry to remember.
- On a dedi running Workshop builds, Steam updates wipe whatever you wrote there.

### 4. `writeLog(loggerName, text)`
[LuaManager.java:7447](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L7447)

Append-only channel to `Zomboid/Logs/<startup-timestamp>_<name>.txt` via
`LoggerManager`/`ZLogger`
([ZLogger.java:28](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/core/logger/ZLogger.java#L28)).
No allowlist, filename sanitized, and the engine auto-archives the previous session's
logs into dated `logs_<date>/` backup folders. Effectively a free, engine-managed
rotating log system — arguably a better home for chronicle-style streams than
hand-rolled ring buffers.

## The boundaries

- **Path traversal is dead everywhere**: every entry point runs `hasRelativePath`
  ([LuaManager.java:6910](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L6910),
  blocks `..`), and everything is prefixed into a jail — `Zomboid/Lua/`,
  `Zomboid/Logs/`, the mod dir, Saves, Screenshots, Sandbox Presets. There is no
  escaping the cache-dir tree.
- **Deletion is scoped**: `deleteSave` (recursive), `deletePlayerSave`,
  `deleteSandboxPreset` — all confined to saves/presets. Nothing can delete or rename
  inside `Zomboid/Lua/`; truncate-via-overwrite remains the only "delete" there.
- **Touch trick**: `getFileReader` / `getModFileReader` with `createIfNull=true` will
  *create* an empty file of any extension — the allowlist doesn't apply to readers.
- **Fixed-purpose extras**: `takeScreenshot([name])` → Screenshots PNG,
  `saveModsFile()`, `saveControllerSettings`.

## Practical takeaways for RFTD

- JSON payloads in `Zomboid/Lua/` must wear a `.txt`/`.log` name through
  `getFileWriter` — or keep their real extension by going binary through
  `getFileOutput`.
- `writeLog` is the sanctioned append-only stream with free rotation.
- Extensions must be lowercase; extensionless writes are dead as of 42.20.

## Addendum — do `.ini`/`.cfg` buy anything real? (2026-08-02)

**Through `getFileWriter`: no.** After the allowlist check passes, all four extensions
take the identical code path — same `BufferedWriter`, same UTF-8, same `Zomboid/Lua/`
jail. The engine attaches no parser, no rotation, no loader, no watcher to any of them.
The allowlist is a lockdown gate enumerating what B41-era Lua was already writing, not a
feature menu; the extension you pick is metadata for humans only.

**The one place `.cfg` means something to Lua — and it bypasses `getFileWriter`
entirely:** the sandbox preset system, rooted at `Zomboid/Sandbox Presets/`
([LuaManager.java:1268](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L1268)):

- `getSandboxOptions():savePresetFile(name)` / `loadPresetFile(name)` — engine-format
  read/write of `<name>.cfg`
  ([SandboxOptions.java:655](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/SandboxOptions.java#L655),
  class exposed at
  [LuaManager.java:2424](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L2424),
  instance via `getSandboxOptions()`
  [LuaManager.java:4789](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L4789)).
- `getSandboxPresets()` / `deleteSandboxPreset(name)` globals — list/delete by bare name
  ([LuaManager.java:4854](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L4854),
  [:4870](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/Lua/LuaManager.java#L4870)).

That's a genuinely useful surface — programmatic snapshot/restore/shipping of full
sandbox configurations — but you use it through those methods, never by hand-writing a
`.cfg` with `getFileWriter` (wrong directory, and you'd have to counterfeit the engine's
own serialization format).

**`.ini` means nothing to Lua anywhere.** The engine's many `.ini` files (`options.ini`,
`erosion.ini`, `sounds.ini`, per-save `InGameMap.ini`…) are all written by Java-internal
config writers; no INI parser is exposed to Kahlua. `debuglog-server.cfg`
([DebugLog.java:360](PZ_Engine_Decompiled_42.20.0-a2947723ca/zombie/debug/DebugLog.java#L360))
lives at cache-dir root — outside the Lua jail, engine-managed only.

**Verdict:** default to `.txt` (or `writeLog` for streams). Pick `.ini`/`.cfg` only as a
signal to humans and external tooling — an admin hand-editing settings, an editor
syntax-highlighting INI, a watcher script filtering by extension. If we ever want preset
manipulation, `savePresetFile` is the door.
