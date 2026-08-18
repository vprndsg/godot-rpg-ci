#!/usr/bin/env python3
"""Composite a map from maps/*.json into a viewable PNG.

    python3 tools/render_map.py                     # every map, 3x
    python3 tools/render_map.py port_azure_town     # one map
    python3 tools/render_map.py --scale 4 --grid --annotate

Writes docs/art/map_<id>.png.

No Godot and no browser: this reads the same tiles.json legend the game reads
and stamps terrain.png straight into a canvas, so it runs in about a second
anywhere. That matters because tiling seams, missing shadows and repetition
are invisible on a single magnified tile and obvious the moment you see forty
of them next to each other.

--annotate overlays spawns, portals, NPCs and signs, which is what you want
when reviewing a map's layout rather than its art.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pixel import ROOT, Canvas, blit, draw_text, load_png, rgb

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


def render(map_id, scale=3, grid=False, annotate=False):
    reg = json.load(open(os.path.join(ROOT, "assets/tiles/tiles.json")))
    atlas = load_png(os.path.join(ROOT, os.path.relpath(reg["atlas"].replace("res://", ""))))
    ts = int(reg.get("tile_size", 16))
    data = json.load(open(os.path.join(ROOT, "maps", map_id + ".json")))
    legend = data.get("legend", {})

    rows = data.get("ground", [])
    height = len(rows)
    width = max((len(r) for r in rows), default=0)
    if width == 0 or height == 0:
        raise SystemExit("map '%s' has no ground layer" % map_id)

    cell = ts * scale
    bar = 16
    c = Canvas(width * cell, height * cell + bar)
    c.rect(0, 0, c.w, c.h, rgb("14161c"))

    unknown = set()
    for layer in LAYERS:
        for y, row in enumerate(data.get(layer, [])):
            for x, ch in enumerate(row):
                if ch == " ":
                    continue
                name = legend.get(ch)
                if name is None or name not in reg["tiles"]:
                    unknown.add(ch)
                    c.rect(x * cell, y * cell, cell, cell, MISSING)
                    continue
                ax, ay = reg["tiles"][name]["atlas"]
                blit(c, atlas, x * cell, y * cell,
                     sx=ax * ts, sy=ay * ts, w=ts, h=ts, factor=scale)

    if grid:
        for x in range(width + 1):
            colour = GRID_MAJOR if x % 5 == 0 else GRID
            for y in range(height * cell):
                c.blend(min(x * cell, c.w - 1), y, colour)
        for y in range(height + 1):
            colour = GRID_MAJOR if y % 5 == 0 else GRID
            for x in range(c.w):
                c.blend(x, min(y * cell, height * cell - 1), colour)

    if annotate:
        def mark(cx, cy, kind, label):
            colour = MARKERS[kind]
            x, y = cx * cell, cy * cell
            c.frame(x, y, cell, cell, colour)
            c.frame(x + 1, y + 1, cell - 2, cell - 2, colour)
            draw_text(c, x + 2, y + 2, label, colour, scale_=1)

        for name, at in data.get("spawns", {}).items():
            mark(at[0], at[1], "spawn", name[:6])
        for p in data.get("portals", []):
            mark(p["at"][0], p["at"][1], "portal", str(p.get("to", ""))[:8])
        for n in data.get("npcs", []):
            mark(n["at"][0], n["at"][1], "npc", str(n.get("npc", ""))[:8])
        for s in data.get("signs", []):
            mark(s["at"][0], s["at"][1], "sign", "sign")

    caption = "%s  %dx%d  %dx zoom" % (map_id, width, height, scale)
    if unknown:
        caption += "  MISSING LEGEND: " + " ".join(sorted(unknown))
    draw_text(c, 4, height * cell + 5, caption,
              MISSING if unknown else rgb("8b93a6"), scale_=1)

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
