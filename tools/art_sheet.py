#!/usr/bin/env python3
"""Render labelled contact sheets of every tile, actor and palette colour.

    python3 tools/art_sheet.py

Writes docs/art/atlas.png, docs/art/actors.png and docs/art/palette.png.

The shipped art is tiny and illegible at 1:1. These sheets magnify it and name
every piece, so an agent working headlessly can open one with an image viewer
(Codex: `view_image`) and actually see what a painter drew. Committed on
purpose -- GitHub then renders a before/after image diff on any pull request
that touches the art.

Every tile is drawn with its ground diamond outlined. A tile whose art floats
off that outline, or spills past it, is a tile that will not line up with its
neighbours in the game.

Pair it with tools/render_map.py, which shows the same tiles in context.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pixel import (
    ROOT, Canvas, P, blit, diamond_span, draw_text, geometry, load_png, rgb,
    text_width,
)

BG = rgb("14161c")
PANEL = rgb("1d212b")
INK = rgb("e8ecf4")
DIM = rgb("8b93a6")
SOLID_MARK = rgb("d8654f")
CHECK_A = rgb("2a2f3a")
CHECK_B = rgb("22262f")

TW, TH, CW, CH = geometry()
FOOT = (CH - TH) // 2
DRAWN_H = FOOT + TH      # the cell rows a painter may use; the rest is padding
ZOOM = 5
ACTOR_ZOOM = 4
FOOTPRINT = (255, 255, 255, 46)


def checker(c, x, y, w, h, size=6):
    for yy in range(h):
        for xx in range(w):
            odd = ((xx // size) + (yy // size)) % 2
            c.set(x + xx, y + yy, CHECK_A if odd else CHECK_B)


def footprint(c, x, y, zoom):
    """Outline where the ground diamond sits inside a magnified cell."""
    for row in range(TH):
        x0, width = diamond_span(row, TW, TH)
        for col in (x0, x0 + width - 1):
            for sy in range(zoom):
                for sx in range(zoom):
                    c.blend(x + col * zoom + sx, y + (FOOT + row) * zoom + sy, FOOTPRINT)


def header(c, title, subtitle):
    draw_text(c, 10, 10, title, INK, scale_=3)
    draw_text(c, 10, 30, subtitle, DIM, scale_=1)


# --------------------------------------------------------------------------

def build_atlas_sheet():
    reg = json.load(open(os.path.join(ROOT, "assets/tiles/tiles.json")))
    atlas = load_png(os.path.join(ROOT, "assets/tiles/terrain.png"))
    names = sorted(reg["tiles"])

    cols = int(reg.get("atlas_columns", 8))
    cell_w = TW * ZOOM + 14
    cell_h = DRAWN_H * ZOOM + 34
    top = 46
    rows = (len(names) + cols - 1) // cols

    c = Canvas(cols * cell_w + 12, top + rows * cell_h + 12)
    c.rect(0, 0, c.w, c.h, BG)
    header(c, "TILE ATLAS",
           "%d tiles - %dx%d diamond in a %dx%d cell - faint outline = the ground it stands on - red frame = blocks movement"
           % (len(names), TW, TH, CW, CH))

    for i, name in enumerate(names):
        info = reg["tiles"][name]
        ax, ay = info["atlas"]
        solid = bool(info.get("solid", False))
        cx = 6 + (i % cols) * cell_w
        cy = top + (i // cols) * cell_h

        c.rect(cx, cy, cell_w - 4, cell_h - 4, PANEL)
        px, py = cx + 7, cy + 5
        checker(c, px, py, TW * ZOOM, DRAWN_H * ZOOM)
        blit(c, atlas, px, py, sx=ax * CW, sy=ay * CH, w=CW, h=DRAWN_H, factor=ZOOM)
        footprint(c, px, py, ZOOM)
        if solid:
            c.frame(px - 1, py - 1, TW * ZOOM + 2, DRAWN_H * ZOOM + 2, SOLID_MARK)

        label_y = py + DRAWN_H * ZOOM + 5
        draw_text(c, px, label_y, name, INK, scale_=2)
        meta = "%d,%d%s" % (ax, ay, "  SOLID" if solid else "")
        draw_text(c, px, label_y + 13, meta, SOLID_MARK if solid else DIM, scale_=1)

    c.save(os.path.join(ROOT, "docs/art/atlas.png"))


def build_actor_sheet():
    manifest = json.load(open(os.path.join(ROOT, "assets/sprites/actors.json")))
    sheet = load_png(os.path.join(ROOT, "assets/sprites/actors.png"))
    fw, fh = manifest["frame_size"]
    dirs = manifest["directions"]
    frames = int(manifest["frames_per_direction"])
    actors = sorted(manifest["actors"], key=lambda k: manifest["actors"][k]["row_block"])

    label_col = 68
    cell_w = fw * ACTOR_ZOOM + 8
    cell_h = fh * ACTOR_ZOOM + 8
    block_h = len(dirs) * cell_h + 22
    top = 46

    c = Canvas(label_col + frames * cell_w + 16, top + len(actors) * block_h + 12)
    c.rect(0, 0, c.w, c.h, BG)
    header(c, "ACTORS", "%d actors x %d directions x %d frames - tools/gen_art.py ACTORS"
           % (len(actors), len(dirs), frames))

    for a, actor in enumerate(actors):
        block_y = top + a * block_h
        c.rect(6, block_y, c.w - 12, block_h - 8, PANEL)
        draw_text(c, 12, block_y + 6, actor, INK, scale_=2)
        for d, direction in enumerate(dirs):
            row_y = block_y + 20 + d * cell_h
            draw_text(c, 12, row_y + fh * ACTOR_ZOOM // 2 - 2, direction, DIM, scale_=1)
            for f in range(frames):
                px = label_col + f * cell_w
                checker(c, px, row_y, fw * ACTOR_ZOOM, fh * ACTOR_ZOOM, size=8)
                blit(c, sheet, px, row_y,
                     sx=f * fw, sy=(manifest["actors"][actor]["row_block"] * len(dirs) + d) * fh,
                     w=fw, h=fh, factor=ACTOR_ZOOM)

    c.save(os.path.join(ROOT, "docs/art/actors.png"))


def build_palette_sheet():
    names = sorted(P)
    cols = 6
    sw, sh = 96, 44
    top = 46
    rows = (len(names) + cols - 1) // cols

    c = Canvas(cols * sw + 12, top + rows * sh + 12)
    c.rect(0, 0, c.w, c.h, BG)
    header(c, "PALETTE", "%d colours - tools/pixel.py P - do not introduce colours outside this" % len(names))

    for i, name in enumerate(names):
        colour = P[name]
        x = 6 + (i % cols) * sw
        y = top + (i // cols) * sh
        checker(c, x, y, sw - 6, 26, size=6)
        for yy in range(26):
            for xx in range(sw - 6):
                c.blend(x + xx, y + yy, colour)
        c.frame(x, y, sw - 6, 26, PANEL)
        draw_text(c, x, y + 29, name, INK, scale_=1)
        hexed = "%02X%02X%02X" % colour[:3]
        if colour[3] != 255:
            hexed += " A%d" % colour[3]
        draw_text(c, x, y + 36, hexed, DIM, scale_=1)

    c.save(os.path.join(ROOT, "docs/art/palette.png"))


if __name__ == "__main__":
    build_atlas_sheet()
    build_actor_sheet()
    build_palette_sheet()
