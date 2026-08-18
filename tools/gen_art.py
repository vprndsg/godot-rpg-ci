#!/usr/bin/env python3
"""Regenerate the project's pixel art from code.

    python3 tools/gen_art.py

Writes assets/tiles/terrain.png and assets/sprites/actors.png. Everything is
deterministic, so re-running produces byte-identical files and an unchanged
diff. Art lives in code so Claude can extend it headlessly: add a draw_* here,
add the tile to assets/tiles/tiles.json, re-run this, then re-run
tools/build_tileset.gd.

Standard library only -- no Pillow, nothing to install. The canvas, palette
and PNG writer live in tools/pixel.py, which the contact-sheet and map
renderers share.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pixel import ROOT, Canvas, CLEAR, P, noise, rgb  # noqa: F401  (rgb/CLEAR used by painters)

TS = 16  # tile size


# --------------------------------------------------------------------------
# tile painters -- each fills a 16x16 cell at (ox, oy)
# --------------------------------------------------------------------------

def speckle(c, ox, oy, base, hi, lo, density=0.18, salt=0):
    c.rect(ox, oy, TS, TS, base)
    for y in range(TS):
        for x in range(TS):
            n = noise(ox + x, oy + y, salt)
            if n < density * 0.5:
                c.set(ox + x, oy + y, lo)
            elif n < density:
                c.set(ox + x, oy + y, hi)


def cast_shadow(c, ox, oy, cx, cy, rx, ry):
    """Dithered ellipse for props that sit over a separate ground layer."""
    for y in range(max(0, cy - ry), min(TS, cy + ry + 1)):
        for x in range(max(0, cx - rx), min(TS, cx + rx + 1)):
            dx = (x - cx) / float(rx)
            dy = (y - cy) / float(ry)
            d = dx * dx + dy * dy
            if d <= 0.62:
                c.set(ox + x, oy + y, P["shadow"])
            elif d <= 1.0 and (x + y) % 2 == 0:
                c.set(ox + x, oy + y, P["shadow_soft"])


def t_grass(c, ox, oy):
    speckle(c, ox, oy, P["grass"], P["grass_hi"], P["grass_lo"], 0.10, 1)
    for x, y in ((2, 5), (11, 2), (7, 12)):
        c.set(ox + x, oy + y, P["grass_lo"])
        c.set(ox + x - 1, oy + y - 1, P["grass_hi"])
        c.set(ox + x + 1, oy + y - 1, P["grass_hi"])


def t_grass_flower(c, ox, oy):
    t_grass(c, ox, oy)
    for fx, fy, col in ((3, 4, rgb("e8d45a")), (10, 9, rgb("d96f9a")), (6, 12, rgb("e8e0f0"))):
        c.set(ox + fx, oy + fy, col)
        c.set(ox + fx + 1, oy + fy, col)
        c.set(ox + fx, oy + fy + 1, col)
        c.set(ox + fx + 1, oy + fy + 1, P["grass_lo"])


def t_dirt(c, ox, oy):
    speckle(c, ox, oy, P["dirt"], P["dirt_hi"], P["dirt_lo"], 0.14, 2)
    for x, y in ((3, 3), (10, 7), (6, 13)):
        c.hline(ox + x, oy + y, 2, P["dirt_lo"])


def t_stone_path(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["stone_lo"])
    # Rounded, salt-worn setts with recessed dark mortar.
    for (x, y, w, h) in ((0, 0, 6, 5), (7, 0, 9, 6), (0, 6, 8, 5),
                         (9, 7, 7, 4), (0, 12, 5, 4), (6, 12, 10, 4)):
        c.rect(ox + x + 1, oy + y, w - 1, h - 1, P["stone"])
        c.hline(ox + x + 2, oy + y, max(1, w - 3), P["stone_hi"])
        c.set(ox + x + w - 1, oy + y + h - 2, P["stone_lo"])


def t_water(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["water"])
    c.hline(ox, oy + 5, TS, P["water_lo"])
    c.hline(ox, oy + 12, TS, P["water_lo"])
    for x, y, w in ((1, 2, 6), (9, 4, 5), (4, 8, 8), (0, 14, 5), (11, 11, 4)):
        c.hline(ox + x, oy + y, w, P["water_hi"])
        if w >= 6:
            c.set(ox + x + 1, oy + y - 1, P["foam"])
            c.set(ox + x + w - 2, oy + y + 1, P["water_lo"])


def t_sand(c, ox, oy):
    speckle(c, ox, oy, P["sand"], P["sand_hi"], P["sand_lo"], 0.10, 4)
    for x, y in ((3, 12), (12, 4), (8, 8)):
        c.set(ox + x, oy + y, P["sand_lo"])
        c.set(ox + x + 1, oy + y, P["sand_hi"])


def t_shore(c, ox, oy):
    """Horizontal sea-to-sand edge used along Port Azure's north beach."""
    t_sand(c, ox, oy)
    edge = (6, 6, 7, 7, 6, 5, 5, 6, 6, 7, 7, 6, 5, 5, 6, 6)
    for x, depth in enumerate(edge):
        for y in range(depth):
            c.set(ox + x, oy + y, P["water"])
        c.set(ox + x, oy + depth - 2, P["water_hi"])
        c.set(ox + x, oy + depth - 1, P["foam"])
    c.hline(ox + 1, oy + 2, 5, P["water_hi"])
    c.hline(ox + 10, oy + 3, 4, P["water_lo"])


