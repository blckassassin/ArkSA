#!/usr/bin/env python3
"""Generate the repository icon: a hex-cut island with a red obelisk.

Drawn as pixel art on a 32x32 grid, then exported two ways from the one source:

  icon.png  256x256, upscaled with NEAREST so the pixels stay hard-edged
  icon.svg  one <rect> per run of same-coloured pixels, crisp at any size

Usage:  python3 tools/icongen/build.py [--preview]

Light source is top-left, so left faces are lighter and right faces darker.
"""
from __future__ import annotations

import os
import sys

from PIL import Image

S = 32                      # grid size, in pixels
PNG_SIZE = 256              # exported raster size
CORNER_R = 5                # background corner radius, in grid pixels

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------
BG_TOP     = (0x1a, 0x24, 0x33)
BG_BOT     = (0x0b, 0x11, 0x18)

GRASS_LIT  = (0x6a, 0xb5, 0x6b)
GRASS      = (0x4d, 0x93, 0x53)
GRASS_DARK = (0x37, 0x6e, 0x3f)

ROCK_LIT   = (0x8a, 0x74, 0x58)
ROCK       = (0x6b, 0x59, 0x43)
ROCK_DARK  = (0x49, 0x3b, 0x2c)

OBEL_LIT   = (0xff, 0x7b, 0x6b)
OBEL       = (0xd9, 0x3d, 0x3d)
OBEL_DARK  = (0xa6, 0x2b, 0x2e)

GLOW       = (0xff, 0x5a, 0x46)


def blend(a, b, t):
    """Linear blend from a to b by t in [0,1]."""
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


# ---------------------------------------------------------------------------
# Geometry
#
# A flat-top hexagon squashed into a low iso view: flat top and bottom edges,
# pointy left and right, so the silhouette still reads as a hex at 16px.
# Each entry is the inclusive x span of one row of the grass face.
# ---------------------------------------------------------------------------
HEX_TOP_Y = 17
HEX_ROWS = [
    (10, 21),   # y=17, flat top edge
    (8, 23),
    (6, 25),
    (4, 27),
    (3, 28),    # y=21, widest — the left and right points
    (4, 27),
    (6, 25),
    (8, 23),
    (10, 21),   # y=25, flat bottom edge
]
SLAB_DEPTH = 6   # rows of rock below the grass

