# FMOD timeline seek from Lua — smoke test

**Goal:** start a sound at an arbitrary millisecond offset, using only what B42.20 already ships. No engine changes, no TIS request.

**The trick:** `BaseSoundEmitter:setTimelinePosition(ref, markerName)` is already Lua-exposed, but it takes a *named* marker that resolves through a `soundTimeline` script. `SoundTimelineScript:Load()` is also public and Lua-exposed — so we rewrite the marker's millisecond value at runtime, immediately before playing. One marker, any offset.

Everything below is traced from the 42.20 decompile but **not yet run** — that's what this test is for. Run the stages in order; each one isolates a different assumption.

---

## Stage 0 — setup

Two files in a throwaway test mod.

**`media/scripts/timeline_test.txt`**

```
module Base
{
    soundTimeline YOUR/EVENT/PATH
    {
        seek = 0,
    }
}
```

Three things about this file:

- **`YOUR/EVENT/PATH` is the FMOD event path with `event:/` stripped.** Whatever is on the `event = ` line in your sound script goes here verbatim. Vanilla examples: `Vehicle/Sport/Engine`, `Object/Fridge/Running`.
- **The trailing comma after `0` is mandatory.** The parser only commits a value when it hits a `,` — a closing brace does not flush it. `{ seek = 0 }` parses to an empty table and every lookup returns -1.
- The `module Base` wrapper is required; scripts live in module buckets.

**`media/lua/client/TimelineTest.lua`** — stub for now, filled in per stage:

```lua
local TL = {}

Events.OnKeyPressed.Add(function(key)
    if key == Keyboard.KEY_F7 then TL.stage1() end
end)
```

Rebind `KEY_F7` if it collides with something you have. Output goes to `console.txt`.

Run single-player, sound enabled. With sound off the game hands you a `DummySoundEmitter` whose `setTimelinePosition` is a no-op, and you'll chase a ghost.

---

## Stage 1 — does the script load, and under what name?

This is the cheapest stage and it answers the casing question outright.

```lua
function TL.stage1()
    local all = getScriptManager():getAllSoundTimelines()
    print("=== soundTimelines loaded: " .. all:size())
    for i = 0, all:size() - 1 do
        local st = all:get(i)
        print("   [" .. st:getEventName() .. "]  seek=" .. tostring(st:getPosition("seek")))
    end
end
```

**Pass:** your event path appears in the list, spelled exactly as you wrote it, with `seek=0`.

**Fail — your entry is missing:** the script file didn't load. Check the file is under `media/scripts/`, has the `module Base` wrapper, and that the mod is actually enabled.

**Fail — entry present but `seek=-1`:** the trailing comma. Go back and add it.

Note the exact spelling that comes back here. `getSoundTimeline(name)` is a straight map lookup with no case normalization, so this listing *is* the key you must use everywhere below.

---

## Stage 2 — can Lua rewrite the marker?

The one genuinely uncertain step. `Load` is declared `throws Exception`, and how the Kahlua bridge handles a checked-exception method is the thing I can't confirm from the decompile alone. Hence the `pcall`.

```lua
local EVENT = "YOUR/EVENT/PATH"   -- exactly as Stage 1 printed it

function TL.stage2()
    local st = getScriptManager():getSoundTimeline(EVENT)
    if st == nil then print("FAIL: no timeline named [" .. EVENT .. "]") return end

    local ms = 45000
    local body = "soundTimeline " .. EVENT .. " { seek = " .. ms .. ", }"

    local ok, err = pcall(function() st:Load(EVENT, body) end)
    print("Load ok=" .. tostring(ok) .. " err=" .. tostring(err))
    print("readback seek=" .. tostring(st:getPosition("seek")))
end
```

**Pass:** `ok=true` and `readback seek=45000`. Route is live — skip to Stage 3.

**Fail — `ok=false`:** read the error. If it's about the method not existing or arg mismatch, the bridge won't expose `Load` and you fall back to Stage 4.

**Fail — `ok=true` but `seek` unchanged or -1:** the string didn't parse. Print `body` and check the trailing comma survived your concatenation.

