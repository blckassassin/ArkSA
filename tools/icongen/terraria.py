#!/usr/bin/env python3
"""Generate the Terraria icon: a green hill under a blue sky with a tree.

Same 32x32 pixel-art approach as build.py, whose writers (and background
plate / blend helpers) we reuse directly.
Outputs terraria.png (256x256) and terraria.svg at the repo root.

Usage:  python3 tools/icongen/terraria.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from build import ROOT, S, blend, in_background, write_png, write_svg  # noqa: E402

# ---------------------------------------------------------------------------
# Palette. Light source top-left, same convention as build.py: left-facing
# surfaces are lighter, right-facing/lower ones darker.
# ---------------------------------------------------------------------------
SKY_TOP    = (0x6e, 0xc6, 0xf0)
SKY_BOT    = (0xc9, 0xec, 0xfa)

HILL_LIT   = (0x7b, 0xc4, 0x7f)
HILL       = (0x4c, 0x9a, 0x54)
HILL_DARK  = (0x2f, 0x6e, 0x37)

TRUNK_LIT  = (0x8a, 0x5a, 0x34)
TRUNK_DARK = (0x5c, 0x3a, 0x21)

LEAF_LIT   = (0x3f, 0x8f, 0x46)
LEAF_DARK  = (0x1a, 0x49, 0x22)

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
HILL_MIN_Y = 15   # crest, at the center column
HILL_MAX_Y = 27   # where the hill meets the canvas edge

TREE_X = 10        # trunk sits left of center
TRUNK_HEIGHT = 4
CANOPY_R = 5


def hill_top(x: int) -> int:
    """Row where the hill's grass surface starts at column x (a shallow
    parabola, tallest at the center, tapering to the sides)."""
    t = ((x - 16) / 16.0) ** 2
    return HILL_MIN_Y + round((HILL_MAX_Y - HILL_MIN_Y) * min(1.0, t))


def build_grid():
    """Return a 32x32 grid of RGBA tuples (alpha 0 = transparent)."""
    g = [[(0, 0, 0, 0) for _ in range(S)] for _ in range(S)]

    def put(x, y, rgb, a=255):
        if 0 <= x < S and 0 <= y < S:
            g[y][x] = (rgb[0], rgb[1], rgb[2], a)

    # --- sky, subtle vertical gradient, same rounded plate as build.py ------
    for y in range(S):
        row = blend(SKY_TOP, SKY_BOT, y / (S - 1))
        for x in range(S):
            if in_background(x, y):
                put(x, y, row)

    # --- hill: a mound, lit top-left, darker toward the bottom-right --------
    for x in range(S):
        top = hill_top(x)
        for y in range(top, S):
            if not in_background(x, y):
                continue
            shade = (x / 31.0) * 0.5 + ((y - HILL_MIN_Y) / (HILL_MAX_Y - HILL_MIN_Y)) * 0.5
            put(x, y, blend(HILL_LIT, HILL_DARK, min(1.0, shade)))
        # Bright rim along the top-left-facing slope.
        if x < 16:
            put(x, top, blend(HILL_LIT, HILL, 0.15))

    # --- tree trunk, planted on the hill at TREE_X ---------------------------
    trunk_base = hill_top(TREE_X)
    trunk_top = trunk_base - TRUNK_HEIGHT
    for y in range(trunk_top, trunk_base + 1):
        put(TREE_X, y, TRUNK_LIT)
        put(TREE_X + 1, y, TRUNK_DARK)

    # --- canopy: a round blob of leaves above the trunk ----------------------
    cx, cy = TREE_X, trunk_top - 1
    for dy in range(-CANOPY_R, CANOPY_R + 1):
        for dx in range(-CANOPY_R, CANOPY_R + 1):
            if dx * dx + dy * dy > CANOPY_R * CANOPY_R:
                continue
            x, y = cx + dx, cy + dy
            # Light from top-left across the canopy's surface.
            t = (dx + dy + CANOPY_R) / (2 * CANOPY_R)
            put(x, y, blend(LEAF_LIT, LEAF_DARK, min(1.0, max(0.0, t))))
    # A couple of bright highlight pixels, upper-left of the canopy center.
    put(cx - 2, cy - 2, LEAF_LIT)
    put(cx - 1, cy - 3, LEAF_LIT)

    return g


def main():
    grid = build_grid()
    png = write_png(grid, os.path.join(ROOT, "terraria.png"))
    svg = write_svg(grid, os.path.join(ROOT, "terraria.svg"),
                     label="Green hill under a blue sky with a tree")
    print(f"  wrote {os.path.relpath(png, ROOT)}")
    print(f"  wrote {os.path.relpath(svg, ROOT)}")


if __name__ == "__main__":
    main()
