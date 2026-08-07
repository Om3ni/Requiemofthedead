# Writing a Limes satellite — per-zone settings for your own mod

Limes holds the zones. Your mod holds the logic. This is the contract between
them: you declare what your mod wants to know per zone, Limes stores it,
replicates it, persists it, and draws a control for it in the admin panel. You
never write a UI, a save format, or a packet.

Everything here is public API. Nothing in this document requires an edit to a
Limes file, and nothing requires Limes to know your mod exists at compile time.

Written 2026-08-06 against suite 1.1.0. Companion to `limes-design.md` (§11.3 is
the reasoning behind this contract) and `limes-todo.md` (what is still missing).

---

## The shape of it

Four calls, in this order:

```lua
-- 1. Say who you are. Optional, but it names your section in the panel.
Limes.mods.register("MyMod", {
    label = "My Mod",
    order = 20,
    description = "What this mod does, per zone.",
})

-- 2. Declare a field. One call per setting.
Limes.fields.register("MyMod", "patrolChance", {
    type = "number", default = 0, min = 0, max = 100,
    side = "both",
    group = "Patrols", label = "Patrol chance", order = 1,
    unit = "%",
    help = "How likely a patrol is to pass through this zone.",
})

-- 3. Read it where your logic runs.
local zone = Limes.getLocation(x, y)
local chance = Limes.fields.get(zone, "patrolChance")

-- 4. If your effect is standing, unwind it when the zone changes.
Limes.onZoneEvent(function(event, name, zone, rev) ... end)
```

That is the whole contract. The admin gets a dial for `patrolChance` in the
Details panel the moment your mod loads, grouped under "My Mod" → "Patrols",
with your help text behind the `?`.

---

## 1. `Limes.fields.register(owner, name, spec)`

Returns `true` on success, `false` and a console warning otherwise.

**`owner`** is your mod's id. First claim wins: if two mods register the same
field name, the second is refused and warned. That is deliberate — two owners
for one key is a design defect, not a runtime condition to arbitrate. Namespace
anything that is not obviously yours.

**`name`** is the key as it appears in the store and in `RFTDLimes.ini`. It must
match `[%w_]+`. A name outside that survives the wire and vanishes on the next
save, silently, because the persistence grammar drops it on the way back in.

### `spec` — storage

| Key | Meaning |
|---|---|
| `type` | `"number"`, `"boolean"` or `"string"`. Required. |
| `default` | What the field means when nothing in the inheritance chain sets it. |
| `min`, `max` | Numbers only. **Clamped at resolution**, not just in the UI. |
| `side` | `"both"`, `"client"` or `"server"`. See below. |

**`side` is a wire decision and it is the one to think about.** `"both"` sends
the value to every client; `"client"` too. `"server"` keeps it off the wire
entirely — the client never sees it and therefore cannot edit it.

Use `"server"` only for values that are genuinely large or genuinely secret: a
loot table, a spawn manifest. If an admin needs to *set* it in the panel, it has
to be `"both"`, because the editor is a client. An unusable `side` is corrected
up to `"both"` and never down — over-sending costs bandwidth, under-sending is a
correctness bug.

### `spec` — presentation

Carried by the registry, never interpreted by it. This is what makes your field
render without a line of UI code.

| Key | Meaning |
|---|---|
| `label` | What the admin reads. Defaults to the field name. |
| `help` | The `?` popout body. No help, no `?` glyph. |
| `group` | Section header within your mod's pane. |
| `order` | Sort order within your mod. Ties break by name. |
| `ui` | Force a control. Absent, the type decides. |
| `unit` | Suffix on a number — `"tiles"`, `"%"`. |
| `zero` | What `0` *means* when it does not mean zero — `"off"`. |
| `values` | For `enum` and `choice`. |
| `labels` | Parallel to `values`, for `choice`: what each is called. |
| `empty`, `rule`, `maxLen` | For `text`. |

### Which control you get

| `ui` | Stores | Use for |
|---|---|---|
| `bool` | boolean | a switch. Default for `type = "boolean"`. |
| `int` | number | a stepper with `min`/`max`/`step`. Default for `type = "number"`. |
| `enum` | **an index** | a positional set of options. |
| `choice` | **the string** | a closed set whose *value* is the word. |
| `text` | the string | prose. Opens a popout to type in. Default for `type = "string"`. |
| `colour` | — | **not built yet.** Declared fields are counted and reported. |

**`enum` versus `choice` is the one that bites.** `enum` stores a 1-based index
into `values`, which is right for a positional dial. `choice` stores the string
itself. If your consumer branches on the word — `if v == "remove"` — you want
`choice`, or the store will hold `2` where your code looks for `"remove"`: a
value that saves, replicates, displays and enforces nothing.

```lua
Limes.fields.register("MyMod", "patrolKind", {
    type = "string", default = "", side = "both",
    ui = "choice",
    values = { "",            "foot",       "vehicle" },
    labels = { "None",        "On foot",    "Vehicle" },
    group = "Patrols", label = "Patrol kind",
    help = "Who passes through. 'None' leaves the zone alone.",
})
```

Blank is a *position* in that list, not an escape from the control. An admin
choosing "leave this alone" is making a choice, and it should read like one.

