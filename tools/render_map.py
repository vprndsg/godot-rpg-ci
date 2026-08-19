#!/usr/bin/env python3
"""Composite a map from maps/*.json into a viewable PNG.

    python3 tools/render_map.py                     # every map, 3x
    python3 tools/render_map.py port_azure_town     # one map
    python3 tools/render_map.py --scale 4 --grid --annotate

Writes docs/art/map_<id>.png.

No Godot and no browser: this reads the same tiles.json the game reads, walks
the grid back to front and stamps terrain.png into a canvas, so it runs in a
few seconds anywhere. That matters more now that the world is isometric --
tiles overlap their neighbours, and whether a wall sits *on* its cell or eight
pixels off it is invisible on a single magnified tile and obvious the moment
you see a hundred of them together.

The projection here is the same one scripts/iso.gd uses, which is the same one
Godot's TILE_SHAPE_ISOMETRIC uses. If this render looks right, the game does.

--annotate overlays spawns, portals, NPCs and signs, which is what you want
when reviewing a map's layout rather than its art.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pixel import ROOT, Canvas, diamond_span, draw_text, load_png, rgb

LAYERS = ("ground", "objects")
GRID = (255, 255, 255, 40)
GRID_MAJOR = (255, 255, 255, 90)
MISSING = rgb("ff00d0")

MARKERS = {
    "spawn":  rgb("57d08a"),
    "portal": rgb("f2c14e"),
    "npc":    rgb("6fa8ff"),
    "sign":   rgb("c98ce0"),
}


def map_ids():
    maps_dir = os.path.join(ROOT, "maps")
    return sorted(f[:-5] for f in os.listdir(maps_dir) if f.endswith(".json"))


def cell_stamp(atlas, ax, ay, cw, ch, drawn_h):
    """The non-transparent pixels of one atlas cell, as (dx, dy, colour).

    Cells are mostly empty -- a flat ground tile fills an eighth of one -- so
    collecting the pixels once and stamping only those is what keeps a whole
    town under a few seconds.
    """
    out = []
    for y in range(drawn_h):
        for x in range(cw):
            colour = atlas.get(ax * cw + x, ay * ch + y)
            if colour[3]:
                out.append((x, y, colour))
    return out


def stamp(dst, pixels, ox, oy, scale):
    for dx, dy, colour in pixels:
        x, y = ox + dx * scale, oy + dy * scale
        if colour[3] == 255:
            dst.rect(x, y, scale, scale, colour)
        else:
            for sy in range(scale):
                for sx in range(scale):
                    dst.blend(x + sx, y + sy, colour)


def outline(c, ox, oy, tw, th, scale, colour):
    """Trace one cell's diamond, for --grid and --annotate."""
    for y in range(th):
        x0, width = diamond_span(y, tw, th)
        for x in (x0, x0 + width - 1):
            for sy in range(scale):
                for sx in range(scale):
                    c.blend(ox + x * scale + sx, oy + y * scale + sy, colour)