def t_dune_edge(c, ox, oy):
    """Horizontal sand-to-grass edge with an irregular windblown fringe."""
    t_grass(c, ox, oy)
    edge = (5, 5, 4, 4, 5, 6, 6, 5, 4, 4, 5, 6, 6, 5, 5, 5)
    for x, depth in enumerate(edge):
        for y in range(depth):
            c.set(ox + x, oy + y, P["sand"])
        c.set(ox + x, oy + depth - 1, P["sand_lo"])
    for x, y in ((2, 7), (7, 8), (13, 7)):
        c.set(ox + x, oy + y, P["grass_hi"])
        c.set(ox + x + 1, oy + y + 1, P["grass_lo"])


def t_tree(c, ox, oy):
    cast_shadow(c, ox, oy, 9, 13, 6, 2)
    c.rect(ox + 7, oy + 9, 3, 7, P["bark_lo"])
    c.vline(ox + 7, oy + 10, 5, P["bark"])
    # Wind-shaped coastal crown: dark silhouette, mid clumps, sunlit crown.
    for x, y, w, h in ((2, 5, 9, 7), (5, 2, 8, 8), (9, 5, 6, 6)):
        c.rect(ox + x, oy + y, w, h, P["leaf_lo"])
    for x, y, w, h in ((3, 4, 7, 6), (6, 2, 6, 6), (9, 5, 4, 4)):
        c.rect(ox + x, oy + y, w, h, P["leaf"])
    c.rect(ox + 5, oy + 3, 4, 2, P["leaf_hi"])
    c.rect(ox + 10, oy + 5, 3, 2, P["leaf_hi"])
    for x, y in ((2, 7), (4, 3), (8, 1), (13, 7), (11, 10)):
        c.set(ox + x, oy + y, CLEAR)


def t_bush(c, ox, oy):
    cast_shadow(c, ox, oy, 8, 13, 6, 2)
    c.rect(ox + 3, oy + 8, 11, 6, P["leaf_lo"])
    c.rect(ox + 5, oy + 6, 5, 7, P["leaf"])
    c.rect(ox + 9, oy + 7, 4, 5, P["leaf"])
    c.hline(ox + 5, oy + 7, 4, P["leaf_hi"])
    c.hline(ox + 10, oy + 8, 2, P["leaf_hi"])
    c.set(ox + 3, oy + 8, CLEAR)
    c.set(ox + 13, oy + 8, CLEAR)


