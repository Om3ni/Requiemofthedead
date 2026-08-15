# LZI — LuaZombieInjection (experimental)

A one-method sidecar patch to `zombie.popman.ZombiePopulationManager` that gives server
Lua a way to push zombie-config sandbox changes into the native popman (`PZPopMan64.dll`)
at runtime. Consumed by Reaper's `RPGovernor.lua` (the population governor).

## Why it exists

The native popman only receives config via `onConfigReloaded()`, which is called from
exactly two places: world init, and the `/reloadoptions` admin command. Neither is
reachable from Kahlua (`ZombiePopulationManager` and `GameServer.rcon` are not exposed).
The patch appends a push to `setZombiesMaxPerChunk`, whose caller
`setMinMaxZombiesPerChunk(min, max)` IS a global Lua function (LuaManager.java:4149).

After the patch, this Lua sequence hot-applies a population change:

```lua
getSandboxOptions():set("ZombieConfig.PopulationPeakMultiplier", 2.0)
setMinMaxZombiesPerChunk(0, 255)   -- 0/255 are the engine defaults; the call is the trigger
```

The push is gated on `GameServer.server` and wrapped in try/catch; on success the console
prints `[LZI] popman config pushed to native (peak=...)` — that line is the proof the
bridge is installed (Lua cannot detect it directly).

## Install

Copy everything under `classes/` into the dedi's `java/` directory, preserving paths:

```
<serverRoot>/java/zombie/popman/ZombiePopulationManager.class
<serverRoot>/java/zombie/popman/ZombiePopulationManager$PendingCellSave.class
<serverRoot>/java/zombie/popman/ZombiePopulationManager$ZombieSaveData.class
```

The dedi classpath is `java/. , java/projectzomboid.jar` (ProjectZomboid64.json), so the
loose classes shadow the jar. **All three files must be copied together** — javac emits
the inner classes separately and mixing patched/jar halves is undefined.

To uninstall: delete the three files. Nothing else changes.

## Update survival & maintenance

Steam updates and `validate` only touch depot-manifest files; these loose classes are
invisible to Steam and survive every update. The risk is the inverse — they keep
*winning* against a newer jar. After each engine update, re-diff:

```
C:\Tools\jdk-25.0.4+7\bin\javap -p -cp <serverRoot>/java/projectzomboid.jar zombie.popman.ZombiePopulationManager | sort > jar.sig
C:\Tools\jdk-25.0.4+7\bin\javap -p -cp classes zombie.popman.ZombiePopulationManager | sort > our.sig
diff jar.sig our.sig
```

If identical: TIS didn't change the interface; spot-check the CFR-decompiled body if
paranoid. If different: regenerate — decompile the new class (CFR), re-apply the patch
(marked with `// LZI bridge` in `ZombiePopulationManager.java` here), rebuild.

## Build

```
C:\Tools\jdk-25.0.4+7\bin\javac -nowarn -cp <serverRoot>/java/projectzomboid.jar -d classes ZombiePopulationManager.java
```

Needs JDK 25+ (the 42.20.2 jar is class-file version 69). Source here is the CFR 0.152
decompile of 42.20.2-ffe7a8a4b1 plus the marked patch; a pristine recompile was verified
signature-identical to the jar's class before patching.

## Scope

- Server-side only; never distributed with the mods. Clients need nothing.
- The patched setter also runs in the unpatched engine's only vanilla caller path
  (challenge-mode Lua on clients/SP) — the `GameServer.server` gate makes it a no-op there.