# Obelisk: a stepped spire centred on x=16. Odd widths only, so it tapers to a
# single-pixel point at the tip and both edges step outward one pixel at a
# time. A continuous taper cannot be drawn honestly at 32px; clean tiers can.
OBELISK_TIP_Y = 2
OBELISK_BASE_Y = 21
OBELISK_TIERS = [(2, 5, 1), (6, 12, 3), (13, 21, 5)]   # y0, y1, width
OBELISK_ROWS = {}
for _y0, _y1, _w in OBELISK_TIERS:
    for _y in range(_y0, _y1 + 1):
        OBELISK_ROWS[_y] = (16 - _w // 2, 16 + _w // 2)


def in_background(x: int, y: int) -> bool:
    """Rounded-square mask for the icon plate."""
    for cx, cy in ((CORNER_R, CORNER_R), (S - 1 - CORNER_R, CORNER_R),
                   (CORNER_R, S - 1 - CORNER_R), (S - 1 - CORNER_R, S - 1 - CORNER_R)):
        if ((x < CORNER_R and cx == CORNER_R) or (x > S - 1 - CORNER_R and cx != CORNER_R)) and \
           ((y < CORNER_R and cy == CORNER_R) or (y > S - 1 - CORNER_R and cy != CORNER_R)):
            if (x - cx) ** 2 + (y - cy) ** 2 > CORNER_R ** 2 + CORNER_R:
                return False
    return True


def build_grid():
    """Return a 32x32 grid of RGBA tuples (alpha 0 = transparent)."""
    g = [[(0, 0, 0, 0) for _ in range(S)] for _ in range(S)]

    def put(x, y, rgb, a=255):
        if 0 <= x < S and 0 <= y < S:
            g[y][x] = (rgb[0], rgb[1], rgb[2], a)

    # --- background plate, subtle vertical gradient -------------------------
    for y in range(S):
        row = blend(BG_TOP, BG_BOT, y / (S - 1))
        for x in range(S):
            if in_background(x, y):
                put(x, y, row)

    # --- rock slab, drawn first so the grass sits on top --------------------
    # For each column, find the lowest grass row, then extrude downward.
    bottom = {}
    for i, (x0, x1) in enumerate(HEX_ROWS):
        for x in range(x0, x1 + 1):
            bottom[x] = HEX_TOP_Y + i
    for x, y_bot in bottom.items():
        # Taper the slab at the pointy left/right tips so it reads as a solid.
        edge = min(x - 3, 28 - x)
        depth = min(SLAB_DEPTH, edge + 1)
        for d in range(1, depth + 1):
            if x <= 11:
                c = ROCK_LIT
            elif x >= 22:
                c = ROCK_DARK
            else:
                c = ROCK
            # darken toward the underside
            c = blend(c, ROCK_DARK, min(1.0, d / (SLAB_DEPTH + 1)))
            put(x, y_bot + d, c)

    # --- grass top face -----------------------------------------------------
    for i, (x0, x1) in enumerate(HEX_ROWS):
        y = HEX_TOP_Y + i
        for x in range(x0, x1 + 1):
            # Light from top-left across the face.
            t = ((x - 3) / 25.0) * 0.55 + (i / 8.0) * 0.45
            c = blend(GRASS_LIT, GRASS_DARK, t)
            put(x, y, c)
        # Bright rim along the top-left edge.
        if i <= 4:
            put(x0, y, GRASS_LIT)
            put(x0 + 1, y, blend(GRASS_LIT, GRASS, 0.4))

    # --- obelisk ------------------------------------------------------------
    # Two faces split down the middle, so the spire reads as faceted stone
    # rather than a flat bar. Brighter toward the tip, as if lit from within.
    for y, (x0, x1) in sorted(OBELISK_ROWS.items()):
        w = x1 - x0 + 1
        mid = x0 + (w - 1) // 2
        glow_t = 1.0 - (y - OBELISK_TIP_Y) / (OBELISK_BASE_Y - OBELISK_TIP_Y)
        for x in range(x0, x1 + 1):
            if x == x0:
                c = OBEL_LIT
            elif x <= mid:
                c = OBEL
            else:
                c = OBEL_DARK
            put(x, y, blend(c, OBEL_LIT, glow_t * 0.35))

    # --- glow: blend everything near the obelisk toward the emissive red ----
    obel_px = [(x, y) for y, (x0, x1) in OBELISK_ROWS.items() for x in range(x0, x1 + 1)]
    for y in range(S):
        for x in range(S):
            if g[y][x][3] == 0 or (x, y) in obel_px:
                continue
            d2 = min((x - ox) ** 2 + (y - oy) ** 2 for ox, oy in obel_px)
            if d2 <= 4:
                t = 0.34 if d2 <= 1 else 0.16
                r, gr, b, a = g[y][x]
                g[y][x] = (*blend((r, gr, b), GLOW, t), a)

    return g


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
def write_png(grid, path, size=PNG_SIZE):
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for y in range(S):
        for x in range(S):
            im.putpixel((x, y), grid[y][x])
    im.resize((size, size), Image.NEAREST).save(path)
    return path


def write_svg(grid, path, label="Hex-cut island with a red obelisk"):
    """One <rect> per horizontal run of identical pixels."""
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" '
        f'width="{PNG_SIZE}" height="{PNG_SIZE}" shape-rendering="crispEdges" '
        f'role="img" aria-label="{label}">'
    ]
    for y in range(S):
        x = 0
        while x < S:
            c = grid[y][x]
            if c[3] == 0:
                x += 1
                continue
            run = 1
            while x + run < S and grid[y][x + run] == c:
                run += 1
            parts.append(
                f'<rect x="{x}" y="{y}" width="{run}" height="1" '
                f'fill="#{c[0]:02x}{c[1]:02x}{c[2]:02x}"/>'
            )
            x += run
    parts.append("</svg>")
    with open(path, "w") as fh:
        fh.write("\n".join(parts) + "\n")
    return path


def main():
    grid = build_grid()
    png = write_png(grid, os.path.join(ROOT, "icon.png"))
    svg = write_svg(grid, os.path.join(ROOT, "icon.svg"))
    print(f"  wrote {os.path.relpath(png, ROOT)} ({PNG_SIZE}x{PNG_SIZE})")
    print(f"  wrote {os.path.relpath(svg, ROOT)}")

    if "--preview" in sys.argv:
        # All the sizes the Apps list might render at, side by side.
        sizes = [16, 24, 32, 48, 64, 128]
        pad = 4
        sheet = Image.new("RGBA", (sum(sizes) + pad * (len(sizes) + 1),
                                   max(sizes) + pad * 2), (24, 24, 28, 255))
        src = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        for y in range(S):
            for x in range(S):
                src.putpixel((x, y), grid[y][x])
        ox = pad
        for s in sizes:
            sheet.paste(src.resize((s, s), Image.NEAREST), (ox, pad), src.resize((s, s), Image.NEAREST))
            ox += s + pad
        p = os.path.join(os.path.dirname(__file__), "preview.png")
        sheet.save(p)
        print(f"  wrote {os.path.relpath(p, ROOT)}")


if __name__ == "__main__":
    main()
