#!/usr/bin/env python3
"""Regenerate the project's pixel art from code.

    python3 tools/gen_art.py

Writes assets/tiles/terrain.png and assets/sprites/actors.png. Everything is
deterministic, so re-running produces byte-identical files and an unchanged
diff. Art lives in code so Claude can extend it headlessly: add a draw_* here,
add the tile to assets/tiles/tiles.json, re-run this, then re-run
tools/build_tileset.gd.

Standard library only (zlib + struct) -- no Pillow, nothing to install.
"""

import json
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = 16  # tile size


# --------------------------------------------------------------------------
# tiny PNG writer
# --------------------------------------------------------------------------

class Canvas:
    def __init__(self, w, h):
        self.w = w
        self.h = h
        self.px = bytearray(w * h * 4)  # RGBA, starts fully transparent

    def set(self, x, y, c):
        if not (0 <= x < self.w and 0 <= y < self.h):
            return
        i = (y * self.w + x) * 4
        self.px[i:i + 4] = bytes(c)

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.set(xx, yy, c)

    def hline(self, x, y, w, c):
        self.rect(x, y, w, 1, c)

    def vline(self, x, y, h, c):
        self.rect(x, y, 1, h, c)

    def save(self, path):
        raw = bytearray()
        stride = self.w * 4
        for y in range(self.h):
            raw.append(0)  # filter type 0 (None)
            raw += self.px[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            out = struct.pack(">I", len(data)) + tag + data
            return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        png = b"\x89PNG\r\n\x1a\n"
        png += chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        png += chunk(b"IEND", b"")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(png)
        print("wrote %s (%dx%d)" % (os.path.relpath(path, ROOT), self.w, self.h))


def rgb(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)


CLEAR = (0, 0, 0, 0)


def noise(x, y, salt=0):
    """Deterministic hash -> [0, 1). Keeps the art stable across runs."""
    n = (x * 374761393 + y * 668265263 + salt * 2147483647) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65536.0


# --------------------------------------------------------------------------
# palette
# --------------------------------------------------------------------------

P = {
    "grass":     rgb("4c7a3c"), "grass_hi": rgb("5f9349"), "grass_lo": rgb("3d6431"),
    "dirt":      rgb("8b6a45"), "dirt_hi":  rgb("a07e56"), "dirt_lo":  rgb("6f5336"),
    "stone":     rgb("8b8b95"), "stone_hi": rgb("a6a6b0"), "stone_lo": rgb("6b6b75"),
    "water":     rgb("2f5f9e"), "water_hi": rgb("4179bd"), "water_lo": rgb("234a7d"),
    "sand":      rgb("d6c48b"), "sand_hi":  rgb("e6d6a3"), "sand_lo":  rgb("bda972"),
    "leaf":      rgb("2f6b34"), "leaf_hi":  rgb("3f8a43"), "leaf_lo":  rgb("224f26"),
    "bark":      rgb("6b4429"), "bark_lo":  rgb("4d301c"),
    "wood":      rgb("8a5f3a"), "wood_hi":  rgb("a3744a"), "wood_lo":  rgb("6b482b"),
    "wallw":     rgb("70492d"), "wallw_hi": rgb("875a38"), "wallw_lo": rgb("54371f"),
    "walls":     rgb("5c5c66"), "walls_hi": rgb("74747f"), "walls_lo": rgb("42424b"),
    "roof":      rgb("9e3f3f"), "roof_hi":  rgb("bb5050"), "roof_lo":  rgb("7a2f2f"),
    "rug":       rgb("8e3b5e"), "rug_hi":   rgb("ab4c74"), "rug_lo":   rgb("6d2c48"),
    "cloth":     rgb("c9b28d"),
    "metal":     rgb("9aa3ad"), "metal_lo": rgb("6e757d"),
    "fire":      rgb("e8863a"), "fire_hi":  rgb("f5c04a"), "fire_lo":  rgb("bf5a24"),
    "glass":     rgb("6fa8c9"), "glass_hi": rgb("9bcfe6"),
    "dark":      rgb("1a1a20"), "black": rgb("101014"),
    "shadow":    (0, 0, 0, 70),
}


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


def t_grass(c, ox, oy):
    speckle(c, ox, oy, P["grass"], P["grass_hi"], P["grass_lo"], 0.22, 1)
    for y in range(TS):
        for x in range(TS):
            if noise(ox + x, oy + y, 7) > 0.94:
                c.set(ox + x, oy + y, P["grass_hi"])
                c.set(ox + x, oy + y + 1, P["grass_lo"])


def t_grass_flower(c, ox, oy):
    t_grass(c, ox, oy)
    for fx, fy, col in ((3, 4, rgb("e8d45a")), (10, 9, rgb("d96f9a")), (6, 12, rgb("e8e0f0"))):
        c.set(ox + fx, oy + fy, col)
        c.set(ox + fx + 1, oy + fy, col)
        c.set(ox + fx, oy + fy + 1, col)
        c.set(ox + fx + 1, oy + fy + 1, P["grass_lo"])


def t_dirt(c, ox, oy):
    speckle(c, ox, oy, P["dirt"], P["dirt_hi"], P["dirt_lo"], 0.3, 2)


def t_stone_path(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["stone"])
    # irregular cobbles
    for (x, y, w, h) in ((0, 0, 7, 7), (8, 0, 8, 5), (0, 8, 5, 8), (6, 6, 5, 5),
                         (12, 6, 4, 6), (6, 12, 10, 4)):
        c.rect(ox + x, oy + y, w, h, P["stone_hi"] if (x + y) % 4 == 0 else P["stone"])
        c.hline(ox + x, oy + y + h - 1, w, P["stone_lo"])
        c.vline(ox + x + w - 1, oy + y, h, P["stone_lo"])


def t_water(c, ox, oy):
    c.rect(ox, oy, TS, TS, P["water"])
    for y in range(TS):
        for x in range(TS):
            if noise(ox + x, oy + y, 3) > 0.86:
                c.set(ox + x, oy + y, P["water_lo"])
    for y in (3, 9):
        for x in range(2, 12):
            if (x + y) % 5 < 3:
                c.set(ox + x, oy + y, P["water_hi"])


def t_sand(c, ox, oy):
    speckle(c, ox, oy, P["sand"], P["sand_hi"], P["sand_lo"], 0.24, 4)


def t_tree(c, ox, oy):
    t_grass(c, ox, oy)
    c.rect(ox + 6, oy + 10, 4, 6, P["bark"])
    c.vline(ox + 9, oy + 10, 6, P["bark_lo"])
    for y in range(TS):
        for x in range(TS):
            dx, dy = x - 8, y - 7
            d = dx * dx + dy * dy * 1.4
            if d < 42:
                col = P["leaf"]
                if d > 30:
                    col = P["leaf_lo"]
                elif noise(ox + x, oy + y, 5) > 0.6:
                    col = P["leaf_hi"]
                c.set(ox + x, oy + y, col)
    c.rect(ox + 5, oy + 2, 3, 2, P["leaf_hi"])


def t_bush(c, ox, oy):
    t_grass(c, ox, oy)
    for y in range(TS):
        for x in range(TS):
            dx, dy = x - 8, y - 10
            if dx * dx + dy * dy * 1.6 < 32:
                col = P["leaf"] if noise(ox + x, oy + y, 6) > 0.45 else P["leaf_hi"]
                c.set(ox + x, oy + y, col)
    c.hline(ox + 4, oy + 14, 9, P["leaf_lo"])


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
    c.rect(ox, oy, TS, TS, P["roof"])
    for row, y in enumerate((0, 5, 10)):
        off = 0 if row % 2 == 0 else 3
        for x in range(-off, TS, 6):
            c.rect(ox + x, oy + y, 5, 4, P["roof_hi"] if row % 2 else P["roof"])
            c.hline(ox + x, oy + y + 4, 5, P["roof_lo"])


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
    t_wood_floor(c, ox, oy)
    c.rect(ox, oy + 2, TS, 12, P["wood_lo"])
    c.rect(ox, oy + 2, TS, 3, P["wood_hi"])
    c.hline(ox, oy + 5, TS, P["wood"])
    c.hline(ox, oy + 13, TS, P["dark"])
    for x in range(2, TS, 5):
        c.vline(ox + x, oy + 6, 7, P["wood"])


def t_table(c, ox, oy):
    t_wood_floor(c, ox, oy)
    c.rect(ox + 1, oy + 3, 14, 9, P["wood_lo"])
    c.rect(ox + 2, oy + 4, 12, 6, P["wood_hi"])
    c.hline(ox + 2, oy + 4, 12, P["cloth"])
    c.rect(ox + 3, oy + 12, 2, 3, P["wood_lo"])
    c.rect(ox + 11, oy + 12, 2, 3, P["wood_lo"])


def t_chair(c, ox, oy):
    t_wood_floor(c, ox, oy)
    c.rect(ox + 4, oy + 3, 8, 8, P["wood_lo"])
    c.rect(ox + 5, oy + 4, 6, 3, P["wood_hi"])
    c.rect(ox + 4, oy + 11, 2, 3, P["wood_lo"])
    c.rect(ox + 10, oy + 11, 2, 3, P["wood_lo"])


def t_bed(c, ox, oy):
    t_wood_floor(c, ox, oy)
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
    t_wood_floor(c, ox, oy)
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
    t_wood_floor(c, ox, oy)
    c.rect(ox + 2, oy + 3, 12, 12, P["wood_lo"])
    c.rect(ox + 3, oy + 4, 10, 10, P["wood"])
    for i in range(10):
        c.set(ox + 3 + i, oy + 4 + i, P["wood_hi"])
        c.set(ox + 12 - i, oy + 4 + i, P["wood_hi"])


def t_sign(c, ox, oy):
    t_grass(c, ox, oy)
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
    t_grass(c, ox, oy)
    c.rect(ox + 1, oy + 4, 2, 11, P["wood_lo"])
    c.rect(ox + 12, oy + 4, 2, 11, P["wood_lo"])
    c.rect(ox, oy + 6, TS, 2, P["wood"])
    c.rect(ox, oy + 11, TS, 2, P["wood"])
    c.hline(ox, oy + 6, TS, P["wood_hi"])


def t_lamp(c, ox, oy):
    t_stone_path(c, ox, oy)
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
    # name,        skin,     hair,     shirt,    pants
    ("player",     "e0ac7e", "6b4a2a", "3f6fa8", "35405c"),
    ("bartender",  "d69a6b", "8a3f2a", "b8b4a8", "5a4433"),
    ("harbormaster", "c98d5f", "e0dcd2", "2f5f4a", "3a3a44"),
    ("villager",   "eabb8e", "4a3a2c", "8e6fa8", "4a4030"),
]


def draw_actor(c, ox, oy, dir_idx, frame, skin, hair, shirt, pants):
    S, H, SH, PA = rgb(skin), rgb(hair), rgb(shirt), rgb(pants)
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


def build_actors():
    rows = len(ACTORS) * 4
    c = Canvas(4 * FRAME_W, rows * FRAME_H)
    for a, (name, skin, hair, shirt, pants) in enumerate(ACTORS):
        for d in range(4):
            for f in range(4):
                draw_actor(c, f * FRAME_W, (a * 4 + d) * FRAME_H,
                           d, f, skin, hair, shirt, pants)
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
