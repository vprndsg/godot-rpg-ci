#!/usr/bin/env python3
"""Regenerate the project's pixel art from code.

    python3 tools/gen_art.py

Writes assets/tiles/terrain.png and assets/sprites/actors.png. Everything is
deterministic, so re-running produces byte-identical files and an unchanged
diff. Art lives in code so Claude can extend it headlessly: add a draw_* here,
add the tile to assets/tiles/tiles.json, re-run this, then re-run
tools/build_tileset.gd.

The world is isometric, so a tile is not a square. Every painter fills one
atlas cell laid out like this:

    row 0        +----------------+   headroom: walls, canopies, roofs
      ...        |                |   draw upwards into here
    row 23       |                |
    row 24       |      /\        |   the ground diamond -- 32x16, the tile's
      ...        |    /    \      |   actual footprint, and the only part that
    row 39       |      \/        |   lines up with its neighbours
    row 40       |                |   padding: never drawn into. It is what
      ...        |                |   centres the footprint in the cell, which
    row 63       +----------------+   is why terrain.tres needs no offset.

So: build ground from `ground()`, build anything solid from `block()` or
`small_block()`, and stand props on `foot_shadow()`. Those all take footprint
coordinates and put the pixels in the right rows for you.

Standard library only -- no Pillow, nothing to install. The canvas, palette,
PNG writer and the diamond primitives live in tools/pixel.py, which the
contact-sheet and map renderers share.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import packs

from pixel import (  # noqa: F401  (rgb/CLEAR used by painters)
    ROOT, Canvas, CLEAR, P, blob, diamond_floor, diamond_pixels, diamond_span,
    fill_diamond, geometry, in_diamond, load_png, noise, prism, rgb, shade,
)

TW, TH, CW, CH = geometry()   # diamond 32x16 inside a 32x64 cell
FOOT = (CH - TH) // 2         # 24 -- first row of the footprint in a cell

# How tall things stand, in pixels above their own ground. FOOT is the ceiling:
# anything taller would climb out of its cell and be clipped.
WALL_H = 16
ROOF_H = 24


# --------------------------------------------------------------------------
# building blocks -- every painter is made of these
# --------------------------------------------------------------------------

def ground(c, ox, oy, base, hi, lo, density=0.18, salt=0):
    """Flat, speckled terrain: the diamond and nothing above it."""
    for x, y in diamond_pixels(TW, TH):
        n = noise(ox + x, oy + y, salt)
        col = lo if n < density * 0.5 else (hi if n < density else base)
        c.set(ox + x, oy + FOOT + y, col)


def block(c, ox, oy, height, top, left, right):
    """A full-cell solid: wall, roof, doorway. Fills its footprint exactly."""
    prism(c, ox, oy + FOOT, height, top, left, right, TW, TH)


def small_block(c, ox, oy, w, h, height, top, left, right, lift=0):
    """A solid narrower than its cell -- furniture, crates, barrels.

    `lift` raises it off the ground for tabletops, which then need legs.
    """
    dx, dy = (TW - w) // 2, (TH - h) // 2
    prism(c, ox + dx, oy + FOOT + dy - lift, height, top, left, right, w, h)


def faces(height, w=TW, h=TH):
    """(x, top_row, bottom_row) for each column of a block's two side faces.

    Painters use this to texture a face without having to work out where the
    silhouette put it -- brick courses and planks follow the diamond's edge
    automatically.
    """
    floor = diamond_floor(w, h)
    for x in sorted(floor):
        yield x, floor[x] - height + 1, floor[x]


def axis_line(c, ox, oy, x0, y0, colour, axis=1, length=TW):
    """A line along a grid axis: two pixels across for every one down.

    axis=+1 runs down-right (grid +x), axis=-1 runs down-left (grid +y). These
    are the only two directions a line can run and still look like it is lying
    on the ground.
    """
    for i in range(length):
        x = x0 + i
        step = i // 2
        y = y0 + (step if axis > 0 else -step)
        if in_diamond(x, y, TW, TH):
            c.set(ox + x, oy + FOOT + y, colour)


def foot_shadow(c, ox, oy, w=20, h=10):
    """Shade on the ground a prop stands on.

    Props draw over a separate ground layer, so this is deliberately
    translucent -- the grass or boards underneath still read through it.
    """
    dx, dy = (TW - w) // 2, (TH - h) // 2
    inner = set(diamond_pixels(w - 8, h - 4))
    for x, y in diamond_pixels(w, h):
        core = (x - 4, y - 2) in inner
        if core or (x + y) % 2 == 0:
            c.set(ox + dx + x, oy + FOOT + dy + y,
                  P["shadow"] if core else P["shadow_soft"])


def sub_diamonds(c, ox, oy, colour, edge, hi=None, salt=0):
    """Quarter the footprint into four 16x8 diamonds -- flagstones, setts.

    Four half-size diamonds tile a full one exactly, which is the only paving
    pattern that survives being repeated across a whole square.
    """
    for dx, dy in ((8, 0), (0, 4), (16, 4), (8, 8)):
        tone = edge if noise(ox + dx, oy + dy, 20 + salt) > 0.62 else colour
        fill_diamond(c, ox + dx, oy + FOOT + dy, tone, 16, 8)
        if hi is not None:
            for y in range(4):
                x0, width = diamond_span(y, 16, 8)
                c.set(ox + dx + x0, oy + FOOT + dy + y, hi)
                c.set(ox + dx + x0 + width - 1, oy + FOOT + dy + y, hi)


# --------------------------------------------------------------------------
# terrain
# --------------------------------------------------------------------------

def t_grass(c, ox, oy):
    ground(c, ox, oy, P["grass"], P["grass_hi"], P["grass_lo"], 0.10, 1)
    for x, y in ((9, 6), (18, 4), (22, 10), (13, 11)):
        c.set(ox + x, oy + FOOT + y, P["grass_lo"])
        c.set(ox + x - 1, oy + FOOT + y - 1, P["grass_hi"])
        c.set(ox + x + 1, oy + FOOT + y - 1, P["grass_hi"])


def t_grass_flower(c, ox, oy):
    t_grass(c, ox, oy)
    for fx, fy, col in ((11, 8, rgb("e8d45a")), (20, 7, rgb("d96f9a")),
                        (15, 12, rgb("e8e0f0"))):
        c.set(ox + fx, oy + FOOT + fy, col)
        c.set(ox + fx + 1, oy + FOOT + fy, col)
        c.set(ox + fx, oy + FOOT + fy - 1, col)
        c.set(ox + fx + 1, oy + FOOT + fy + 1, P["grass_lo"])


def t_dirt(c, ox, oy):
    ground(c, ox, oy, P["dirt"], P["dirt_hi"], P["dirt_lo"], 0.14, 2)
    # Ruts run along the grid, because carts do.
    axis_line(c, ox, oy, 4, 8, P["dirt_lo"], 1, 24)
    axis_line(c, ox, oy, 6, 12, P["dirt_hi"], -1, 20)


def t_stone_path(c, ox, oy):
    fill_diamond(c, ox, oy + FOOT, P["stone_lo"], TW, TH)
    sub_diamonds(c, ox, oy, P["stone"], P["stone_lo"], P["stone_hi"], salt=1)


def t_water(c, ox, oy):
    fill_diamond(c, ox, oy + FOOT, P["water"], TW, TH)
    for x, y in diamond_pixels(TW, TH):
        n = noise(ox + x, oy + y, 5)
        if n > 0.94:
            c.set(ox + x, oy + FOOT + y, P["water_lo"])
        elif n < 0.04:
            c.set(ox + x, oy + FOOT + y, P["water_hi"])
    # Short crests, all kept clear of the diamond's edges. A stroke that
    # reaches an edge meets the identical stroke on the next tile and rules
    # the whole sea into a lattice -- which is exactly what a tiled ocean
    # must not look like.
    for x0, y0, axis, length, col in ((11, 4, 1, 7, P["water_hi"]),
                                      (17, 10, -1, 6, P["water_hi"]),
                                      (9, 9, 1, 5, P["water_lo"]),
                                      (20, 6, -1, 5, P["water_lo"])):
        axis_line(c, ox, oy, x0, y0, col, axis, length)
    axis_line(c, ox, oy, 12, 4, P["foam"], 1, 4)


def t_sand(c, ox, oy):
    ground(c, ox, oy, P["sand"], P["sand_hi"], P["sand_lo"], 0.10, 4)
    axis_line(c, ox, oy, 8, 9, P["sand_lo"], 1, 14)
    axis_line(c, ox, oy, 12, 11, P["sand_hi"], -1, 12)


def _north_band(c, ox, oy, colour, edge, depth):
    """Flood the strip along the cell's north-east edge.

    That is the edge a cell shares with the one directly north of it, and the
    maps run their coastlines and dune lines along a grid row -- so this is
    the edge the other terrain actually arrives from. Banding the top *half*
    of the diamond instead would draw a horizontal line across a world that
    has no horizontal edges, and every tile in the row would show the same
    sawtooth.
    """
    for x, y in diamond_pixels(TW, TH):
        # Zero along the north-east edge, falling away toward the south-west.
        reach = (x - TW // 2) - 2 * y + 2 * depth
        reach += 3 if noise(ox + x // 4, oy, 7) > 0.5 else 0
        if reach > 3:
            c.set(ox + x, oy + FOOT + y, colour)
        elif reach > 0:
            c.set(ox + x, oy + FOOT + y, edge)


def t_shore(c, ox, oy):
    """Sea meeting sand, with the water on the seaward edge."""
    t_sand(c, ox, oy)
    _north_band(c, ox, oy, P["water"], P["foam"], 8)
    axis_line(c, ox, oy, 19, 3, P["water_hi"], 1, 5)
    axis_line(c, ox, oy, 22, 5, P["water_lo"], -1, 4)


def t_dune_edge(c, ox, oy):
    """Sand giving way to grass, with a windblown fringe."""
    t_grass(c, ox, oy)
    _north_band(c, ox, oy, P["sand"], P["sand_lo"], 7)
    for x, y in ((12, 10), (21, 9)):
        c.set(ox + x, oy + FOOT + y, P["grass_hi"])
        c.set(ox + x + 1, oy + FOOT + y + 1, P["grass_lo"])


# --------------------------------------------------------------------------
# floors
# --------------------------------------------------------------------------

def _boards(c, ox, oy, offset=0):
    """Floorboards running along grid +x, so rooms have a clear grain."""
    fill_diamond(c, ox, oy + FOOT, P["wood"], TW, TH)
    for x, y in diamond_pixels(TW, TH):
        n = noise(ox + x, oy + y, 8)
        if n > 0.90:
            c.set(ox + x, oy + FOOT + y, P["wood_hi"])
        elif n < 0.06:
            c.set(ox + x, oy + FOOT + y, P["wood_lo"])
    for k in range(-4, 5):
        y0 = k * 4 + 8 + offset
        axis_line(c, ox, oy, -16, y0, P["wood_lo"], 1, TW + 32)
        axis_line(c, ox, oy, -16, y0 + 1, P["wood_hi"], 1, TW + 32)
    # One staggered butt joint per tile, across the grain.
    axis_line(c, ox, oy, 12 + offset, 2, P["wood_lo"], -1, 8)


def t_wood_floor(c, ox, oy):
    _boards(c, ox, oy, 0)


def t_wood_floor_b(c, ox, oy):
    _boards(c, ox, oy, 2)


def t_stone_floor(c, ox, oy):
    fill_diamond(c, ox, oy + FOOT, P["stone_lo"], TW, TH)
    sub_diamonds(c, ox, oy, P["stone"], P["stone_lo"], P["stone_hi"], salt=3)


def t_rug(c, ox, oy):
    fill_diamond(c, ox, oy + FOOT, P["rug"], TW, TH)
    fill_diamond(c, ox + 3, oy + FOOT + 2, P["rug_hi"], 26, 13)
    fill_diamond(c, ox + 8, oy + FOOT + 4, P["rug_lo"], 16, 8)
    fill_diamond(c, ox + 12, oy + FOOT + 6, P["rug_hi"], 8, 4)
    # Fringe on the two near edges, where a rug's edge would actually show.
    for y in range(TH // 2, TH):
        x0, width = diamond_span(y, TW, TH)
        if y % 2 == 0:
            c.set(ox + x0, oy + FOOT + y, P["cloth"])
            c.set(ox + x0 + width - 1, oy + FOOT + y, P["cloth"])


# --------------------------------------------------------------------------
# walls and structure
# --------------------------------------------------------------------------

def _course(c, ox, oy, height, left, right, spacing=5):
    """Brick courses across both faces of a block.

    Courses follow the face's own slope, and their colour is derived from the
    face they sit on -- a shared highlight would paint the lit and shadowed
    sides the same and flatten the block back into a stack of plates.
    """
    for x, top, bottom in faces(height):
        base = left if x < TW // 2 else right
        for y in range(top, bottom + 1):
            depth = y - top
            if depth % spacing == 0:
                c.set(ox + x, oy + FOOT + y, shade(base, -16))
            elif depth % spacing == 1:
                c.set(ox + x, oy + FOOT + y, shade(base, 10))
            elif (x * 2 + (depth // spacing) * 5) % 10 < 1:
                c.set(ox + x, oy + FOOT + y, shade(base, -10))


def t_wall_stone(c, ox, oy):
    block(c, ox, oy, WALL_H, P["walls_hi"], P["walls"], P["walls_lo"])
    _course(c, ox, oy, WALL_H, P["walls"], P["walls_lo"])


def _boarding(c, ox, oy, height, left, right):
    """Vertical boards down both faces of a block."""
    for x, top, bottom in faces(height):
        base = left if x < TW // 2 else right
        if x % 4 == 0:
            tone = shade(base, -22)
        elif x % 4 == 1:
            tone = shade(base, 12)
        else:
            continue
        for y in range(top, bottom + 1):
            c.set(ox + x, oy + FOOT + y, tone)


def t_wall_wood(c, ox, oy):
    block(c, ox, oy, WALL_H, P["wallw_hi"], P["wallw"], P["wallw_lo"])
    _boarding(c, ox, oy, WALL_H, P["wallw"], P["wallw_lo"])
    # A rail across both faces stops the boards reading as one flat fan.
    for x, top, bottom in faces(WALL_H):
        c.set(ox + x, oy + FOOT + top + 7, shade(P["wallw"], -26))


def t_wall_top(c, ox, oy):
    """The capped back wall of a room: the same block, seen from outside."""
    block(c, ox, oy, WALL_H, P["walls"], P["walls_lo"], P["dark"])
    _course(c, ox, oy, WALL_H, P["walls_lo"], P["dark"])
    fill_diamond(c, ox + 3, oy + FOOT - WALL_H + 2, P["walls_hi"], 26, 13)


def t_roof(c, ox, oy):
    block(c, ox, oy, ROOF_H, P["roof"], P["roof_lo"], shade(P["roof_lo"], -22))
    # Shingle courses on the top face, running along grid +x.
    for k in range(-3, 5):
        for i in range(TW):
            x = i
            y = k * 4 + 6 + i // 2 - ROOF_H
            if in_diamond(x, y + ROOF_H, TW, TH):
                c.set(ox + x, oy + FOOT + y, P["roof_lo"])
                if in_diamond(x, y + ROOF_H + 1, TW, TH):
                    c.set(ox + x, oy + FOOT + y + 1, P["roof_hi"])
    # Eaves: a dark lip where the roof overhangs the wall below.
    for x, top, bottom in faces(ROOF_H):
        c.set(ox + x, oy + FOOT + top, P["roof_lo"])
        c.set(ox + x, oy + FOOT + top + 1, P["dark"])


def t_door(c, ox, oy):
    """A doorway, not a door: you walk through this tile, so it is cut open.

    The opening straddles the block's near corner, which is the corner facing
    the camera whichever wall the door sits in.
    """
    t_wall_wood(c, ox, oy)
    for x, top, bottom in faces(WALL_H):
        if not 10 <= x <= 21:
            continue
        for y in range(top + 4, bottom + 1):
            c.set(ox + x, oy + FOOT + y, P["black"])
        c.set(ox + x, oy + FOOT + top + 3, P["wood_hi"])   # lintel
        c.set(ox + x, oy + FOOT + top + 4, P["wood_lo"])
    # Frame the opening and hint at the boards of the door standing open.
    for x in (10, 21):
        for y in range(diamond_floor(TW, TH)[x] - WALL_H + 3,
                       diamond_floor(TW, TH)[x] + 1):
            c.set(ox + x, oy + FOOT + y, P["wood_lo"])
    c.set(ox + 18, oy + FOOT + 4, P["metal"])


def t_window(c, ox, oy):
    t_wall_wood(c, ox, oy)
    for x, top, bottom in faces(WALL_H):
        if not 8 <= x <= 23:
            continue
        for y in range(top + 4, top + 11):
            col = P["glass_hi"] if (x + y) % 7 == 0 else P["glass"]
            c.set(ox + x, oy + FOOT + y, col)
    for x in (8, 23):
        for y in range(diamond_floor(TW, TH)[x] - WALL_H + 3,
                       diamond_floor(TW, TH)[x] - WALL_H + 12):
            c.set(ox + x, oy + FOOT + y, P["wood_lo"])
    for x, top, _ in faces(WALL_H):
        if 8 <= x <= 23:
            c.set(ox + x, oy + FOOT + top + 3, P["wood_lo"])
            c.set(ox + x, oy + FOOT + top + 11, P["wood_lo"])
            if 15 <= x <= 16:
                for y in range(top + 4, top + 11):
                    c.set(ox + x, oy + FOOT + y, P["wood_lo"])


def t_shelf(c, ox, oy):
    t_wall_wood(c, ox, oy)
    bottles = (P["glass"], P["fire"], P["leaf_hi"], P["rug_hi"], P["cloth"])
    for x, top, bottom in faces(WALL_H):
        if not 6 <= x <= 25:
            continue
        for shelf_y in (top + 5, top + 10):
            c.set(ox + x, oy + FOOT + shelf_y, P["wood_hi"])
            c.set(ox + x, oy + FOOT + shelf_y + 1, P["wood_lo"])
            if x % 3 != 0:
                c.set(ox + x, oy + FOOT + shelf_y - 1, bottles[(x // 3) % 5])
                c.set(ox + x, oy + FOOT + shelf_y - 2, bottles[(x // 3) % 5])


def t_fireplace(c, ox, oy):
    t_wall_stone(c, ox, oy)
    for x, top, bottom in faces(WALL_H):
        if not 11 <= x <= 20:
            continue
        for y in range(top + 5, bottom + 1):
            c.set(ox + x, oy + FOOT + y, P["black"])
        c.set(ox + x, oy + FOOT + top + 4, P["stone_hi"])
        for y in range(bottom - 4, bottom + 1):
            heat = noise(ox + x, oy + y, 13)
            c.set(ox + x, oy + FOOT + y,
                  P["fire_hi"] if heat > 0.72 else (P["fire"] if heat > 0.3 else P["fire_lo"]))


def t_void(c, ox, oy):
    block(c, ox, oy, WALL_H, P["dark"], P["black"], P["black"])
    for x, y in diamond_pixels(TW, TH):
        if noise(ox + x, oy + y, 11) > 0.97:
            c.set(ox + x, oy + FOOT + y - WALL_H, P["dark"])


def _tread(x, y):
    """Which of four steps a footprint pixel belongs to.

    Steps run across the grid +x axis, so a step edge is a line of constant
    grid y -- which on screen is a line of slope one-in-two. Counting bands
    along that gives a staircase that climbs toward the back of the cell.
    """
    return min(3, max(0, (y - x // 2 + 8) // 4))


def t_stairs_up(c, ox, oy):
    """Steps climbing away from the camera."""
    for x, y in diamond_pixels(TW, TH):
        rise = (3 - _tread(x, y)) * 4
        for d in range(rise + 1):
            if d == 0:
                col = P["stone_hi"]              # the tread you walk on
            elif d < 3:
                col = P["stone"]                 # the riser below it
            else:
                col = P["stone_lo"]
            c.set(ox + x, oy + FOOT + y - rise + d, col)


def t_stairs_down(c, ox, oy):
    """The same staircase, sunk into the floor instead of standing on it."""
    fill_diamond(c, ox, oy + FOOT, P["stone"], TW, TH)
    depths = (P["stone_lo"], P["dark"], P["black"], P["black"])
    for x, y in diamond_pixels(TW, TH):
        step = _tread(x, y)
        if step == 3:
            continue                             # the landing you step from
        c.set(ox + x, oy + FOOT + y, depths[step])
        # A lit lip on the near edge of each step, where the light still falls.
        if _tread(x, y + 1) != step:
            c.set(ox + x, oy + FOOT + y, P["stone_hi"])


# --------------------------------------------------------------------------
# furniture and props
# --------------------------------------------------------------------------

def t_counter(c, ox, oy):
    small_block(c, ox, oy, 28, 14, 9, P["wood_hi"], P["wood"], P["wood_lo"])
    for x, top, bottom in faces(9, 28, 14):
        if x % 5 == 2:
            for y in range(top + 2, bottom + 1):
                c.set(ox + 2 + x, oy + FOOT + 1 + y, P["wood_lo"])
    for x, top, _ in faces(9, 28, 14):
        c.set(ox + 2 + x, oy + FOOT + 1 + top, P["cloth"])


def _legs(c, ox, oy, w, h, lift, colour):
    """Four legs from a lifted tabletop down to the ground it stands on."""
    dx, dy = (TW - w) // 2, (TH - h) // 2
    floor = diamond_floor(w, h)
    for x in (min(floor) + 1, w // 2 - 1, w // 2, max(floor) - 1):
        base = floor[x]
        for k in range(lift + 1):
            c.set(ox + dx + x, oy + FOOT + dy + base - k, colour)


def t_table(c, ox, oy):
    foot_shadow(c, ox, oy, 22, 11)
    _legs(c, ox, oy, 22, 11, 6, P["wood_lo"])
    small_block(c, ox, oy, 22, 11, 3, P["wood_hi"], P["wood"], P["wood_lo"], lift=6)
    fill_diamond(c, ox + 8, oy + FOOT - 9 + 3, P["cloth"], 16, 8)


def t_chair(c, ox, oy):
    foot_shadow(c, ox, oy, 14, 7)
    _legs(c, ox, oy, 12, 6, 5, P["wood_lo"])
    small_block(c, ox, oy, 12, 6, 2, P["wood_hi"], P["wood"], P["wood_lo"], lift=5)
    # Backrest, rising off the far edge of the seat it is joined to. The seat's
    # top face ends at FOOT - 2, so this has to start above that and overlap.
    for x in range(11, 21):
        for y in range(FOOT - 11, FOOT - 1):
            edge = y == FOOT - 11 or x in (11, 20)
            c.set(ox + x, oy + y, P["wood_lo"] if edge else P["wood"])
    for x in range(13, 19):
        c.set(ox + x, oy + FOOT - 8, P["wood_hi"])


def t_bed(c, ox, oy):
    foot_shadow(c, ox, oy, 26, 13)
    small_block(c, ox, oy, 26, 13, 6, P["cloth"], P["wood"], P["wood_lo"])
    fill_diamond(c, ox + 5, oy + FOOT - 4, P["rug"], 22, 11)
    fill_diamond(c, ox + 7, oy + FOOT - 7, rgb("e8e6de"), 12, 6)   # pillow
    for x, top, _ in faces(6, 26, 13):
        c.set(ox + 3 + x, oy + FOOT + 1 + top, P["wood_hi"])


def t_barrel(c, ox, oy):
    foot_shadow(c, ox, oy, 16, 8)
    small_block(c, ox, oy, 14, 7, 13, P["bark_lo"], P["wood"], P["wood_lo"])
    for x, top, bottom in faces(13, 14, 7):
        px = ox + 9 + x
        for y in (top + 3, top + 4, bottom - 3, bottom - 2):
            c.set(px, oy + FOOT + 4 + y, P["metal"] if y % 2 == 0 else P["metal_lo"])
        if x % 4 == 1:
            for y in range(top + 1, bottom + 1):
                c.set(px, oy + FOOT + 4 + y, P["wood_hi"])
    fill_diamond(c, ox + 11, oy + FOOT + 4 - 13 + 1, P["bark"], 10, 5)


def t_crate(c, ox, oy):
    foot_shadow(c, ox, oy, 20, 10)
    small_block(c, ox, oy, 20, 10, 14, P["wood_hi"], P["wood"], P["wood_lo"])
    for x, top, bottom in faces(14, 20, 10):
        px = ox + 6 + x
        c.set(px, oy + FOOT + 3 + top, P["wood_lo"])
        c.set(px, oy + FOOT + 3 + bottom, P["wood_lo"])
        # A diagonal brace on each face, meeting at the near corner.
        brace = top + (x if x < 10 else 19 - x) * (bottom - top) // 10
        c.set(px, oy + FOOT + 3 + brace, P["wood_lo"])


def t_sign(c, ox, oy):
    foot_shadow(c, ox, oy, 12, 6)
    for y in range(14):
        c.set(ox + 15, oy + FOOT + 8 - y, P["bark"])
        c.set(ox + 16, oy + FOOT + 8 - y, P["bark_lo"])
    board_top = FOOT - 14
    for y in range(9):
        for x in range(6, 26):
            edge = y in (0, 8) or x in (6, 25)
            c.set(ox + x, oy + board_top + y, P["wood_lo"] if edge else P["wood_hi"])
    for y, x0, width in ((3, 9, 13), (5, 9, 9)):
        for x in range(x0, x0 + width):
            c.set(ox + x, oy + board_top + y, P["bark_lo"])


def t_fence(c, ox, oy):
    """Rails along both grid axes, so a run reads as a fence from any side.

    A rail runs edge midpoint to edge midpoint -- from where the neighbour's
    rail arrives to where it leaves -- so a line of these joins up instead of
    becoming a row of separate sticks.
    """
    foot_shadow(c, ox, oy, 18, 9)
    for axis in (1, -1):
        # Pickets first, so the rails read as nailed across the front of them.
        for i in range(1, 17, 3):
            x = 8 + i
            step = i // 2
            y = (4 + step) if axis > 0 else (12 - step)
            for k in range(13):
                c.set(ox + x, oy + FOOT + y - k, P["wood_lo"])
            c.set(ox + x, oy + FOOT + y - 13, P["wood"])
        for lift, cap in ((4, P["wood_hi"]), (10, P["wood_hi"])):
            for i in range(17):
                x = 8 + i
                step = i // 2
                y = (4 + step) if axis > 0 else (12 - step)
                c.set(ox + x, oy + FOOT + y - lift, P["wood"])
                c.set(ox + x, oy + FOOT + y - lift - 1, cap)
                c.set(ox + x, oy + FOOT + y - lift + 1, P["wood_lo"])
    for px, tone in ((15, P["wood"]), (16, P["wood_lo"])):
        for y in range(16):
            c.set(ox + px, oy + FOOT + 8 - y, tone)
    c.set(ox + 15, oy + FOOT - 8, P["wood_hi"])
    c.set(ox + 16, oy + FOOT - 8, P["wood_hi"])


def t_lamp(c, ox, oy):
    foot_shadow(c, ox, oy, 12, 6)
    for y in range(20):
        c.set(ox + 15, oy + FOOT + 8 - y, P["metal"])
        c.set(ox + 16, oy + FOOT + 8 - y, P["metal_lo"])
    top = FOOT - 18
    for y in range(7):
        for x in range(12, 20):
            edge = y in (0, 6) or x in (12, 19)
            c.set(ox + x, oy + top + y, P["metal_lo"] if edge else P["fire_hi"])
    for x in range(14, 18):
        c.set(ox + x, oy + top + 3, rgb("fff3c4"))
    for x in range(11, 21):
        c.set(ox + x, oy + top - 1, P["metal_lo"])


def t_tree(c, ox, oy):
    foot_shadow(c, ox, oy, 22, 11)
    for y in range(14):
        c.set(ox + 15, oy + FOOT + 6 - y, P["bark"])
        c.set(ox + 16, oy + FOOT + 6 - y, P["bark_lo"])
        if y in (5, 9):
            c.set(ox + 14, oy + FOOT + 5 - y, P["bark_lo"])
            c.set(ox + 17, oy + FOOT + 5 - y, P["bark_lo"])
    # A wind-shaped coastal crown, built from rounded masses: shadowed
    # underside first, then the bulk, then the sunlit top-left shoulder.
    blob(c, ox, oy, 16, 18, 13, 9, P["leaf_lo"])
    blob(c, ox, oy, 15, 13, 12, 9, P["leaf"])
    blob(c, ox, oy, 20, 16, 8, 6, P["leaf_lo"])
    blob(c, ox, oy, 12, 10, 8, 6, P["leaf_hi"])
    blob(c, ox, oy, 18, 9, 5, 4, P["leaf"])
    # Break the outline so the crown reads as leaves rather than a balloon.
    for y in range(2, 28):
        for x in range(2, 30):
            if noise(ox + x, oy + y, 15) > 0.93:
                c.set(ox + x, oy + y, P["leaf_lo"])
    for x, y in ((5, 17), (27, 19), (13, 2), (24, 8), (8, 24), (22, 25)):
        c.set(ox + x, oy + y, CLEAR)


def t_bush(c, ox, oy):
    foot_shadow(c, ox, oy, 18, 9)
    blob(c, ox, oy, 16, FOOT + 2, 10, 6, P["leaf_lo"])
    blob(c, ox, oy, 15, FOOT - 3, 9, 6, P["leaf"])
    blob(c, ox, oy, 12, FOOT - 6, 5, 4, P["leaf_hi"])
    blob(c, ox, oy, 21, FOOT - 2, 5, 4, P["leaf"])
    for y in range(FOOT - 12, FOOT + 8):
        for x in range(4, 28):
            if noise(ox + x, oy + y, 17) > 0.92:
                c.set(ox + x, oy + y, P["leaf_lo"])
    for x, y in ((6, FOOT + 3), (26, FOOT), (11, FOOT - 10)):
        c.set(ox + x, oy + y, CLEAR)


# --------------------------------------------------------------------------
# emission painters -- the pixels of a tile that stay lit in the dark
#
# A tile with "lighting": {"emission": true} in tiles.json must have an
# e_<name> painter here, and vice versa; build_emission() fails on any
# mismatch. Each painter draws *only the glowing pixels* of its tile, at the
# same coordinates as the diffuse painter, into terrain_emission.png -- an
# atlas laid out exactly like terrain.png. At runtime a shader on the tile
# layers replaces those pixels after ambient darkening, so a lamp's flame
# stays warm at midnight while its post goes dark with everything else.
# Alpha is emission strength: 255 replaces the lit pixel outright, less mixes.
# --------------------------------------------------------------------------

def e_lamp(c, ox, oy):
    # The lantern's glass interior, mirroring t_lamp's geometry exactly.
    top = FOOT - 18
    for y in range(1, 6):
        for x in range(13, 19):
            c.set(ox + x, oy + top + y, P["fire_hi"])
    for x in range(14, 18):
        c.set(ox + x, oy + top + 3, rgb("fff3c4"))


def e_fireplace(c, ox, oy):
    # The firebox flames -- same columns, rows and noise salt as t_fireplace,
    # so emission covers precisely the pixels the diffuse painter made fire.
    for x, top, bottom in faces(WALL_H):
        if not 11 <= x <= 20:
            continue
        for y in range(bottom - 4, bottom + 1):
            heat = noise(ox + x, oy + y, 13)
            c.set(ox + x, oy + FOOT + y,
                  P["fire_hi"] if heat > 0.72 else (P["fire"] if heat > 0.3 else P["fire_lo"]))


def e_window(c, ox, oy):
    # The glass panes from t_window: frame and mullion stay dark, glass glows.
    for x, top, bottom in faces(WALL_H):
        if not 9 <= x <= 22 or 15 <= x <= 16:
            continue
        for y in range(top + 4, top + 11):
            col = P["glass_hi"] if (x + y) % 7 == 0 else P["glass"]
            c.set(ox + x, oy + FOOT + y, col)


EMISSION_PAINTERS = {
    "fireplace": e_fireplace, "lamp": e_lamp, "window": e_window,
}


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
    """Compose the atlas from painters and from any imported art packs.

    A tile is drawn by a `t_<name>` painter here unless tiles.json gives it a
    `pack`, in which case its pixels are cut from that pack's sheet instead.
    Both are *sources*: terrain.png stays a build output either way, so the CI
    drift check keeps meaning what it means.
    """
    reg = json.load(open(os.path.join(ROOT, "assets/tiles/tiles.json")))
    cols = reg["atlas_columns"]
    rows = max(t["atlas"][1] for t in reg["tiles"].values()) + 1
    c = Canvas(cols * CW, rows * CH)

    imported = packs.tile_owner(reg)
    missing = sorted(set(reg["tiles"]) - set(PAINTERS) - set(imported))
    if missing:
        raise SystemExit(
            "tiles.json lists tiles with neither a painter here nor a 'pack': %s"
            % ", ".join(missing))

    manifests, sheets = {}, {}
    for name, info in reg["tiles"].items():
        ax, ay = info["atlas"]
        pack_name = imported.get(name)
        if pack_name is None:
            PAINTERS[name](c, ax * CW, ay * CH)
            continue

        if pack_name not in manifests:
            if pack_name not in packs.pack_names():
                raise SystemExit("tile '%s' names pack '%s', which is not in assets/packs/"
                                 % (name, pack_name))
            manifests[pack_name] = packs.load(pack_name)
            broken = packs.problems(manifests[pack_name])
            if broken:
                raise SystemExit("pack '%s' is not usable:\n  %s" % (pack_name, "\n  ".join(broken)))
            sheets[pack_name] = load_png(os.path.join(
                manifests[pack_name]["_dir"], manifests[pack_name]["sheet"]))

        manifest = manifests[pack_name]
        source_name = info.get("pack_tile", name)
        if source_name not in manifest["tiles"]:
            raise SystemExit("pack '%s' has no tile '%s' (set \"pack_tile\" if it is named "
                             "something else there)" % (pack_name, source_name))
        pixels, spilled = packs.cell_pixels(manifest, source_name, sheets[pack_name])
        if spilled:
            raise SystemExit(
                "tile '%s' from pack '%s' does not fit a %dx%d cell: %d pixels spill outside. "
                "Move the pack's anchor, or adopt its geometry in tiles.json."
                % (name, pack_name, CW, CH, len(spilled)))
        for x, y, colour in pixels:
            c.set(ax * CW + x, ay * CH + y, colour)

    c.save(os.path.join(ROOT, "assets/tiles/terrain.png"))


def build_emission():
    """Compose terrain_emission.png: the self-lit pixels of emissive tiles.

    Same dimensions and cell layout as terrain.png -- the runtime shader
    samples both atlases with the same UVs, so any size drift would smear
    glow across the wrong tiles. Almost every cell is transparent; only tiles
    flagged "emission" in tiles.json draw anything, and the flag and the
    painter table must agree exactly or somebody's lamp silently never glows.
    """
    reg = json.load(open(os.path.join(ROOT, "assets/tiles/tiles.json")))
    cols = reg["atlas_columns"]
    rows = max(t["atlas"][1] for t in reg["tiles"].values()) + 1
    c = Canvas(cols * CW, rows * CH)

    flagged = sorted(
        name for name, info in reg["tiles"].items()
        if isinstance(info.get("lighting"), dict) and info["lighting"].get("emission"))
    missing = sorted(set(flagged) - set(EMISSION_PAINTERS))
    if missing:
        raise SystemExit(
            "tiles.json flags tiles as emissive with no e_<name> painter here: %s "
            "(packs cannot supply emission pixels yet -- draw a painter)" % ", ".join(missing))
    orphaned = sorted(set(EMISSION_PAINTERS) - set(flagged))
    if orphaned:
        raise SystemExit(
            "emission painters exist for tiles not flagged \"emission\" in tiles.json: %s"
            % ", ".join(orphaned))

    for name in flagged:
        ax, ay = reg["tiles"][name]["atlas"]
        EMISSION_PAINTERS[name](c, ax * CW, ay * CH)
    c.save(os.path.join(ROOT, "assets/tiles/terrain_emission.png"))


def build_lights():
    """Draw the default PointLight2D falloff into assets/lights/point_light.png.

    A 64x64 radial glow quantized into discrete rings, because a smooth
    gradient magnified over crisp pixels reads as a vector overlay. Rendered
    with nearest filtering the stepped rings stay chunky at any window scale.
    White with brightness in both rgb and alpha, so the runtime tints it via
    Light2D.color and the same texture serves every emitter.
    """
    size = 64
    steps = 6
    c = Canvas(size, size)
    centre = (size - 1) / 2.0
    for y in range(size):
        for x in range(size):
            d = ((x - centre) ** 2 + (y - centre) ** 2) ** 0.5 / (size / 2.0)
            if d >= 1.0:
                continue
            t = (1.0 - d) ** 1.5
            level = round(t * steps) / steps
            v = int(level * 255 + 0.5)
            if v == 0:
                continue
            c.set(x, y, (v, v, v, v))
    path = os.path.join(ROOT, "assets/lights/point_light.png")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    c.save(path)


# --------------------------------------------------------------------------
# actor sprite sheet: 16x24 frames, 4 frames per row, 4 rows (dirs) per actor
# rows are down, left, right, up -- see ACTORS for the row block order
#
# Those names are grid directions, so on screen they are the four diagonals:
# down and right come toward the camera and show a face, up and left go away
# and show a back. Each is angled to the side it travels.
# --------------------------------------------------------------------------

FRAME_W, FRAME_H = 16, 24
FOOT_ROW = 22   # the row an actor stands on; scripts/actor_sprite.gd agrees

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
    SKD = tuple(max(0, v - 40) for v in S[:3]) + (255,)
    OUT = P["dark"]

    # down/right face the camera; down/left lean to the screen-left.
    front = dir_idx in (0, 2)
    lean = -1 if dir_idx in (0, 1) else 1

    # feet bob: frames 1 and 3 are the two walk poses
    swing = (0, 1, 0, -1)[frame]

    # An isometric shadow: wide and shallow, like the ground it lies on.
    for x in range(4, 12):
        c.set(ox + x, oy + FOOT_ROW, P["shadow"])
    for x in range(3, 13):
        c.set(ox + x, oy + FOOT_ROW - 1, P["shadow"])
    for x in range(5, 11):
        c.set(ox + x, oy + FOOT_ROW + 1, P["shadow_soft"])

    # legs
    c.rect(ox + 5, oy + 16, 3, 5 + swing, PA)
    c.rect(ox + 8, oy + 16, 3, 5 - swing, PA)
    c.rect(ox + 5, oy + 20 + swing, 3, 1, OUT)
    c.rect(ox + 8, oy + 20 - swing, 3, 1, OUT)

    # torso, narrowed on the trailing side so the body reads as turned
    c.rect(ox + 4, oy + 10, 8, 7, SH)
    c.rect(ox + 4, oy + 10, 8, 1, SHD)
    c.vline(ox + 3, oy + 11, 5, SHD)
    c.vline(ox + 12, oy + 11, 5, SHD)
    c.vline(ox + (12 if lean < 0 else 3), oy + 10, 6, SHD)

    # arms -- the leading arm swings, the trailing one is mostly hidden
    c.rect(ox + 3, oy + 11 - min(0, swing), 2, 5, S)
    c.rect(ox + 11, oy + 11 + min(0, swing), 2, 5, S)

    # head
    c.rect(ox + 4, oy + 3, 8, 8, S)
    c.rect(ox + 3, oy + 4, 1, 6, S)
    c.rect(ox + 12, oy + 4, 1, 6, S)

    if front:
        c.rect(ox + 3, oy + 2, 10, 3, H)
        c.rect(ox + 3, oy + 2, 10, 1, HD)
        c.vline(ox + 3, oy + 4, 3, H)
        c.vline(ox + 12, oy + 4, 3, H)
        # Both eyes, shifted toward the direction of travel; the far one sits
        # closer to the edge of the face, which is what sells the 3/4 turn.
        c.set(ox + 6 + lean, oy + 7, OUT)
        c.set(ox + 10 + lean, oy + 7, OUT)
        c.set(ox + 8 + lean, oy + 9, SKD)
        c.vline(ox + (3 if lean > 0 else 12), oy + 4, 4, HD)
    else:
        c.rect(ox + 3, oy + 2, 10, 7, H)
        c.rect(ox + 3, oy + 2, 10, 2, HD)
        c.vline(ox + (12 if lean > 0 else 3), oy + 3, 6, HD)
        c.set(ox + 8 + lean, oy + 9, HD)

    # Occupation-specific shapes make NPCs readable before dialogue opens.
    if role == "player":
        c.hline(ox + 5, oy + 10, 6, AC)                    # rust scarf
        c.set(ox + 8 + 2 * lean, oy + 11, AC)              # its loose end
        c.vline(ox + (10 if lean > 0 else 5), oy + 11, 5, AC)  # satchel strap
        c.set(ox + 11, oy + 16, AC)
    elif role == "bartender":
        c.hline(ox + 5, oy + 10, 6, AC)
        c.rect(ox + 6, oy + 11, 4, 6, AC)  # pale apron
        c.vline(ox + 9, oy + 12, 5, P["cloth"])
    elif role == "harbormaster":
        c.hline(ox + 4, oy + 2, 8, PA)  # square navy watch cap
        c.hline(ox + 5, oy + 1, 6, PA)
        if front:
            c.hline(ox + 5, oy + 9, 6, H)  # white beard
            c.hline(ox + 6, oy + 10, 4, H)
        c.set(ox + 10, oy + 12, AC)  # brass badge
    elif role == "villager":
        c.rect(ox + (11 if lean > 0 else 3), oy + 3, 2, 3, AC)  # hair ribbon
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
        "foot_row": FOOT_ROW,
        "actors": {name: {"row_block": i} for i, (name, *_ ) in enumerate(ACTORS)},
    }
    path = os.path.join(ROOT, "assets/sprites/actors.json")
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print("wrote %s" % os.path.relpath(path, ROOT))


if __name__ == "__main__":
    build_terrain()
    build_emission()
    build_lights()
    build_actors()