Two things worth knowing while you iterate: `Load` does **not** clear the map first, so repeated calls just overwrite the `seek` key — no growth, no leak. And the block header inside the string is cosmetic; `Load` takes the name from its first argument and only reads the key/value pairs. Keeping it accurate just makes debugging saner.

---

## Stage 3 — does it actually move the playhead?

Use a long event of your own — 60s+ — so the offset is unmistakable. Pick something with obvious structure; a track that's near-silent at 0:00 and loud at 0:45 makes this a one-listen verdict.

```lua
local EVENT = "YOUR/EVENT/PATH"    -- the FMOD event path
local SOUND = "YourGameSoundName"  -- the `sound X` script name, NOT the event path

function TL.playAt(ms)
    local st = getScriptManager():getSoundTimeline(EVENT)
    if st == nil then print("FAIL: no timeline") return end

    local ok = pcall(function()
        st:Load(EVENT, "soundTimeline " .. EVENT .. " { seek = " .. math.floor(ms) .. ", }")
    end)
    if not ok then print("FAIL: Load threw") return end

    local pl = getPlayer()
    local emitter = getWorld():getFreeEmitter(pl:getX(), pl:getY(), pl:getZ())
    local ref = emitter:playSound(SOUND)
    print("ref=" .. tostring(ref) .. " target=" .. ms .. "ms")
    if ref == 0 then print("FAIL: playSound returned 0") return end

    emitter:setTimelinePosition(ref, "seek")
end

function TL.stage3() TL.playAt(45000) end
```

**Pass:** playback starts 45 seconds in.

**Fail — `ref=0`:** `SOUND` isn't a real game sound name. That's the `sound X` script name, not the event path — the two are different strings and mixing them up is the most common way this stage fails.

**Fail — plays from 0:00:** either the event path in `EVENT` doesn't match what the clip actually carries, or the seek got applied to the wrong instance. Confirm Stage 1's name matches the `event = ` line in your sound script character for character.

Three constraints baked into the engine that you must design around:

1. **`setTimelinePosition` must happen in the same Lua call as `playSound`.** The event instance is created inside `playSound`, but `FMOD_Studio_StartEvent` doesn't fire until the emitter's next world tick — and the seek only searches sounds still waiting to start. Let a tick pass and it silently does nothing.
2. **This is start-at-offset only, not scrubbing.** There is no path to seek something already playing. If you need that, it has to be built inside the bank as an FMOD parameter and driven with `setParameterValueByName`, which *does* work on live instances.
3. **Don't cache the emitter.** Once it empties, the world recycles it back to the free pool. Grab a fresh one per sound.

There's no race in rewriting a shared marker, incidentally — `setTimelinePosition` resolves the name and fires the JNI call in one synchronous statement, so the value is consumed before anything else can touch it. Many emitters can seek the same event to different offsets in the same frame safely.

---

## Stage 4 — fallback, only if Stage 2 failed

If Lua can't call `Load`, pre-bake the markers instead. Same seek mechanism, coarser resolution, depends on nothing but ordinary script loading:

```
module Base
{
    soundTimeline YOUR/EVENT/PATH
    {
        t0 = 0,
        t1 = 1000,
        t2 = 2000,
        ...
        t247 = 247000,
    }
}
```

```lua
emitter:setTimelinePosition(ref, "t" .. math.floor(ms / 1000))
```

Generate the file with a script. 1-second resolution on a 4-minute track is 240 lines; 500ms is 480. Ugly in the file, inaudible at runtime. Clamp the index to the highest marker you actually emitted — a missing name returns -1 and the seek is skipped silently, so an out-of-range request plays from 0:00 rather than erroring.

---

## Reporting back

If it stalls, the useful details are: which stage, the exact `print` output, and the `event = ` line from your sound script. Stage 1's listing plus Stage 2's `ok=`/`err=` pair narrows it to a specific line of engine code almost every time.

Plan assembled by M.S.A with the help of Fable 5; grepped from the decompiled project zomboid headers. 