def render(map_id, scale=3, grid=False, annotate=False):
    reg = json.load(open(os.path.join(ROOT, "assets/tiles/tiles.json")))
    atlas = load_png(os.path.join(ROOT, os.path.relpath(reg["atlas"].replace("res://", ""))))
    tw, th = (int(v) for v in reg["tile_size"])
    cw, ch = (int(v) for v in reg["cell_size"])
    foot = (ch - th) // 2
    drawn_h = foot + th      # the cell rows a painter is allowed to use

    data = json.load(open(os.path.join(ROOT, "maps", map_id + ".json")))
    legend = data.get("legend", {})

    rows = data.get("ground", [])
    height = len(rows)
    width = max((len(r) for r in rows), default=0)
    if width == 0 or height == 0:
        raise SystemExit("map '%s' has no ground layer" % map_id)

    # A diamond grid leans left as it descends, so the far corner sits at a
    # negative x; shift everything right by that much. The top margin is the
    # headroom a tall tile on the back row draws into.
    span = width + height
    origin_x = (height - 1) * tw // 2
    origin_y = foot
    bar = 16
    c = Canvas(span * tw // 2 * scale, (origin_y + span * th // 2) * scale + bar)
    c.rect(0, 0, c.w, c.h, rgb("14161c"))

    def cell_origin(cx, cy):
        """Top-left of a cell's atlas region, in canvas pixels."""
        px = (cx - cy) * tw // 2 + tw // 2 + origin_x - cw // 2
        py = (cx + cy) * th // 2 + th // 2 + origin_y - ch // 2
        return px * scale, py * scale

    stamps = {}
    unknown = set()

    def draw_cell(layer, cx, cy):
        row = data.get(layer, [])
        if cy >= len(row) or cx >= len(row[cy]):
            return
        ch_ = row[cy][cx]
        if ch_ == " ":
            return
        name = legend.get(ch_)
        px, py = cell_origin(cx, cy)
        if name is None or name not in reg["tiles"]:
            unknown.add(ch_)
            outline(c, px + (cw - tw) // 2 * scale, py + foot * scale, tw, th, scale, MISSING)
            return
        if name not in stamps:
            ax, ay = reg["tiles"][name]["atlas"]
            stamps[name] = cell_stamp(atlas, ax, ay, cw, ch, drawn_h)
        stamp(c, stamps[name], px, py, scale)

    # Ground first and flat, exactly like the un-sorted ground TileMapLayer.
    for y in range(height):
        for x in range(width):
            draw_cell("ground", x, y)

    # Then everything that stands up, back to front. Screen depth in a diamond
    # grid is x + y, which is precisely what Godot's y-sorting compares.
    for x, y in sorted(((x, y) for y in range(height) for x in range(width)),
                       key=lambda p: (p[0] + p[1], p[0])):
        draw_cell("objects", x, y)

    if grid:
        for y in range(height):
            for x in range(width):
                px, py = cell_origin(x, y)
                major = x % 5 == 0 or y % 5 == 0
                outline(c, px + (cw - tw) // 2 * scale, py + foot * scale,
                        tw, th, scale, GRID_MAJOR if major else GRID)

    if annotate:
        def mark(cx, cy, kind, label):
            colour = MARKERS[kind]
            px, py = cell_origin(cx, cy)
            px += (cw - tw) // 2 * scale
            py += foot * scale
            outline(c, px, py, tw, th, scale, colour)
            draw_text(c, px + tw * scale // 2 - 6, py + th * scale // 2 - 2, label, colour)

        for name, at in data.get("spawns", {}).items():
            mark(at[0], at[1], "spawn", name[:6])
        for p in data.get("portals", []):
            mark(p["at"][0], p["at"][1], "portal", str(p.get("to", ""))[:8])
        for n in data.get("npcs", []):
            mark(n["at"][0], n["at"][1], "npc", str(n.get("npc", ""))[:8])
        for s in data.get("signs", []):
            mark(s["at"][0], s["at"][1], "sign", "sign")

    caption = "%s  %dx%d cells  isometric %dx%d  %dx zoom" % (
        map_id, width, height, tw, th, scale)
    if unknown:
        caption += "  MISSING LEGEND: " + " ".join(sorted(unknown))
    draw_text(c, 4, c.h - bar + 5, caption, MISSING if unknown else rgb("8b93a6"))

    c.save(os.path.join(ROOT, "docs/art/map_%s.png" % map_id))
    return unknown


if __name__ == "__main__":
    args = [a for a in sys.argv[1:]]
    scale = 3
    if "--scale" in args:
        i = args.index("--scale")
        scale = int(args[i + 1])
        del args[i:i + 2]
    grid = "--grid" in args
    annotate = "--annotate" in args
    wanted = [a for a in args if not a.startswith("--")] or map_ids()

    problems = False
    for map_id in wanted:
        if render(map_id, scale=scale, grid=grid, annotate=annotate):
            problems = True
    sys.exit(1 if problems else 0)
