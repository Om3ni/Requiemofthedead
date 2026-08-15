-- SPDX-License-Identifier: GPL-3.0-or-later
-- RCPartsView - the vehicle parts diagram for the admin Vehicles tab (client).
--
-- Draws vanilla's own top-down mechanic overlay: a body silhouette per vehicle
-- family plus one sprite per part, each TINTED BY THAT PART'S ACTUAL CONDITION
-- and simply absent when the part is gone. 314 sprites ship with the game.
--
-- WHY THIS AND NOT ISUI3DScene. The 3D scene is a catalogue portrait, not the
-- car: SceneVehicle takes a script NAME and nothing else, builds its model list
-- from the VehicleScript, and calls getSkin(0) unconditionally - so it renders
-- a showroom-fresh vehicle whether the real one is a burnt shell with no hood.
-- Fine for "which car is this" (all RCMyVehicles uses it for), actively
-- misleading for "what shape is it in". It is also a GL viewport per open
-- panel. This is a handful of tinted texture draws and it tells the truth.
--
-- TWO DELIBERATE DIVERGENCES FROM VANILLA'S renderCarOverlay:
--   * no pulse. Vanilla throbs the alpha on a part below 10% or missing.
--     Growl rule 4 is "stillness, then the strike - nothing else moves", and a
--     diagram that breathes at you is exactly the ambient motion that rule
--     exists to forbid. Broken reads as dim-and-red, held still.
--   * semantic colour, not core highlight colour. Vanilla interpolates the
--     engine's good/bad highlight colours; we use DFKit ok/warn/danger so the
--     diagram speaks the same three-tone language as every other verdict in
--     the family, and so a reskin moves it with everything else.
--
-- THE FAMILY LADDER. ISCarMechanicsOverlay.CarList is a hardcoded table keyed
-- by script name, so a modded vehicle is not in it. Resolution order:
--   1. the script's OWN declaration (getCarMechanicsOverlay) - authoritative,
--      this is how a vehicle mod opts in, and vanilla checks it first too
--   2. exact script-name hit in CarList
--   3. INFERRED from the part set - and stamped as inferred on the diagram
--   4. nil, and the caller falls back
-- Step 3 is deliberately timid: it fires only on evidence that cannot mean
-- anything else (a tow hitch, a truck bed, rear doors). A silhouette that
-- confidently draws a van's parts on a sports car is worse than no diagram,
-- so when it is not sure it does not guess.

if isServer() then return end

-- ISCarMechanicsOverlay is deliberately NOT required. Nothing in vanilla
-- requires it either - it is a plain global dropped by the client's walk of
-- media/lua/client - so the require PATH is unverified, and a require that
-- fails throws. The family rule is that a FILE-SCOPE use of a foreign global
-- gets declared; every reference here is inside a function and resolves at
-- draw time, by which point the walk has long finished.

RCPartsView = RCPartsView or {}

local M   = RCShared.MODULE
local ART = "media/ui/vehicles/mechanic overlay/"

-- ---------------------------------------------------------------------------
-- Part data. Local first: getVehicleById resolves anything streamed to THIS
-- client, which is the common case and costs nothing. Only a car the admin can
-- see in the list but has never streamed needs a round trip, and then it is one
-- request for one car, cached - never the whole fleet's parts up front, which
-- would be 30-odd values per vehicle across hundreds of them.
-- ---------------------------------------------------------------------------

local cache     = {}   -- vid -> { parts = {...} }
local requested = {}   -- vid -> true while a request is in flight
local recheck   = {}   -- vid -> timestamp until which the cache is not trusted

-- How long after an edit to keep re-reading. A part edit is applied SERVER-side
-- and comes back via transmitPartCondition, so the local object does not change
-- in the same frame the command is sent - it changes a round trip later.
local RECHECK_MS = 1500