**A closed set is never a text box.** A `text` field lets someone type `"Foot"`
and get silence. If a value has a list, give it the list.

---

## 2. Reading it

```lua
local zone = Limes.getLocation(x, y)     -- resolved zone at a tile, or nil
local zone = Limes.getZone("Riverside")  -- by name, or nil
```

A resolved zone is a table with `name`, `rects`, `inherits`, `profiles`,
`template`, `fields`, and a few internals. `profiles` (since 2026-08-07) is the
ordered list of profile names the record applies — profiles are rect-less
template zones whose fields merge into every zone that lists them (own fields
beat profiles; later profiles beat earlier; a profile's own `inherits` is never
followed). By the time you read `fields`, all of that has already happened —
a satellite never needs to know whether a value came from a profile. Read
fields two ways:

```lua
zone.fields.patrolChance                        -- nil when nothing sets it
Limes.fields.get(zone, "patrolChance")          -- falls back to your default
```

The difference matters. `zone.fields` contains only what is **set somewhere in
the inheritance chain**, so `nil` genuinely means "nobody has an opinion" and
you may apply your own logic. `Limes.fields.get` applies your registered default
instead. Use the raw table when "unset" and "set to zero" are different
statements; use `get` when they are not.

**Values arrive typed and clamped.** Registration is what does it: a store
written by hand or imported from elsewhere holds `"25"`, and by the time your
consumer sees it, it is `25`. That coercion is a *consequence of registering* —
an unregistered key is preserved verbatim and handed to you as whatever string
was in the file.

**Inheritance is already flattened.** A zone drawn inside another inherits its
parent's fields; `_default` sits under everything as the implicit root. You
never walk the chain yourself.

### Where your code can run

| | Server | Client |
|---|---|---|
| Store is populated | after `OnServerStarted` | after the baseline arrives |
| `side = "server"` fields | visible | absent |
| Limes present at all | dedicated server only | dedicated client only |

Limes is **dedicated-server-only** today. In single-player both `isServer()` and
`isClient()` are false, persistence never loads, and the store is empty by
construction. Guard accordingly, and do not assume a zone lookup in SP.

---

## 3. Reacting to change

```lua
Limes.onChanged(function(rev) ... end)
```

Fires when the store moves, for any reason. Use it to drop caches.

```lua
Limes.onZoneEvent(function(event, name, zone, rev) ... end)
-- event = "added" | "edited" | "enabled" | "disabled" | "deleted"
```

Fires per zone, and this is the one that matters **if your effect is standing**.

A standing effect is anything that persists after you applied it: a modified
global, a HUD element, a spawn suppression. Its undo path is usually "the player
leaves the zone" — and that never fires if the zone stops existing under the
player's feet. An admin disabling a zone while someone stands in it is not an
edge case; it is Tuesday.

```lua
Limes.onZoneEvent(function(event, name, zone)
    if event == "disabled" or event == "deleted" then
        MyMod.unwind(name)      -- or the effect outlives the zone forever
    end
end)
```

`zone` is the new resolved record, except on `"deleted"`, which carries the
last-known one so you can unwind by geometry.

Two properties worth relying on: events are **derived, never transmitted** —
both sides compute the identical sequence from the baseline or delta they
already have, so no event costs a packet — and the diff is **content-based**, so
a redundant baseline fires nothing. First boot on an empty store does report
every zone as `"added"`; if you only care about teardown, watch `"disabled"` and
`"deleted"`.

---

## 4. Bridging an existing mod

If your mod already has its own per-zone data and you want Limes to become the
source, **do it from your side, not by editing the host.** LMDirge is the worked
example: it takes over `RQPhunZones.getEffectiveRules` from within Limes, so
Dirge's three call sites are untouched and deleting the bridge file restores the
old behaviour exactly.

Two rules that came out of building it:

**Install deferred and idempotently.** Mod load order decides whether the host
has been parsed when your file runs, and the server's `Mods=` line is not yours
to assume. Try at load, retry on a boot event, and never install twice. A server
that happens to load the host first is the kind of luck that hides the defect.

**An empty store must not take over.** If Limes has no zones yet — a fresh
install, an import that has not happened — a bridge that answers anyway silently
replaces the host's working data with nothing.

---

## What this API does not do

- **No `colour` control.** Declare `ui = "colour"` and the field is counted and
  reported in the panel as one this build cannot draw. Forward-compatible by
  design: unknown `ui` values are carried, not dropped.
- **No per-field permissions.** Anyone who can open the editor can set any
  `side = "both"` field.
- **No validation callback.** `type`, `min`, `max` and a `choice` list are the
  whole vocabulary. A field that needs a rule enforces it in your consumer.
- **No schema versioning.** A field you rename is a new field; the old key stays
  in the store as an unregistered value.

---

## Checklist

- [ ] `type` is right, and `side` is `"both"` if the admin must set it
- [ ] a closed set uses `choice` with `values` + `labels`, not `text`
- [ ] `help` says what the field does **and what it cannot promise**
- [ ] the consumer tolerates `nil` — no zone, no value, no Limes
- [ ] a standing effect unwinds on `"disabled"` and `"deleted"`
- [ ] nothing assumes single-player