def _planks(c, ox, oy, base, hi, lo, offset=0):
    """Long horizontal boards -- deliberately unlike the brick painter."""
    c.rect(ox, oy, TS, TS, base)
    for y in range(TS):
        for x in range(TS):
            n = noise(ox + x, oy + y, 8)
            if n > 0.90:
                c.set(ox + x, oy + y, hi)
            elif n < 0.06:
                c.set(ox + x, oy + y, lo)
    for y in (5, 11):
        c.hline(ox, oy + y, TS, lo)
        c.hline(ox, oy + y + 1, TS, hi)
    # one short butt-joint per tile, staggered by offset so floors tile without
    # lining up into a visible grid
    c.vline(ox + (offset + 6) % TS, oy, 5, lo)
    c.vline(ox + (offset + 13) % TS, oy + 12, 4, lo)


def t_wood_floor(c, ox, oy):
    _planks(c, ox, oy, P["wood"], P["wood_hi"], P["wood_lo"], 0)


def t_wood_floor_b(c, ox, oy):
    _planks(c, ox, oy, P["wood"], P["wood_hi"], P["wood_lo"], 7)


def t_stone_floor(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["stone_lo"])
    for gy in range(2):
        for gx in range(2):
            c.rect(ox + gx * 8 + 1, oy + gy * 8 + 1, 6, 6, P["stone"])
            c.hline(ox + gx * 8 + 1, oy + gy * 8 + 1, 6, P["stone_hi"])


def t_rug(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["rug"])
    c.rect(ox + 2, oy + 2, 12, 12, P["rug_hi"])
    c.rect(ox + 5, oy + 5, 6, 6, P["rug_lo"])
    for x in range(0, TS, 2):
        c.set(ox + x, oy, P["rug_lo"])
        c.set(ox + x, oy + TS - 1, P["rug_lo"])


def _bricks(c, ox, oy, base, hi, lo):
    c.rect(ox, oy, TS, TS, base)
    for row, y in enumerate((0, 4, 8, 12)):
        c.hline(ox, oy + y, TS, lo)
        off = 0 if row % 2 == 0 else 8
        c.vline(ox + off, oy + y, 4, lo)
        c.vline(ox + (off + 8) % TS, oy + y, 4, lo)
        c.hline(ox, oy + y + 1, TS, hi)


def t_wall_stone(c, ox, oy):
    _bricks(c, ox, oy, P["walls"], P["walls_hi"], P["walls_lo"])


def t_wall_wood(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["wallw"])
    for x in range(0, TS, 4):
        c.vline(ox + x, oy, TS, P["wallw_lo"])
        c.vline(ox + x + 1, oy, TS, P["wallw_hi"])
    c.hline(ox, oy + 7, TS, P["wallw_lo"])


def t_wall_top(c, ox, oy):
    _bricks(c, ox, oy, P["walls_lo"], P["walls"], P["dark"])
    c.hline(ox, oy, TS, P["walls_hi"])


def t_roof(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["roof_lo"])
    for row, y in enumerate((0, 5, 10, 15)):
        off = 0 if row % 2 == 0 else 3
        for x in range(-off, TS, 6):
            c.rect(ox + x, oy + y, 5, 4, P["roof"])
            c.hline(ox + x + 1, oy + y, 3, P["roof_hi"])
            c.set(ox + x + 4, oy + y + 3, P["roof_lo"])


def t_door(c, ox, oy):
    t_wall_wood(c, ox, oy)
    c.rect(ox + 3, oy + 2, 10, 14, P["wood_lo"])
    c.rect(ox + 4, oy + 3, 8, 13, P["wood"])
    c.vline(ox + 8, oy + 3, 13, P["wood_lo"])
    c.set(ox + 10, oy + 9, P["metal"])
    c.set(ox + 10, oy + 10, P["metal_lo"])


