#!/usr/bin/env python3
"""make-growl-sprites.py - generate the Growl sprite set for the Dragonfly deck.

Six PNGs, and the design rule they encode: sprites carry SHAPE ONLY. Every
pixel is pure white; the alpha channel is the geometry. Color arrives at draw
time via drawTextureScaled's tint args (vanilla ISUIElement.lua:1032 ->
UIElement.DrawTextureScaledCol, UIElement.java:384), so the entire skin - and
any future reskin - iterates in DFTheme.lua without ever regenerating these.

RGB stays 255 everywhere INCLUDING fully transparent pixels, on the lesson
recorded in make-sidebar-icon.py: resampling averages the RGB of transparent
neighbours into edge pixels, and if those are anything but the sprite's own
color you get a fringe. All-white sprites cannot fringe.

The set (media/ui/Growl/):
  cnr_tl/tr/bl/br.png  32px quarter discs, 4x supersampled AA. Drawn scaled to
                       radius r they become DFTheme.roundRect's corners.
  glow.png             160px radial falloff, for the ONE glow the rules allow
                       (armed hover) plus soft shadow duty if a surface earns it.
  noise.png            140px film grain tile; alpha noise drawn at ~4%.
  vein.png             148x560 wing-venation strip for the roster background -
                       the mark's texture, grown as branching random walks.
                       Seeded, so the wing is the same wing on every rebuild.

Run: python tools/make-growl-sprites.py   (writes into the mod tree, idempotent)
"""

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / (
    "RequiemOfTheDead/Contents/mods/Dragonfly/42/media/ui/Growl"
)

WHITE = (255, 255, 255)


def save(img, name):
    OUT.mkdir(parents=True, exist_ok=True)
    img.save(OUT / name, "PNG")
    print(f"  {name}  {img.size[0]}x{img.size[1]}")


def corner(size=32, ss=4):
    """Quarter disc, arc centre at the bottom-right corner: that is the
    top-left corner sprite; the other three are flips."""
    big = size * ss
    a = Image.new("L", (big, big), 0)
    px = a.load()
    for y in range(big):
        for x in range(big):
            # distance from the arc centre (big, big); inside = opaque
            d = math.hypot(big - x, big - y)
            if d <= big - ss:
                px[x, y] = 255
            elif d <= big:
                px[x, y] = int(255 * (big - d) / ss)
    a = a.resize((size, size), Image.LANCZOS)
    img = Image.new("RGBA", (size, size), WHITE + (0,))
    img.putalpha(a)
    return img


def glow(size=160):
    a = Image.new("L", (size, size), 0)
    px = a.load()
    c = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - c, y - c) / c
            if d < 1:
                px[x, y] = int(255 * (1 - d) ** 2.5)
    img = Image.new("RGBA", (size, size), WHITE + (0,))
    img.putalpha(a)
    return img


def noise(size=140, seed=42):
    rng = random.Random(seed)
    a = Image.new("L", (size, size), 0)
    px = a.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = rng.randrange(256)
    img = Image.new("RGBA", (size, size), WHITE + (0,))
    img.putalpha(a)
    return img


def vein(w=148, h=560, seed=7):
    """Branching walks downward - the wing. Alpha is kept moderate; the
    roster draws this at low tint alpha so it reads as texture, not lines."""
    rng = random.Random(seed)
    img = Image.new("RGBA", (w, h), WHITE + (0,))
    d = ImageDraw.Draw(img)

    def walk(x, y, angle, life, alpha):
        while life > 0 and 0 <= y <= h + 10:
            angle += (rng.random() - 0.5) * 0.7
            nx = x + math.cos(angle) * 9
            ny = y + math.sin(angle) * 9
            d.line([(x, y), (nx, ny)], fill=WHITE + (alpha,), width=1)
            x, y = nx, ny
            life -= 1
            if rng.random() < 0.16 and life > 6:
                walk(x, y, angle + (0.9 if rng.random() < 0.5 else -0.9),
                     int(life * 0.5), max(60, int(alpha * 0.75)))

    for _ in range(9):
        walk(rng.random() * w, -8, math.pi / 2 + (rng.random() - 0.5) * 0.6,
             int(30 + rng.random() * 35), 170)
    return img


def main():
    print(f"Growl sprites -> {OUT}")
    tl = corner()
    save(tl, "cnr_tl.png")
    save(tl.transpose(Image.FLIP_LEFT_RIGHT), "cnr_tr.png")
    save(tl.transpose(Image.FLIP_TOP_BOTTOM), "cnr_bl.png")
    save(tl.transpose(Image.ROTATE_180), "cnr_br.png")
    save(glow(), "glow.png")
    save(noise(), "noise.png")
    save(vein(), "vein.png")
    print("done.")


if __name__ == "__main__":
    main()
