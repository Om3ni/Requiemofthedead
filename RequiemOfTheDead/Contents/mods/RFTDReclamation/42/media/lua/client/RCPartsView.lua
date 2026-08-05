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
    if not pcall(function() v = getVehicleById(vid) end) or not v then return nil end
    local out, n = {}, 0
    pcall(function() n = v:getPartCount() end)
    for i = 0, n - 1 do
        pcall(function()
            local p = v:getPartByIndex(i)
            if not p then return end
            local rec = { id = p:getId() }
            pcall(function() rec.cond = math.floor(p:getCondition() or 0) end)
            -- "installable but no item present" is vanilla's own test for a
            -- part that has been removed rather than merely worn out
            pcall(function()
                rec.missing = (p:getInventoryItem() == nil) and (p:getTable("install") ~= nil) or false
            end)
            pcall(function()
                if p:isContainer() then
                    rec.amount   = p:getContainerContentAmount()
                    rec.capacity = p:getContainerCapacity()
                end
            end)
            out[#out + 1] = rec
        end)
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
        pcall(function()
            sendClientCommand(getPlayer(), M, "vehicleparts", { vid = vid })
        end)
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

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M or command ~= "VehicleParts" or not args then return end
    local vid = args.vid
    if not vid then return end
    requested[vid] = nil
    cache[vid] = { parts = args.parts or {} }
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

function RCPartsView.draw(el, rect, row)
    placed = nil
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

    placed = { dx = dx, dy = dy, scale = scale, props = props, row = row }

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