def t_stairs_up(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["stone_lo"])
    for i, y in enumerate((12, 8, 4, 0)):
        c.rect(ox + i, oy + y, TS - i, 4, P["stone"])
        c.hline(ox + i, oy + y, TS - i, P["stone_hi"])
        c.hline(ox + i, oy + y + 3, TS - i, P["stone_lo"])


def t_stairs_down(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["stone"])
    for i, y in enumerate((0, 4, 8, 12)):
        c.rect(ox + i, oy + y, TS - i * 2, 4, P["stone_lo"] if i % 2 else P["stone"])
        c.hline(ox + i, oy + y, TS - i * 2, P["dark"])
    c.rect(ox + 6, oy + 12, 4, 4, P["black"])


def t_counter(c, ox, oy):
    cast_shadow(c, ox, oy, 8, 14, 7, 2)
    c.rect(ox, oy + 2, TS, 12, P["wood_lo"])
    c.rect(ox, oy + 2, TS, 3, P["wood_hi"])
    c.hline(ox, oy + 5, TS, P["wood"])
    c.hline(ox, oy + 13, TS, P["dark"])
    for x in range(2, TS, 5):
        c.vline(ox + x, oy + 6, 7, P["wood"])


def t_table(c, ox, oy):
    cast_shadow(c, ox, oy, 8, 13, 7, 2)
    c.rect(ox + 1, oy + 3, 14, 9, P["wood_lo"])
    c.rect(ox + 2, oy + 4, 12, 6, P["wood_hi"])
    c.hline(ox + 2, oy + 4, 12, P["cloth"])
    c.rect(ox + 3, oy + 12, 2, 3, P["wood_lo"])
    c.rect(ox + 11, oy + 12, 2, 3, P["wood_lo"])


def t_chair(c, ox, oy):
    cast_shadow(c, ox, oy, 8, 13, 4, 2)
    c.rect(ox + 4, oy + 3, 8, 8, P["wood_lo"])
    c.rect(ox + 5, oy + 4, 6, 3, P["wood_hi"])
    c.rect(ox + 4, oy + 11, 2, 3, P["wood_lo"])
    c.rect(ox + 10, oy + 11, 2, 3, P["wood_lo"])


def t_bed(c, ox, oy):
    cast_shadow(c, ox, oy, 8, 14, 7, 2)
    c.rect(ox + 1, oy + 1, 14, 14, P["wood_lo"])
    c.rect(ox + 2, oy + 2, 12, 12, P["cloth"])
    c.rect(ox + 2, oy + 2, 12, 4, rgb("e8e6de"))
    c.rect(ox + 3, oy + 7, 10, 7, P["rug"])
    c.hline(ox + 3, oy + 7, 10, P["rug_hi"])


def t_fireplace(c, ox, oy):
    _bricks(c, ox, oy, P["walls"], P["walls_hi"], P["walls_lo"])
    c.rect(ox + 3, oy + 5, 10, 11, P["black"])
    c.rect(ox + 4, oy + 10, 8, 6, P["fire_lo"])
    c.rect(ox + 5, oy + 11, 6, 5, P["fire"])
    c.rect(ox + 6, oy + 13, 4, 3, P["fire_hi"])
    c.hline(ox + 2, oy + 4, 12, P["stone_hi"])