local function readLocalParts(vid)
    if not vid then return nil end
    local v
    -- guarded: vid rode in on a server row - a malformed value would blow the
    -- (short) cast inside getVehicleById
    if not pcall(function() v = getVehicleById(vid) end) or not v then return nil end
    -- Part walk and reads are bounds-checked field returns (VehicleParts.java:111,
    -- VehiclePart.java:130/891/166/155/352/398/359/148) - no guards needed.
    local out = {}
    local n = v:getPartCount()
    for i = 0, n - 1 do
        local p = v:getPartByIndex(i)
        if p then
            local rec = { id = p:getId() }
            rec.cond = math.floor(p:getCondition() or 0)
            -- "installable but no item present" is vanilla's own test for a
            -- part that has been removed rather than merely worn out
            rec.missing = (p:getInventoryItem() == nil) and (p:getTable("install") ~= nil) or false
            if p:isContainer() then
                rec.amount   = p:getContainerContentAmount()
                rec.capacity = p:getContainerCapacity()
            end
            -- Accepted item types, same field the server snapshot carries
            -- (RCFleet.parts) - the Workshop tab's recipe filter reads it and
            -- must not care which side answered.
            local it = p:getItemType()
            if it and it:size() > 0 then
                local list = {}
                for j = 0, it:size() - 1 do list[#list + 1] = tostring(it:get(j)) end
                rec.items = list
            end
            out[#out + 1] = rec
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Returns the part list, or nil while it is being fetched.
function RCPartsView.partsFor(row)
    if not row or row.loaded == false then return nil end
    local vid = row.vid
    if not vid then return nil end

    -- POST-EDIT RECHECK WINDOW. Invalidating on edit is not enough on its own:
    -- the command is applied server-side and returns via transmitPartCondition,
    -- so the frame right after the click still sees the OLD condition. A plain
    -- invalidate therefore refills the cache with pre-edit data and then trusts
    -- it forever - which reads as "repair does nothing until you click twice",
    -- because the second click's invalidate is what finally picks up the first
    -- click's result. Found 2026-08-03.
    --
    -- So for a short window after an edit, re-read every frame instead of
    -- trusting the cache. Steady state is unaffected.
    local now = getTimestampMs()
    local until_ = recheck[vid]
    if until_ then
        if now >= until_ then
            recheck[vid] = nil
        else
            local fresh = readLocalParts(vid)
            if fresh then
                cache[vid] = { parts = fresh }
                return fresh
            end
            -- not streamed here; fall through to the server path below
        end
    end

    local hit = cache[vid]
    if hit then return hit.parts end

    local local_ = readLocalParts(vid)
    if local_ then
        cache[vid] = { parts = local_ }
        return local_
    end

    if not requested[vid] then
        requested[vid] = true
        -- Two doors, one reply. The admin inspector asks by vid, behind
        -- the admin gate. The player panel's My Vehicles tab marks its
        -- rows `mine` and asks by CLAIM id - the server resolves that
        -- through the registry, so ownership is the proof and the vid the
        -- answer is keyed by never came from the client. Both replies
        -- land on "VehicleParts" keyed by vid; the cache neither knows
        -- nor cares which door was used.
        if row.mine and row.claimId then
            sendClientCommand(getPlayer(), M, "myvehicleparts", { claimId = row.claimId })
        else
            sendClientCommand(getPlayer(), M, "vehicleparts", { vid = vid })
        end
    end
    return nil
end

-- A car whose parts we just edited must not keep serving a stale diagram.
-- Opens the recheck window as well as dropping the cache - see partsFor for why
-- dropping alone is not enough.
function RCPartsView.invalidate(vid)
    if vid then
        cache[vid] = nil
        requested[vid] = nil
        recheck[vid] = getTimestampMs() + RECHECK_MS
    else
        cache, requested, recheck = {}, {}, {}
    end
end

-- Reassembly. The server byte-splits a parts list that outgrew one message, so a
-- reply can arrive as several - see RCFleet's note on why this was done before a
-- capture caught it rather than after.
--
-- ACCUMULATE UNTIL THE LAST SLICE, then publish. The cache is what the diagram
-- reads, so writing partial parts into it would render a vehicle as though it
-- were missing the components that simply had not arrived yet - a wrong diagram
-- rather than an incomplete one, and nothing on screen would say so.
--
-- `requested[vid]` is cleared only on completion for the same reason: it is the
-- in-flight marker, and clearing it early would let a second request start while
-- the first was still arriving.
--
-- A sender that predates this sends neither seq nor total; that reads as
-- seq=1 total=1, a single complete slice, and behaves exactly as before.
local assembling = {}

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M or command ~= "VehicleParts" or not args then return end
    local vid = args.vid
    if not vid then return end

    local seq   = tonumber(args.seq)   or 1
    local total = tonumber(args.total) or 1

    if total <= 1 then
        assembling[vid] = nil
        requested[vid]  = nil
        cache[vid] = { parts = args.parts or {} }
        return
    end

    -- A new stream for this vehicle supersedes a half-assembled older one.
    local acc = assembling[vid]
    if not acc or seq == 1 then acc = { parts = {}, got = 0 }; assembling[vid] = acc end

    for _, p in ipairs(args.parts or {}) do acc.parts[#acc.parts + 1] = p end
    acc.got = acc.got + 1

    if acc.got >= total then
        assembling[vid] = nil
        requested[vid]  = nil
        cache[vid] = { parts = acc.parts }
    end
end)

-- ---------------------------------------------------------------------------
-- Family resolution
-- ---------------------------------------------------------------------------

-- Inference targets, expressed as CarList KEYS rather than image prefixes -
-- getCarMechanicsOverlay returns a key too, so every rung of the ladder speaks
-- the same currency and there is one lookup at the end.
local INFER_TRAILER = "Base.Trailer"
local INFER_TRUCK   = "Base.PickUpTruck"
local INFER_4DOOR   = "Base.CarNormal"

local function partSet(parts)
    local set = {}
    for _, p in ipairs(parts or {}) do set[p.id] = true end
    return set
end

-- Timid on purpose - see the header. Each rule keys off a part that only one
-- body family has, and anything ambiguous returns nil so the caller falls back
-- rather than drawing a confident lie.
local function inferKey(row, parts)
    if row.kind == "trailer" then return INFER_TRAILER end
    local set = partSet(parts)
    if set["TruckBed"] then return INFER_TRUCK end
    if set["DoorRearLeft"] and set["DoorRearRight"] then return INFER_4DOOR end
    return nil
end

-- How many of this vehicle's parts vanilla actually has sprites for. An INFERRED
-- family is only worth drawing if most of the car will appear in it.
--
-- This is the modded-vehicle guard (KI5 and friends). Their part ids are their
-- own, so they are absent from vanilla's PartList and simply do not render -
-- leaving a silhouette with three parts on it and nothing to say the other
-- twenty exist. A sparse diagram is worse than none: it does not look broken, it
-- looks like a car with almost no damage.
local function drawableCount(parts)
    local PL = ISCarMechanicsOverlay and ISCarMechanicsOverlay.PartList
    if not PL then return 0 end
    local n = 0
    for _, rec in ipairs(parts or {}) do
        if PL[rec.id] then n = n + 1 end
    end
    return n
end

-- Below this many drawable parts an inferred diagram is refused. A vanilla car
-- clears it comfortably (four tires and four brakes alone are eight); a vehicle
-- whose parts are almost all custom does not, and falls back instead.
local INFER_MIN_DRAWABLE = 8

-- Returns props, inferred(boolean). props is nil when no family could be found.
function RCPartsView.family(row, parts)
    if not (row and ISCarMechanicsOverlay) then return nil, false end
    local CL = ISCarMechanicsOverlay.CarList
    if not CL then return nil, false end

    -- 1. the script's own declaration (this is how a mod opts in). TRUSTED
    --    without a coverage check: the author named this family deliberately,
    --    and second-guessing them would break the one path modded vehicles have.
    if row.overlay and CL[row.overlay] then return CL[row.overlay], false end
    -- 2. exact script-name hit - vanilla's own table, equally trusted
    if row.script and CL[row.script] then return CL[row.script], false end
    -- 3. inference, flagged, and only when enough of the car will actually draw
    local key = inferKey(row, parts)
    if key and CL[key] and drawableCount(parts) >= INFER_MIN_DRAWABLE then
        return CL[key], true
    end
    return nil, false
end

-- ---------------------------------------------------------------------------
-- Colour. Three tones, not a gradient: a diagram is read at a glance and an
-- interpolated ramp makes 55% and 65% indistinguishable exactly where the
-- decision lives.
-- ---------------------------------------------------------------------------
local function condColour(rec)
    local C = DFKit.col
    if rec.missing then return C.danger, 0.30 end
    local c = rec.cond or 0
    if c < 30 then return C.danger, 0.85 end
    if c < 65 then return C.warn,   0.85 end
    return C.ok, 0.80
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

-- Where the diagram actually landed last frame, so the hit test and the draw
-- can never disagree about the transform.
local placed = nil

-- THE DIAGRAM IS DRAWN UPRIGHT, and stays that way. Recording the dead end so
-- nobody spends the evening on it twice:
--
-- The art is 263x600 - portrait, nose up. Given a wide, short pane it fits to
-- the HEIGHT and lands ~95px across: legible as a picture, impossible to click
-- a wing mirror on. Rotating it 90 degrees seemed like the fix, and vanilla
-- offers exactly one call that can rotate AND scale - the free-quad
-- DrawTexture(tex, 8 corner coords, rgba), reached through javaObject since no
-- ISUIElement wrapper exists.
--
-- It renders a blob. The quad geometry is right (verified against
-- DrawTextureAngle's own corner order, TL/TR/BR/BL) and every sprite shares the
-- 263x600 canvas, so the fault is below Lua: that SpriteRenderer overload takes
-- no UV arguments, and PZ packs these into atlas pages - so the whole page gets
-- stretched across the quad instead of the sprite's sub-region. There IS a
-- render() overload taking explicit u/v corners, but it is not exposed.
--
-- The actual problem was never the art's orientation, it was putting PORTRAIT
-- art in a LANDSCAPE pane. Give the diagram a tall column instead and it fits
-- upright at nearly 1:1 - about six times the area, through the same
-- drawTextureScaledUniform that always worked. Layout, not trigonometry.

-- `noHit` exists for the player panel's tab, which draws this diagram but has
-- no right-click surface. `placed` is a single module-wide slot consumed by
-- partAt (the admin cheat menu's hit test), and both panels can be open at
-- once on a staff client - if the player tab also wrote the slot, whichever
-- panel drew LAST each frame would own the transform, and an admin's
-- right-click on their own diagram would resolve through the player tab's
-- geometry: wrong part, cheat applied to it. A surface that never hit-tests
-- must not write the hit-test state.
function RCPartsView.draw(el, rect, row, noHit)
    if not noHit then placed = nil end
    if not (el and rect and row) then return end

    if row.loaded == false then
        DFKit.drawEmpty(el, rect.x, rect.y, rect.w, rect.h,
            "unloaded - nothing to inspect until it streams in")
        return
    end

    local parts = RCPartsView.partsFor(row)
    if not parts then
        DFKit.drawEmpty(el, rect.x, rect.y, rect.w, rect.h, "reading parts...")
        return
    end

    local props, inferred = RCPartsView.family(row, parts)
    if not props then
        DFKit.drawEmpty(el, rect.x, rect.y, rect.w, rect.h,
            "no parts diagram for this vehicle")
        return
    end

    local base = getTexture(ART .. props.imgPrefix .. "base.png")
    if not base then
        DFKit.drawEmpty(el, rect.x, rect.y, rect.w, rect.h, "overlay art missing")
        return
    end

    local bw, bh = 0, 0
    -- guarded: a not-yet-loaded texture lazily reads its size off disk
    -- (Texture.java:715 -> syncReadSize:1315); a bad file skips this frame
    pcall(function() bw, bh = base:getWidth(), base:getHeight() end)
    if bw <= 0 or bh <= 0 then return end

    -- Fit upright, centred. Uniform scale only - the part rects assume the
    -- base's aspect ratio, and every sprite shares its canvas.
    local pad   = 6
    local scale = math.min((rect.w - pad * 2) / bw, (rect.h - pad * 2) / bh)
    if scale <= 0 then return end
    local dw, dh = bw * scale, bh * scale
    local dx = rect.x + (rect.w - dw) / 2
    local dy = rect.y + (rect.h - dh) / 2

    local C = DFKit.col
    -- The shell sits well back: it is context, and the parts are the message.
    el:drawTextureScaledUniform(base, dx, dy, scale, 0.30, C.textDim.r, C.textDim.g, C.textDim.b)

    local PL = ISCarMechanicsOverlay.PartList or {}
    for _, rec in ipairs(parts) do
        local pp = PL[rec.id]
        if pp then
            -- per-vehicle sprite override (rear windshields share art)
            if props.PartList and props.PartList[rec.id] then pp = props.PartList[rec.id] end
            local col, a = condColour(rec)
            local imgs = pp.multipleImg and pp.img or { pp.img }
            for _, name in ipairs(imgs) do
                local tex = getTexture(ART .. props.imgPrefix .. name .. ".png")
                if tex then
                    el:drawTextureScaledUniform(tex, dx, dy, scale, a, col.r, col.g, col.b)
                end
            end
        end
    end

    if not noHit then
        placed = { dx = dx, dy = dy, scale = scale, props = props, row = row }
    end

    if inferred then
        -- Say so. An inferred silhouette is a guess about the BODY, not about
        -- the conditions, and the admin is entitled to know which it is.
        local fL = DFKit.font.label or UIFont.Small
        local msg = "inferred body: " .. tostring(props.imgPrefix)
        el:drawText(msg, rect.x + 8, rect.y + rect.h - 18,
            C.warn.r, C.warn.g, C.warn.b, 0.8, fL)
    end
end

-- ---------------------------------------------------------------------------
-- Hit test. Vanilla's part rects live in ELEMENT space at scale 1, drawn from
-- (props.x, props.y) - so a rect coordinate is a texture pixel plus that
-- offset. Our draw is scaled and centred, so the inverse has to put the offset
-- back before comparing. Getting this wrong reads as "the hitboxes are shifted
-- by ten pixels", which is subtle enough to survive a lot of testing.
-- ---------------------------------------------------------------------------
function RCPartsView.partAt(mx, my)
    local p = placed
    if not p then return nil end
    local PL = ISCarMechanicsOverlay and ISCarMechanicsOverlay.PartList
    if not PL then return nil end

    local vx = p.props.x + (mx - p.dx) / p.scale
    local vy = p.props.y + (my - p.dy) / p.scale

    local parts = RCPartsView.partsFor(p.row) or {}
    for _, rec in ipairs(parts) do
        local pp = PL[rec.id]
        if pp then
            local x1, y1, x2, y2 = pp.x, pp.y, pp.x2, pp.y2
            local byFamily = pp.vehicles and pp.vehicles[p.props.imgPrefix]
            if byFamily then
                x1, y1, x2, y2 = byFamily.x, byFamily.y, byFamily.x2, byFamily.y2
            end
            if x1 and y1 and x2 and y2
                and vx >= x1 and vx <= x2 and vy > y1 and vy <= y2 then
                return rec
            end
        end
    end
    return nil
end

-- The rect the diagram currently occupies, for the tab's mouse plumbing.
function RCPartsView.isOver(mx, my)
    local p = placed
    if not p then return false end
    return RCPartsView.partAt(mx, my) ~= nil
end

-- ---------------------------------------------------------------------------
-- The per-part breakdown grid. MOVED HERE from RCVehicleTab (2026-08-13) the
-- day the player panel's My Vehicles tab grew the same grid - the diagram
-- answers "where is the damage", this answers "how bad, exactly", and two
-- surfaces drawing it from two copies is how the two answers drift apart.
-- The admin tab's drawParts is now a thin wrapper; its right-click cheat
-- surface keeps working off the hit rows this returns.
--
-- Grouped rather than alphabetical: whoever is reading asks "can it drive"
-- (drivetrain), "can it drive SAFELY" (running gear), then "is it worth
-- keeping" (body) - and a flat A-Z list interleaves those three questions.
-- ---------------------------------------------------------------------------
local GROUPS = {
    { title = "DRIVETRAIN",   match = function(id)
        return id == "Engine" or id == "Battery" or id == "GasTank" or id == "Muffler"
    end },
    { title = "RUNNING GEAR", match = function(id)
        return id:find("^Tire") or id:find("^Brake") or id:find("^Suspension")
    end },
    { title = "BODY",         match = function(id)
        return id:find("Door") or id:find("Window") or id:find("Windshield")
            or id == "TruckBed" or id:find("^Hood") or id:find("^Trunk")
    end },
}

local function partLabel(rec)
    if rec.missing then return "gone" end
    -- Containers say how full, not how intact: "21 / 60" is the useful fact
    -- about a gas tank, and its condition is the row's colour anyway.
    if rec.capacity and rec.capacity > 0 then
        return string.format("%d / %d", math.floor(rec.amount or 0), math.floor(rec.capacity))
    end
    return tostring(rec.cond or 0) .. "%"
end

local function partColour(rec)
    local C = DFKit.col
    if rec.missing then return C.danger end
    local c = rec.cond or 0
    if c < 30 then return C.danger end
    if c < 65 then return C.warn end
    return C.ok
end

-- Prettify a part id for a narrow column: "TireFrontLeft" -> "Tire Front Left".
local function partName(id)
    return (id:gsub("(%l)(%u)", "%1 %2"))
end

-- Draw the grid into `rect` (element space), scrolled by `scroll` (a DFScroll
-- the CALLER owns, because the offset has to outlive the frame and this
-- function is redrawn from scratch every one of them). Returns the hit rows -
-- { x, y, w, h, rec } in element space, only for rows actually visible - or
-- {} when there was nothing to draw; the admin tab feeds them to its
-- right-click cheat surface, the player tab throws them away.
function RCPartsView.drawBreakdown(el, rect, row, scroll)
    local p = rect
    local function clearScroll()
        scroll:measure(0, 0)
        scroll:reset()
        return {}
    end
    if not p or p.h < 30 then return clearScroll() end
    local C  = DFKit.col
    local fL = DFKit.font.label or UIFont.Small
    if not row then return clearScroll() end

    if row.loaded == false then
        DFKit.drawEmpty(el, p.x, p.y, p.w, p.h,
            "unloaded - no part data until someone streams it in")
        return clearScroll()
    end

    local hits = {}

    local parts = RCPartsView.partsFor(row)
    if not parts then
        DFKit.drawEmpty(el, p.x, p.y, p.w, p.h, "reading parts...")
        return clearScroll()
    end

    -- Bucket once. Anything unmatched lands in OTHER rather than vanishing -
    -- modded vehicles carry parts vanilla never named, and silently dropping
    -- them would make the panel lie about what is on the car.
    local buckets, seen = {}, {}
    for i = 1, #GROUPS do buckets[i] = {} end
    local other = {}
    for _, rec in ipairs(parts) do
        if not seen[rec.id] then
            seen[rec.id] = true
            local placed_ = false
            for i, g in ipairs(GROUPS) do
                if g.match(rec.id) then buckets[i][#buckets[i] + 1] = rec; placed_ = true; break end
            end
            if not placed_ then other[#other + 1] = rec end
        end
    end

    -- Grid rhythm from the label font, not fixed. A 15px part row around a
    -- 20px glyph overlaps the row beneath it, and this grid is dense enough
    -- that the overlap compounds down the whole column.
    local gfh = 12
    -- guarded: getFontHeight NPEs on a font this build lacks
    -- (TextManager.java:127); 12px is the fallback rhythm
    pcall(function() gfh = getTextManager():getFontHeight(fL) end)
    local ROW_H2 = math.max(15, gfh + 3)
    local HEAD_H = math.max(16, gfh + 4)
    -- One column in a tall narrow pane; two if the caller hands this a wide
    -- one. Derived from the width rather than assumed, so the grid cannot
    -- spill off its own pane.
    local nCols = (p.w >= 420) and 2 or 1

    -- MEASURE FIRST, then flow. This used to fill columns against the visible
    -- height and simply stop - drawGroup returned false and every remaining
    -- group vanished, with nothing on screen to say so. Vanilla cars fit, so it
    -- never showed; a KI5 car carries far more parts and most of them land in
    -- OTHER, which is drawn last and so is exactly what disappeared.
    --
    -- The fix is a virtual canvas: measure what the content actually needs,
    -- give the columns that height to flow into, and scroll the result. The
    -- column model survives intact - content still fills column 1 before
    -- column 2 - it is just no longer clipped to one screenful.
    local function groupH(list)
        if #list == 0 then return 0 end
        return HEAD_H + #list * ROW_H2 + 6
    end
    local totalH = 0
    for i = 1, #GROUPS do totalH = totalH + groupH(buckets[i]) end
    totalH = totalH + groupH(other)

    local virtualH = math.max(p.h, math.ceil(totalH / nCols))

    -- The gutter is 0 when it all fits, so a vanilla car still uses the full
    -- pane. Named sbW, not barW: the condition meter inside each row is already
    -- a local `barW` further down, and one shadowing the other is a bug waiting.
    local sc     = scroll
    local sbW    = sc:measure(p.h, virtualH)
    local availW = p.w - sbW
    local colW  = math.floor((availW - (nCols - 1) * 12) / nCols)
    local cols  = {}
    for i = 1, nCols do cols[i] = { x = p.x + (i - 1) * (colW + 12), y = p.y } end
    local ci = 1

    -- Column cursors are VIRTUAL positions; sy() maps one to the screen.
    local function sy(vy) return sc:screenY(vy) end
    local function visible(vy, h) return sc:shows(vy, h, p) end

    local function room(need)
        return (cols[ci].y + need) <= (p.y + virtualH)
    end
    -- Fall to the next column when this one fills. With the virtual height
    -- above, "all columns full" now means the content genuinely does not fit
    -- the canvas we sized for it, which cannot happen - the canvas was sized
    -- from the content. The guard stays as a backstop.
    local function ensure(need)
        if room(need) then return true end
        while ci < nCols do
            ci = ci + 1
            if room(need) then return true end
        end
        return false
    end

    local function drawGroup(title, list)
        if #list == 0 then return true end
        if not ensure(HEAD_H + ROW_H2) then return false end
        local c = cols[ci]
        if visible(c.y, HEAD_H) then
            el:drawText(title, c.x, sy(c.y), C.textDim.r, C.textDim.g, C.textDim.b, 0.8, fL)
        end
        c.y = c.y + HEAD_H
        for _, rec in ipairs(list) do
            if not ensure(ROW_H2) then return false end
            c = cols[ci]
            -- Scrolled off: no drawing and no hit rect. A part that cannot be
            -- seen must not answer a right-click, or the cheat menu would act
            -- on whichever row happened to share those coordinates.
            if visible(c.y, ROW_H2) then
                local ry    = sy(c.y)
                local col   = partColour(rec)
                local label = partLabel(rec)
                local lw    = getTextManager():MeasureStringX(fL, label)
                local nameW = colW - lw - 66
                local nm    = partName(rec.id)
                if DFTheme and DFTheme.fitText and nameW > 12 then
                    nm = DFTheme.fitText(nm, fL, nameW)
                end
                el:drawText(nm, c.x, ry, C.text.r, C.text.g, C.text.b, rec.missing and 0.6 or 1, fL)
                -- bar sits between the name column and the value
                local barX = c.x + colW - lw - 58
                local barW = 50
                if barW > 8 then
                    el:drawRect(barX, ry + 6, barW, 4, 0.45, C.bg.r, C.bg.g, C.bg.b)
                    if not rec.missing then
                        local pct = math.max(0, math.min(100, rec.cond or 0))
                        el:drawRect(barX, ry + 6, math.floor(barW * pct / 100), 4, 1, col.r, col.g, col.b)
                    end
                end
                el:drawText(label, c.x + colW - lw, ry, col.r, col.g, col.b, 1, fL)
                -- Record the row's box for the caller's hotspot, in SCREEN
                -- space and captured BEFORE the cursor advances, so the rect
                -- is the one just drawn.
                hits[#hits + 1] = { x = c.x, y = ry, w = colW, h = ROW_H2, rec = rec }
            end
            c.y = c.y + ROW_H2
        end
        cols[ci].y = cols[ci].y + 6
        return true
    end

    -- Clip to the pane: with a scroll offset the first and last rows straddle
    -- the edges, and unclipped they would paint over whatever the caller drew
    -- above and below.
    sc:clip(el, p)
    for i, g in ipairs(GROUPS) do
        if not drawGroup(g.title, buckets[i]) then break end
    end
    drawGroup("OTHER", other)
    sc:unclip(el)

    -- The bar, outside the stencil and last. Its presence is also the only
    -- honest signal that the car has more parts than the pane shows.
    sc:draw(el, p, C)

    return hits
end

print("[RC] RCPartsView loaded (mechanic overlay diagram)")

-- ---------------------------------------------------------------------------
-- Copyright (C) 2026 Project_Omen. Part of Requiem of the Dead.
--
-- Free software under the GNU General Public License, version 3 or later.
-- You may use, study, modify and share it. If you share it - modified or not,
-- on the Workshop or anywhere else - keep this notice, license your version
-- under the GPL too, publish your source, and say what you changed.
-- Distributed in the hope it is useful, but WITHOUT ANY WARRANTY.
-- <https://www.gnu.org/licenses/gpl-3.0.html>
