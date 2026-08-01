# The RotD UI Schema — "Chorus" (working title)

Instructions for how player-facing panels are authored in this family, starting
with Echoes' Songbook. This is the root reference: what the engine can actually
do (verified against the 42.20 decompile), what our schema looks like, and the
rules for writing one.

## Provenance and the originality rule

The design conversation that produced this studied three mods: EHR (layout
anatomy), and Angrii's RQD suite and Deadband (what disciplined PZ UI
architecture looks like at scale). **Those are Angrii's work. We take lessons,
never code** — no identifiers, no file structure, no distinctive
implementations. Chorus is a clean-room system, grounded directly in the
engine, with the stated goal of surpassing what inspired it. Credit the
inspiration honestly in comments where it's real; copy nothing.

## What the engine is actually capable of (verified, 42.20 decompile)

Everything below was confirmed in `PZ_Engine_Decompiled_42.20.0-a2947723ca`
or vanilla `media/lua`. Anything *not* listed here should be verified before a
schema feature depends on it ([the standing rule](docs/) — never guess an
engine API).

### Tier 1 — PZAPI atom framework (the modern substrate)
`media/lua/client/PZAPI/ui/` (vanilla, drives the B42 world map; joypad-aware
via `ISAtomUIJoypad`). Java side: `zombie.ui.AtomUI*`.

- Node tree with **per-node transforms: `angle` (rotation), `scaleX/Y`,
  `pivotX/Y`**, position/size, per-node `r,g,b,a`.
- **`isStencil` nodes** — clipping is a property of the tree, and it nests
  (Java tracks a stencil level).
- Anchoring (`anchorLeft/Right/Top/Down`), `alwaysOnTop`/`alwaysBack`,
  visible/enabled.
- **Declarative construction**: atoms are built by calling a class table with
  a property table. Composition layers: `atoms/` (Node, Text, TextEntry,
  Texture), `molecules/`, `organisms/`. There is a `testUI.lua` harness.

This is the intended future of PZ UI and the natural rendering target for a
schema. It is not an experiment: vanilla ships **molecules** (Panel, TabPanel,
ImageButton, TextButton, ScrollBarVertical) and **organisms** (Window,
FishWindow, BuildUI, PrintMedia, an Inventory prototype) built on it — real
game UI. Notes from the dig: `testUI.lua` is stale legacy (requires a
`pzapi/ui/ui` module that no longer exists) but usefully demonstrates
texture-atom 9-slice props (`sliceLeft/Right/Top/Down`), `anchorSide` and
`mouse` extensions, and live rotate/scale — those properties are read by the
Java `AtomUI*` classes from the node table, so they likely work on current
atoms; the probe list covers confirming them.