def t_barrel(c, ox, oy):
    cast_shadow(c, ox, oy, 9, 14, 6, 2)
    # dark rim first so the barrel separates from a wooden floor behind it
    c.rect(ox + 2, oy + 1, 12, 15, P["dark"])
    c.rect(ox + 3, oy + 2, 10, 13, P["bark"])
    c.rect(ox + 4, oy + 3, 8, 11, P["wood"])
    c.vline(ox + 5, oy + 3, 11, P["wood_hi"])
    c.vline(ox + 8, oy + 3, 11, P["wood_lo"])
    c.rect(ox + 3, oy + 5, 10, 2, P["metal"])
    c.hline(ox + 3, oy + 6, 10, P["metal_lo"])
    c.rect(ox + 3, oy + 11, 10, 2, P["metal"])
    c.hline(ox + 3, oy + 12, 10, P["metal_lo"])
    c.rect(ox + 4, oy + 1, 8, 3, P["bark_lo"])
    c.rect(ox + 5, oy + 2, 6, 1, P["wood_hi"])


def t_crate(c, ox, oy):
    cast_shadow(c, ox, oy, 9, 14, 6, 2)
    c.rect(ox + 2, oy + 3, 12, 12, P["wood_lo"])
    c.rect(ox + 3, oy + 4, 10, 10, P["wood"])
    for i in range(10):
        c.set(ox + 3 + i, oy + 4 + i, P["wood_hi"])
        c.set(ox + 12 - i, oy + 4 + i, P["wood_hi"])


def t_sign(c, ox, oy):
    cast_shadow(c, ox, oy, 9, 14, 5, 2)
    c.rect(ox + 7, oy + 8, 2, 8, P["bark"])
    c.rect(ox + 2, oy + 3, 12, 7, P["wood_lo"])
    c.rect(ox + 3, oy + 4, 10, 5, P["wood_hi"])
    c.hline(ox + 4, oy + 5, 8, P["bark_lo"])
    c.hline(ox + 4, oy + 7, 6, P["bark_lo"])


def t_window(c, ox, oy):
    t_wall_wood(c, ox, oy)
    c.rect(ox + 2, oy + 3, 12, 10, P["wood_lo"])
    c.rect(ox + 3, oy + 4, 10, 8, P["glass"])
    c.rect(ox + 3, oy + 4, 5, 4, P["glass_hi"])
    c.vline(ox + 8, oy + 4, 8, P["wood_lo"])
    c.hline(ox + 3, oy + 8, 10, P["wood_lo"])


def t_fence(c, ox, oy):
    cast_shadow(c, ox, oy, 8, 14, 7, 2)
    c.rect(ox + 1, oy + 4, 2, 11, P["wood_lo"])
    c.rect(ox + 12, oy + 4, 2, 11, P["wood_lo"])
    c.rect(ox, oy + 6, TS, 2, P["wood"])
    c.rect(ox, oy + 11, TS, 2, P["wood"])
    c.hline(ox, oy + 6, TS, P["wood_hi"])


def t_lamp(c, ox, oy):
    cast_shadow(c, ox, oy, 9, 14, 4, 2)
    c.rect(ox + 7, oy + 6, 2, 10, P["metal_lo"])
    c.rect(ox + 5, oy + 1, 6, 6, P["metal"])
    c.rect(ox + 6, oy + 2, 4, 4, P["fire_hi"])
    c.set(ox + 7, oy + 3, rgb("fff3c4"))
    c.rect(ox + 5, oy, 6, 1, P["metal_lo"])


def t_shelf(c, ox, oy):
    t_wall_wood(c, ox, oy)
    c.rect(ox, oy + 2, TS, 12, P["wood_lo"])
    for y in (3, 9):
        c.hline(ox, oy + y + 4, TS, P["wood"])
        for i, x in enumerate(range(1, 14, 3)):
            col = (P["glass"], P["fire"], P["leaf_hi"], P["rug_hi"], P["cloth"])[i % 5]
            c.rect(ox + x, oy + y, 2, 4, col)
            c.set(ox + x, oy + y, P["dark"])


def t_void(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["black"])
    for y in range(TS):
        for x in range(TS):
            if noise(ox + x, oy + y, 11) > 0.97:
                c.set(ox + x, oy + y, P["dark"])


