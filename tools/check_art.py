#!/usr/bin/env python3
"""Check that every tile in the atlas actually stands on the isometric grid.

    python3 tools/check_art.py

This is the gate that makes imported art safe. A painter in tools/gen_art.py
builds from `ground()` and `block()` and lands on the footprint by
construction; a sheet downloaded from itch.io has never heard of this project
and will sit wherever its author put it. One tile hanging eight pixels low is
invisible on a contact sheet and unmistakable the moment it is next to forty
others, which is exactly the class of mistake worth failing a build over.

The contract, in one line: **a sprite may rise as far above its cell as it
likes, and may not sink below the ground diamond it stands on.**

That is what lets a tree overhang its neighbours while its trunk still meets
the floor at a known place -- and it is the only rule that has to hold for
y-sorting by ground contact to order the world correctly.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import packs
from pixel import ROOT, footprint_top, geometry, load_png

# A pixel is judged by its centre, and a sprite is allowed to touch the very
# edge of its footprint, so compare against the diamond with half a pixel of
# slack rather than rejecting art for landing exactly on the boundary.
SLACK = 0.5


def ground_limit(x, tw, th, cw):
    """Lowest row an opaque pixel may occupy in column x.

    The ground diamond's lower boundary, as a continuous line rather than the
    stepped pixel mask -- art is not obliged to reproduce the mask's staircase,
    only to stay on the surface it describes.
    """
    centre_x = cw / 2.0
    centre_y = footprint_top() + th / 2.0
    across = abs(x + 0.5 - centre_x) / (tw / 2.0)
    return centre_y + (th / 2.0) * (1.0 - across)


def check_atlas():
    registry = json.load(open(os.path.join(ROOT, "assets/tiles/tiles.json")))
    tw, th, cw, ch = geometry()
    atlas_path = os.path.join(ROOT, registry["atlas"].replace("res://", ""))
    atlas = load_png(atlas_path)

    limits = [ground_limit(x, tw, th, cw) + SLACK for x in range(cw)]
    failures = []

    for name in sorted(registry["tiles"]):
        info = registry["tiles"][name]
        ax, ay = info["atlas"]
        if (ax + 1) * cw > atlas.w or (ay + 1) * ch > atlas.h:
            failures.append("%-14s cell %s is outside the %dx%d atlas" % (name, info["atlas"], atlas.w, atlas.h))
            continue

        worst = None
        for y in range(ch - 1, -1, -1):
            for x in range(cw):
                if not atlas.get(ax * cw + x, ay * ch + y)[3]:
                    continue
                if y > limits[x]:
                    if worst is None or y > worst[1]:
                        worst = (x, y)
        if worst is not None:
            x, y = worst
            failures.append(
                "%-14s sinks below its own ground: a pixel at column %d row %d, "
                "but the footprint there ends at row %d"
                % (name, x, y, int(limits[x])))

    return failures, len(registry["tiles"])


def check_packs():
    failures = []
    for name in packs.pack_names():
        manifest = packs.load(name)
        issues = packs.problems(manifest)
        if issues:
            failures.extend(issues)
            continue
        for tile_name in sorted(manifest["tiles"]):
            _, spilled = packs.cell_pixels(manifest, tile_name)
            if spilled:
                failures.append(
                    "pack '%s' tile '%s' spills %d pixels outside the atlas cell -- "
                    "move its anchor, or adopt the pack's geometry in tiles.json"
                    % (name, tile_name, len(spilled)))
    return failures


if __name__ == "__main__":
    atlas_failures, tile_count = check_atlas()
    pack_failures = check_packs()

    for line in atlas_failures + pack_failures:
        print("  x %s" % line)

    if atlas_failures or pack_failures:
        print("\nart check FAILED: %d problem(s)" % (len(atlas_failures) + len(pack_failures)))
        sys.exit(1)

    installed = packs.pack_names()
    print("art check ok: %d tiles stand on the footprint%s"
          % (tile_count,
             ", %d pack(s) fit their cells" % len(installed) if installed else ""))