**Engine semantics finding (verified, decompile):** PZ's Kahlua fork patched
`KahluaTableImpl.rawget` — on a key miss the read falls through to
`metatable.rawget(key)`, so every PZ table treats its metatable as an
implicit `__index`. Vanilla atom code depends on this (`_mt.instantiate` is
reachable with no `__index` wired). Stock-Lua tooling must shim it (Project
Echo's harness does, one line); any code meant to run both in-game and in
tests must not rely on the fallback unshimmed.

### Tier 2 — the raw draw surface (`zombie.ui.UIElement`, usable from any ISUIElement)
- **Free-quad texture draw** — `DrawTexture(tex, tlx,tly, trx,try, brx,bry,
  blx,bly, r,g,b,a)`: arbitrary corner placement. Skew, tilt, fake
  perspective, card-flip illusions.
- **`DrawTextureAngle`** — rotation about a center point.
- **`DrawUVSliceTexture`** — UV sub-rectangles: proper **9-slice chrome** from
  one small texture.
- **Tiling** — `DrawTextureTiled` / `TiledX` / `TiledY` / `TiledYOffset`:
  repeating patterns, paper grain, film sprocket edges.
- **Mask/percentage fills** — `DrawTexturePercentage` /
  `PercentageBottomUp` / `DrawTextureIconMask`: textured meters and XP bars
  with zero custom art beyond the fill texture.
- **`DrawLine` with thickness**, **`DrawPolygon`** (textured 4-point).
- **`DrawItemIcon(item, ...)` / `DrawScriptItemIcon`** — the engine draws any
  item's real icon at any size. No texture-path guessing.
- **Stencils: `setStencilRect` AND `setStencilCircle`**, `suspendStencil` /
  `resumeStencil`, `repaintStencilRect`. Circular portholes, vignette masks,
  clipped scroll regions.
- Text: per-call font, `DrawText` with **zoom** parameter, Centre/Right
  variants, `DrawTextUntrimmed`, `drawTextWithBackground`.
- `setMaxDrawHeight`, `setRenderClippedChildren`, per-player render context
  (splitscreen-safe).

### Tier 3 — fonts (`zombie.ui.UIFont`)
- **SDF family: `SdfRegular`, `SdfBold`, `SdfItalic`, `SdfBoldItalic`** (+
  `SdfOld*`) — signed-distance-field: crisp at any scale, real bold/italic.
- Flavor fonts: **`Handwritten`** (sheet-music annotations want this),
  `Dialogue`, `Title`, `Intro`, `Code*`, `AutoNorm*`, classic `Small/Medium/
  Large/Massive`.

### Tier 4 — 3D and exotic widgets
- **`UI3DModel`**: renders a character with a full **animation state machine**
  (`setAnimSetName`, `setState`, `setVariable`, `setAnimate`), direction,
  zoom, X/Y offset. This is how a portrait can show the player *performing* —
  the play animations we already ship, running live in the panel.
- **`UI3DScene`** (Lua-exposed, `zombie.vehicles.UI3DScene`): the model/scene
  viewer behind vehicle debug tooling. Candidate for rendering instrument
  models directly. Command-style API — needs in-game probing before we depend
  on it.
- **`RadialMenu` and `RadialProgressBar`** — native radial widgets. A
  quick-play wheel is an engine primitive, not a dream.
- `ScreenFader` exists engine-side.

### Known absences (design around, don't fight)
- No gradient draw call — fake with a soft-edge texture (free-quad or tiled)
  or stacked alpha strips.
- No shader access from Lua. No arbitrary FBO/render-to-texture from Lua.
- `io.open` is blocked; prefs persist via `getFileWriter`/`getFileReader`
  (allowlisted extensions — `.txt` is proven by Last Rites' prefs layer).

### Probe results (2026-08-01, ECUIProbe full auto-run, all pages green)
Live-verified in engine — every draw page rendered without error: free-quad
skew + rotation, rect AND circle stencils, UV 9-slice, tiled fills,
percentage-mask meters, DrawItemIcon, SDF + flavor fonts, thick lines,
polygons, and RadialProgressBar as a properly-wrapped child element
(constructor is `(luaSelfTable, texture)` — the standard wrapper contract;
`setValue(0..1)` drives it). Portrait sub-probes all passed: `setCharacter`,
`setDirection`, `setAnimateWhilePaused` (NOTE: the ISUI3DModel wrapper has no
`setAnimate`), `setState("idle")`, and `setVariable("PerformingAction",
"ECPlayGuitarAcoustic")` — the doll accepts our AnimSet condition variable.

Two hard-won engine rules from the probe cycle: exposed-Java arg-count
mismatches detonate OUTSIDE `pcall` (never blind-call exposed constructors),
and in `-debug` a dumped Lua error pauses the game loop even when caught.

### Portrait verdict (2026-08-01, user's eyes + decompile)
The doll renders; **the equipped instrument does not**. Root cause: the doll
copies clothing and back/belt attachments but not hand models. The engine CAN
do it — `AnimatedModel.setPrimaryHandModelName(String)` exists — but the
field is private in `UI3DModel`, the class is not Lua-exposed, and no wrapper
passes it through. Held-item portraits are engine-possible, Lua-unreachable
in 42.20. Therefore `portrait3d` v0 = **doll + engine-drawn item icon
composed over it** (`DrawItemIcon`, verified); a performing-motion doll with
empty hands would read as mime and is off the table until the engine exposes
hand models.

### Still needs eyes or further probing
1. Can `UI3DScene` display an arbitrary item model cleanly in a panel?
   (Global is exposed; command API unprobed — this is the remaining route to
   a rotating 3D instrument in the portrait box, as a probe page 9.)
3. PZAPI atom behavior under load: nested stencils + rotation + scale
   together; input routing vs classic ISUI windows above/below it.
4. SDF legibility judgment at small sizes (rendered clean; taste pending).

## The schema

A panel is **one Lua table**: data in, window out. The renderer (the "Chorus
engine", built once, owned by Echoes until it earns a Core promotion) consumes
it, validates it loudly at boot in debug, and builds the UI. Panels never
hand-position widgets; they declare structure, style tokens, data bindings,
and intents.

```lua
return {
    id = "ec_songbook",                 -- unique, prefixed by owning mod

    -- 1. TOKENS: the single visual vocabulary. No literal colors/sizes
    --    anywhere else. Themable; the settings wheel edits these live.
    tokens = {
        color = {
            ink     = { 0.92, 0.90, 0.84 },   -- text
            inkDim  = { 0.60, 0.58, 0.54 },
            accent  = { 0.75, 0.62, 0.30 },   -- Echoes brass
            surface = { 0.04, 0.04, 0.05 },
            panel   = { 0.08, 0.08, 0.09 },
        },
        font  = { body = "SdfRegular", strong = "SdfBold", flavor = "Handwritten" },
        space = { xs = 4, s = 8, m = 12, l = 20 },
        chrome = { bezel = true, wornEdges = true },
    },

    -- 2. SURFACES: opacity-bearing layers. Prefs attach here — the alpha
    --    slider maps to a surface, chrome and body fade independently,
    --    content ink never fades below floor.
    surfaces = {
        chrome = { alpha = 0.97, prefKey = "songbook.alpha.chrome", floor = 0.30 },
        body   = { alpha = 0.92, prefKey = "songbook.alpha.body",   floor = 0.30 },
    },

    -- 3. FRAME: window behavior. Sizes are the *design* size; the renderer
    --    owns min/collapse/remember mechanics.
    frame = {
        w = 760, h = 520, minW = 420, minH = 400,
        collapsedW = 420, collapsible = "library",
        remember = { "position", "size", "collapsed" },   -- via ECPrefs
        settingsWheel = true,                              -- gear -> prefs flyout
    },

    -- 4. REGIONS: named rectangles from a dock pass (top/left/fill), no
    --    absolute coordinates. Every widget lives in a region.
    regions = {
        header   = { dock = "top",  h = 40 },
        tabs     = { dock = "top",  h = 72 },
        portrait = { dock = "left", w = 300 },
        library  = { dock = "fill", collapsible = true },
    },

    -- 5. TABS: a registry contract, not a hardcoded list. Providers return
    --    tab instances; Echoes registers instruments-in-inventory + Group;
    --    a future admin tab plugs in without touching this file.
    tabs = { provider = "ECSongbookTabs.list", glyphSize = 44, showLabelsOnHover = true },

    -- 6. WIDGETS: typed nodes in regions. Types are the Chorus vocabulary —
    --    each maps to verified engine capability, nothing speculative.
    widgets = {
        { id = "who",     type = "portrait3d", region = "portrait",
          source = "ECSongbookData.portrait",     -- character + instrument + anim state
          interact = { rotate = true, zoom = true }, fallback = "itemicon" },
        { id = "skill",   type = "meter", region = "portrait", dock = "bottom",
          source = "ECSongbookData.skill" },       -- level, xp, max — textured fill
        { id = "carry",   type = "readout", region = "portrait", dock = "bottom",
          source = "ECSongbookData.carry" },       -- lure distance line
        { id = "songs",   type = "list", region = "library",
          source = "ECSongbookData.rows", rowStyle = "songRow",
          empty = "IGUI_EC_NoSongs" },
        { id = "actions", type = "buttonrow", region = "library", dock = "bottom",
          buttons = { "play", "group", "join" } },
    },

    -- 7. BINDINGS: pure functions, data -> view model. No widget reads game
    --    state directly; no binding touches a widget. This is the seam that
    --    survives every relayout.
    bindings = "ECSongbookData",

    -- 8. ACTIONS: named intents, resolved by the owning mod. Widgets refer
    --    to these by id; the schema never embeds behavior.
    actions = "ECSongbookActions",
}
```

### Authoring rules

1. **Tokens or nothing.** A literal color or magic pixel number in a widget
   definition is a review-blocker. New look = new token.
2. **Bindings are pure.** They read game state and return plain tables. If a
   binding needs a side effect, it's an action.
3. **Actions are intents.** `play`, `joinGroup(username)` — the schema knows
   names, the mod knows meaning.
4. **No vanilla suppression.** We never hide/patch vanilla windows from tick
   hooks. Our panels stand next to the game, not on its throat.
5. **Prefs are cosmetic only** and go through the mod's prefs file
   (LRPrefs pattern); outcome-affecting config stays sandbox.
6. **Verify before you claim.** A widget type may only enter the vocabulary
   with its engine capability confirmed in the table above — decompile first,
   probe panel when the decompile isn't enough.
7. **Fail loud in debug, degrade quiet in prod.** Schema validation errors
   should be unmissable on a dev build and non-fatal on Mosaic.
8. **Boundaries hold.** Chorus lives in Echoes today. If a second mod wants
   it, it graduates to Core — it does not get copy-pasted sideways.

## The HTML authoring surface (the pipeline)

The schema above is the **IR**, not the authoring format. The pipeline lives
in its own project, **`C:\VSCodeProjects\ProjectEcho`** (see its README for
operations); this section is the contract. Panels are designed
as a constrained HTML dialect in `design/ui/`, previewed live in a browser
(VS Code Live Server — instant reload, devtools, real iteration speed), and
compiled to schema Lua. This works because PZAPI atoms and HTML are the same
abstraction — retained rectangle trees with transforms, clipping and z-order:
transforms map to `transform`, stencil nodes to `overflow: hidden`, stencil
circles to `border-radius` + overflow, 9-slice to `border-image`, tiling to
`background-repeat`, mask fills to `clip-path`, anchors to edge pinning.

```
design/ui/songbook.html      authored by humans, previewed in browser
        │  tools/chorus-compile (Python stdlib, watch mode)
        ▼
ECSongbookSchema.lua         the IR — reviewed, diffed, committed
        │  tools/check-lua + golden-tree suite (headless atom stub)
        ▼
PZAPI atom tree              runtime; debug Lua reload for in-game hot loop
```

Dialect rules:

- **Only the dialect compiles.** `data-region`, `data-widget`, `data-token-*`
  attributes on a small tag set; arbitrary HTML/CSS is a compile error, not a
  best-effort guess. The dialect is the schema wearing HTML clothes.
- **Tokens are the single source.** `design/tokens.css` is the hand-authored
  truth: the browser consumes its CSS variables directly, and the compiler
  parses them into every schema's token table. Design files may reference
  only those variables. One vocabulary, two renderers.
- **Real art in the preview.** PZ textures are PNGs already; the compiler
  mirrors referenced textures into the design folder so the browser shows
  actual chrome and icons.
- **Text never pixel-fits.** Browser font metrics approximate SDF metrics;
  text widgets must live in docked/fill regions so measurement differences
  cannot break layout. The compiler rejects fixed-size text containers.
- **3D/radial preview as stand-ins.** `portrait3d` renders as a placeholder
  in the browser; its truth is the probe panel, never the mock.
- **The browser is preview, not proof.** Correctness chain stays: compiler
  output → headless golden-tree tests → probe panel pixels in game.

### Headless testing (why this pipeline is trustworthy)

The PZAPI atoms Lua layer is pure Lua 5.1; its only engine seam is
`ui.javaObj = ui._ATOM_UI_CLASS.new(ui)` (`Meta.lua:64`), and
`_ATOM_UI_CLASS` is per-node data. A recording stub class plus eight trivial
globals (`getMouseX/Y`, `getText`, `getPlayerScreen*`, `UIManager.AddUI`)
lets the full tree build inside `tools\run-tests` — schema validation, token
resolution, dock math and tree shape assert headlessly; golden-tree snapshots
turn schema diffs into reviewable text. Java-side truth (text measurement,
render, input) stays with the probe panel.

### Roadmap

- **v0**: renderer core — tokens/surfaces/frame/regions + `list`, `meter`,
  `readout`, `buttonrow`, `tabbar`, settings flyout with per-surface alpha
  sliders (slider + exact-entry rows). Songbook ships on it.
- **v0.5**: probe results fold in — `portrait3d` goes live (animated
  performer, or item model via UI3DScene, or icon fallback; whichever the
  probes prove).
- **v1**: `radial` widget (quick-play wheel), granular theming (per-token
  color editing in the settings wheel), PZAPI-atom rendering backend behind
  the same schema.
