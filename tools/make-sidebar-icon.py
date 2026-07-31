#!/usr/bin/env python3
"""make-sidebar-icon.py - turn one master PNG into a PZ sidebar icon set.

Project Zomboid's left-hand sidebar ships FIVE variants of every icon, one per
sidebar-size option: media/ui/Sidebar/<W>/<Name>_<W>.png for W in
48/64/80/96/128, each SQUARE (verified: Admin_Icon_Off_128.png is 128x128).
ISEquippedItem picks the folder matching its current TEXTURE_WIDTH, so shipping a
single file means four of the five settings get a rescale. This generates the set.

Two things it does that a naive resize does not:

1. PREMULTIPLIED ALPHA. Transparent pixels still carry RGB, and AI-generated art
   routinely leaves them white - this master's corners are (254,254,254,0). A
   straight RGBA downscale averages those white values into the badge's edge
   pixels and you get a pale halo, worst exactly where it shows most (48px).
   Premultiplying before the resample and dividing back out afterwards keeps the
   edge colour honest.

2. FOOTPRINT NORMALISATION. Vanilla content fills 95.3% of its canvas (122 of
   128px). Art generated at 1024 typically sits smaller - this master filled
   77.9% - which renders a visibly runty badge next to CLIENT and ADMIN. We crop
   to the alpha bounding box, square it, then rescale so content occupies the
   same 95.3%. Pass --fill 1.0 to keep the art's own margins instead.

Note the badge is drawn into a 4:3 button (TEXTURE_HEIGHT = TEXTURE_WIDTH * 0.75)
but the art is square, same as vanilla: ISButton uses drawTextureScaledAspect, so
it fits without distorting. Square in, square out - do not pre-squash.

STATE PAIRS MUST SHARE A FRAME. An Off/On pair gets swapped in place by
setImage(), so any difference in scale or offset between them reads as the badge
jumping when the panel opens. Independently normalising each is exactly how that
happens: the two renders rarely have identical alpha bounds (measured here, the
green Off extended 839px tall and the red On only 804px, a 4.4% difference), so
each would be cropped and magnified by a different amount. Pass the sibling via
--align-with and the crop box becomes the UNION of both bounds, so both are
framed and scaled identically. Union is commutative, so running once per file
with the other named produces matching frames either way round.

Requires Pillow (not stdlib, unlike the rest of tools/):  pip install Pillow

Usage:
    python tools/make-sidebar-icon.py <master.png> <outdir> --name DF_Panel_Off
    # state pair - name each other so they stay aligned:
    python tools/make-sidebar-icon.py off.png <outdir> --name DF_Panel_Off --align-with on.png
    python tools/make-sidebar-icon.py on.png  <outdir> --name DF_Panel_On  --align-with off.png
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.exit("Pillow required:  pip install Pillow")

SIZES = (48, 64, 80, 96, 128)
VANILLA_FILL = 122 / 128  # measured from media/ui/Sidebar/128/Admin_Icon_Off_128.png


def premultiply(im):
    r, g, b, a = im.split()
    # ImageChops.multiply is (x*y)/255 per pixel - exactly premultiplication.
    return Image.merge("RGBA", (
        ImageChops.multiply(r, a),
        ImageChops.multiply(g, a),
        ImageChops.multiply(b, a),
        a,
    ))


def unpremultiply(im):
    """Divide RGB back out by alpha. Runs on the already-downscaled image, so this
    pure-Python pass is over at most 128x128 px."""
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                # Zero the RGB of fully transparent pixels so no future resize can
                # reintroduce a halo from them - the exact bug this script exists for.
                px[x, y] = (0, 0, 0, 0)
            elif a < 255:
                s = 255 / a
                px[x, y] = (min(255, int(r * s + 0.5)),
                            min(255, int(g * s + 0.5)),
                            min(255, int(b * s + 0.5)), a)
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("master", type=Path)
    ap.add_argument("outdir", type=Path)
    ap.add_argument("--name", required=True,
                    help="basename; files land as <outdir>/<W>/<name>_<W>.png")
    ap.add_argument("--fill", type=float, default=VANILLA_FILL,
                    help=f"content fraction of canvas (default {VANILLA_FILL:.3f}, vanilla-matched)")
    ap.add_argument("--align-with", action="append", default=[], type=Path,
                    metavar="PNG",
                    help="sibling state art to share a crop frame with (repeatable); "
                         "prevents the badge jumping when the two are swapped")
    args = ap.parse_args()

    im = Image.open(args.master).convert("RGBA")
    print(f"master: {im.size[0]}x{im.size[1]}")

    bbox = im.getchannel("A").getbbox()
    if bbox is None:
        sys.exit("master is fully transparent")

    # Union in each sibling's bounds so every state of this icon is cropped and
    # scaled identically - see STATE PAIRS in the header.
    for sib in args.align_with:
        sim = Image.open(sib).convert("RGBA")
        if sim.size != im.size:
            sys.exit(f"--align-with {sib} is {sim.size[0]}x{sim.size[1]}, "
                     f"master is {im.size[0]}x{im.size[1]}; a shared frame needs a shared canvas")
        sbb = sim.getchannel("A").getbbox()
        if sbb is None:
            continue
        bbox = (min(bbox[0], sbb[0]), min(bbox[1], sbb[1]),
                max(bbox[2], sbb[2]), max(bbox[3], sbb[3]))
        print(f"union with {sib.name}: bbox now {bbox}")

    im = im.crop(bbox)
    cw, ch = im.size
    print(f"cropped to shared frame: {cw}x{ch}")

    # Square on the longer edge, content centred, so nothing is stretched.
    side = max(cw, ch)
    if (cw, ch) != (side, side):
        sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        sq.paste(im, ((side - cw) // 2, (side - ch) // 2))
        im = sq
        print(f"squared to {side}x{side}")

    pm = premultiply(im)

    for w in SIZES:
        inner = max(1, round(w * args.fill))
        small = pm.resize((inner, inner), Image.LANCZOS)
        small = unpremultiply(small)

        canvas = Image.new("RGBA", (w, w), (0, 0, 0, 0))
        off = ((w - inner) // 2, (w - inner) // 2)
        canvas.paste(small, off)

        d = args.outdir / str(w)
        d.mkdir(parents=True, exist_ok=True)
        out = d / f"{args.name}_{w}.png"
        canvas.save(out, "PNG", optimize=True)
        print(f"  {out}  canvas={w}x{w} content={inner}x{inner} "
              f"fill={inner / w:.1%} bytes={out.stat().st_size}")


if __name__ == "__main__":
    main()