PAINTERS = {
    "grass": t_grass, "grass_flower": t_grass_flower, "dirt": t_dirt,
    "stone_path": t_stone_path, "water": t_water, "sand": t_sand,
    "shore": t_shore, "dune_edge": t_dune_edge,
    "tree": t_tree, "bush": t_bush,
    "wood_floor": t_wood_floor, "wood_floor_b": t_wood_floor_b,
    "stone_floor": t_stone_floor, "rug": t_rug, "wall_stone": t_wall_stone,
    "wall_wood": t_wall_wood, "wall_top": t_wall_top, "roof": t_roof,
    "door": t_door, "stairs_up": t_stairs_up, "stairs_down": t_stairs_down,
    "counter": t_counter, "table": t_table, "chair": t_chair, "bed": t_bed,
    "fireplace": t_fireplace,
    "barrel": t_barrel, "crate": t_crate, "sign": t_sign, "window": t_window,
    "fence": t_fence, "lamp": t_lamp, "shelf": t_shelf, "void": t_void,
}


def build_terrain():
    reg = json.load(open(os.path.join(ROOT, "assets/tiles/tiles.json")))
    cols = reg["atlas_columns"]
    rows = max(t["atlas"][1] for t in reg["tiles"].values()) + 1
    c = Canvas(cols * TS, rows * TS)

    missing = sorted(set(reg["tiles"]) - set(PAINTERS))
    if missing:
        raise SystemExit("tiles.json lists tiles with no painter here: %s" % ", ".join(missing))

    for name, info in reg["tiles"].items():
        ax, ay = info["atlas"]
        PAINTERS[name](c, ax * TS, ay * TS)
    c.save(os.path.join(ROOT, "assets/tiles/terrain.png"))


# --------------------------------------------------------------------------
# actor sprite sheet: 16x24 frames, 4 frames per row, 4 rows (dirs) per actor
# rows are down, left, right, up -- see ACTORS for the row block order
# --------------------------------------------------------------------------

FRAME_W, FRAME_H = 16, 24

ACTORS = [
    # name,          skin,     hair,     shirt,    pants,    accent
    ("player",       "e2ad7f", "50382d", "356f88", "2f4056", "c76b42"),
    ("bartender",    "d89b6b", "7b3d2d", "8b5a3c", "4d4038", "e0c99b"),
    ("harbormaster", "ca8f62", "ded8c8", "365f50", "333f4a", "d2a84b"),
    ("villager",     "e8b78d", "49342e", "7d557c", "453d42", "4f8d82"),
]


def draw_actor(c, ox, oy, role, dir_idx, frame, skin, hair, shirt, pants, accent):
    S, H, SH, PA, AC = rgb(skin), rgb(hair), rgb(shirt), rgb(pants), rgb(accent)
    HD = tuple(max(0, v - 30) for v in H[:3]) + (255,)
    SHD = tuple(max(0, v - 35) for v in SH[:3]) + (255,)
    OUT = P["dark"]

    # feet bob: frames 1 and 3 are the two walk poses
    swing = (0, 1, 0, -1)[frame]

    # shadow
    for x in range(4, 12):
        c.set(ox + x, oy + 22, P["shadow"])
    for x in range(3, 13):
        c.set(ox + x, oy + 21, P["shadow"])

    # legs
    c.rect(ox + 5, oy + 16, 3, 5 + swing, PA)
    c.rect(ox + 8, oy + 16, 3, 5 - swing, PA)
    c.rect(ox + 5, oy + 20 + swing, 3, 1, OUT)
    c.rect(ox + 8, oy + 20 - swing, 3, 1, OUT)

    # torso
    c.rect(ox + 4, oy + 10, 8, 7, SH)
    c.rect(ox + 4, oy + 10, 8, 1, SHD)
    c.vline(ox + 3, oy + 11, 5, SHD)
    c.vline(ox + 12, oy + 11, 5, SHD)

    # arms
    c.rect(ox + 3, oy + 11 - min(0, swing), 2, 5, S)
    c.rect(ox + 11, oy + 11 + min(0, swing), 2, 5, S)

    # head
    c.rect(ox + 4, oy + 3, 8, 8, S)
    c.rect(ox + 3, oy + 4, 1, 6, S)
    c.rect(ox + 12, oy + 4, 1, 6, S)

    if dir_idx == 3:  # up -- back of head, no face
        c.rect(ox + 3, oy + 2, 10, 7, H)
        c.rect(ox + 3, oy + 2, 10, 2, HD)
    else:
        c.rect(ox + 3, oy + 2, 10, 3, H)
        c.rect(ox + 3, oy + 2, 10, 1, HD)
        c.vline(ox + 3, oy + 4, 3, H)
        c.vline(ox + 12, oy + 4, 3, H)
        if dir_idx == 0:  # down -- both eyes
            c.set(ox + 6, oy + 7, OUT)
            c.set(ox + 10, oy + 7, OUT)
            c.set(ox + 8, oy + 9, tuple(max(0, v - 40) for v in S[:3]) + (255,))
        elif dir_idx == 1:  # left profile
            c.set(ox + 5, oy + 7, OUT)
            c.set(ox + 4, oy + 9, tuple(max(0, v - 40) for v in S[:3]) + (255,))
            c.vline(ox + 12, oy + 3, 5, HD)
        else:  # right profile
            c.set(ox + 10, oy + 7, OUT)
            c.set(ox + 11, oy + 9, tuple(max(0, v - 40) for v in S[:3]) + (255,))
            c.vline(ox + 3, oy + 3, 5, HD)

    # Occupation-specific shapes make NPCs readable before dialogue opens.
    if role == "player":
        c.hline(ox + 5, oy + 10, 6, AC)  # rust scarf
        if dir_idx in (0, 2):
            c.vline(ox + 10, oy + 11, 5, AC)  # satchel strap
        elif dir_idx == 1:
            c.vline(ox + 5, oy + 11, 5, AC)
        c.set(ox + 11, oy + 16, AC)
    elif role == "bartender":
        c.hline(ox + 5, oy + 10, 6, AC)
        c.rect(ox + 6, oy + 11, 4, 6, AC)  # pale apron
        c.vline(ox + 9, oy + 12, 5, P["cloth"])
    elif role == "harbormaster":
        c.hline(ox + 4, oy + 2, 8, PA)  # square navy watch cap
        c.hline(ox + 5, oy + 1, 6, PA)
        if dir_idx != 3:
            c.hline(ox + 5, oy + 9, 6, H)  # white beard
            c.hline(ox + 6, oy + 10, 4, H)
        c.set(ox + 10, oy + 12, AC)  # brass badge
    elif role == "villager":
        c.rect(ox + 11, oy + 3, 2, 3, AC)  # sea-green hair ribbon
        c.hline(ox + 4, oy + 15, 8, AC)


def build_actors():
    rows = len(ACTORS) * 4
    c = Canvas(4 * FRAME_W, rows * FRAME_H)
    for a, (name, skin, hair, shirt, pants, accent) in enumerate(ACTORS):
        for d in range(4):
            for f in range(4):
                draw_actor(c, f * FRAME_W, (a * 4 + d) * FRAME_H,
                           name, d, f, skin, hair, shirt, pants, accent)
    c.save(os.path.join(ROOT, "assets/sprites/actors.png"))
    manifest = {
        "frame_size": [FRAME_W, FRAME_H],
        "frames_per_direction": 4,
        "directions": ["down", "left", "right", "up"],
        "actors": {name: {"row_block": i} for i, (name, *_ ) in enumerate(ACTORS)},
    }
    path = os.path.join(ROOT, "assets/sprites/actors.json")
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print("wrote %s" % os.path.relpath(path, ROOT))


if __name__ == "__main__":
    build_terrain()
    build_actors()
