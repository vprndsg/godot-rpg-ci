#!/usr/bin/env python3
"""Third-party art packs: manifests, licences, and landing a foreign cell on our grid.

Art does not have to be drawn by tools/gen_art.py. A tile in
assets/tiles/tiles.json may instead name a `pack`, and its pixels are then cut
from a sheet somebody else made -- itch.io, a bundle, a commission.

The important part is that this does **not** cost the reproducibility gate.
The pack's sheet is a committed *source*, exactly like tiles.json, and
terrain.png stays a build output: `tools/ci.sh generate` rebuilds it from
painters plus pack sheets and CI still fails if the result differs from what
was committed. Nothing about the art becoming hand-made makes the build
unreproducible -- only art that lives *only* in terrain.png would do that.

A pack is a directory under assets/packs/ holding its sheet and a pack.json:

    {
      "name": "seaside-iso",
      "source": "https://someone.itch.io/seaside-iso",
      "author": "Someone",
      "license": "CC-BY-4.0",
      "attribution": "Seaside Iso by Someone, CC-BY 4.0",
      "sheet": "sheet.png",
      "cell_size": [64, 96],
      "anchor": [32, 80],
      "tiles": { "quay": [0, 0], "crane": [1, 0] }
    }

`anchor` is the one number that matters. It is the pixel *inside a source
cell* that should end up at the centre of our ground diamond -- normally the
point the sprite stands on. Everything else about fitting foreign art to this
grid falls out of it.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pixel import ROOT, geometry, load_png

PACKS_DIR = os.path.join(ROOT, "assets/packs")

# Fields without which a pack cannot be shipped. Licence and attribution are
# not paperwork: a pack whose terms nobody wrote down is a pack nobody can
# safely publish, and this repo publishes to Pages on every merge.
REQUIRED = ("name", "source", "author", "license", "sheet", "cell_size", "anchor", "tiles")


def pack_names():
    if not os.path.isdir(PACKS_DIR):
        return []
    return sorted(d for d in os.listdir(PACKS_DIR)
                  if os.path.isfile(os.path.join(PACKS_DIR, d, "pack.json")))


def load(name):
    """One pack's manifest, with `_dir` added so callers can find its sheet."""
    path = os.path.join(PACKS_DIR, name, "pack.json")
    with open(path) as f:
        manifest = json.load(f)
    manifest["_dir"] = os.path.join(PACKS_DIR, name)
    return manifest


def load_all():
    return {name: load(name) for name in pack_names()}


def problems(manifest):
    """Everything wrong with a manifest, in plain language."""
    out = []
    name = manifest.get("name", "?")
    for field in REQUIRED:
        if field not in manifest:
            out.append("pack '%s' has no '%s'" % (name, field))
    if out:
        return out

    for field in ("cell_size", "anchor"):
        value = manifest[field]
        if not (isinstance(value, list) and len(value) == 2):
            out.append("pack '%s': %s must be [x, y]" % (name, field))
    if out:
        return out

    sheet = os.path.join(manifest["_dir"], manifest["sheet"])
    if not os.path.isfile(sheet):
        out.append("pack '%s' names sheet '%s', which is not there" % (name, manifest["sheet"]))
        return out

    cw, ch = manifest["cell_size"]
    ax, ay = manifest["anchor"]
    if not (0 <= ax < cw and 0 <= ay < ch):
        out.append("pack '%s': anchor %s is outside its own %dx%d cell"
                   % (name, manifest["anchor"], cw, ch))

    image = load_png(sheet)
    columns = image.w // cw
    rows = image.h // ch
    if columns == 0 or rows == 0:
        out.append("pack '%s': the %dx%d sheet is smaller than one %dx%d cell"
                   % (name, image.w, image.h, cw, ch))
        return out
    for tile_name, at in manifest["tiles"].items():
        if not (isinstance(at, list) and len(at) == 2):
            out.append("pack '%s': tile '%s' must give [column, row]" % (name, tile_name))
            continue
        if not (0 <= at[0] < columns and 0 <= at[1] < rows):
            out.append("pack '%s': tile '%s' at %s is outside the %dx%d cell grid"
                       % (name, tile_name, at, columns, rows))
    return out


def offset(manifest):
    """Where a source cell's top-left lands inside one of our atlas cells.

    Our ground diamond is centred in our cell; the pack's anchor is the point
    that has to sit at that centre. The difference is the whole transform.
    """
    tw, th, cw, ch = geometry()
    ax, ay = manifest["anchor"]
    return (cw // 2 - ax, (ch - th) // 2 + th // 2 - ay)


def cell_pixels(manifest, tile_name, sheet=None):
    """(x, y, rgba) of one pack tile, already in our cell's coordinates.

    Returns a second list of pixels that fell outside our cell. Those are not
    silently dropped: a sprite that does not fit is a sprite whose pack needs
    a different anchor, or whose geometry the project should adopt wholesale.
    """
    _, _, cw, ch = geometry()
    if sheet is None:
        sheet = load_png(os.path.join(manifest["_dir"], manifest["sheet"]))
    scw, sch = manifest["cell_size"]
    col, row = manifest["tiles"][tile_name]
    dx, dy = offset(manifest)

    inside, spilled = [], []
    for sy in range(sch):
        for sx in range(scw):
            colour = sheet.get(col * scw + sx, row * sch + sy)
            if not colour[3]:
                continue
            x, y = sx + dx, sy + dy
            (inside if 0 <= x < cw and 0 <= y < ch else spilled).append((x, y, colour))
    return inside, spilled


def tile_owner(registry):
    """tile name -> pack name, for every tile whose art is imported."""
    return {name: info["pack"] for name, info in registry["tiles"].items() if "pack" in info}


def credits_markdown():
    """The attribution block, built from the manifests rather than by hand."""
    packs = load_all()
    lines = ["# Credits", "",
             "Port Azure's own art is generated by `tools/gen_art.py` and is CC0.",
             "The art below came from elsewhere and carries its own terms.", ""]
    if not packs:
        lines += ["No third-party art packs are installed.", ""]
        return "\n".join(lines)
    for name in sorted(packs):
        p = packs[name]
        lines.append("## %s" % p.get("name", name))
        lines.append("")
        lines.append("- **Author:** %s" % p.get("author", "?"))
        lines.append("- **Source:** %s" % p.get("source", "?"))
        lines.append("- **Licence:** %s" % p.get("license", "?"))
        if p.get("attribution"):
            lines.append("- **Required attribution:** %s" % p["attribution"])
        lines.append("- **Tiles:** %s" % ", ".join(sorted(p.get("tiles", {}))))
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    if "--credits" in sys.argv:
        path = os.path.join(ROOT, "CREDITS.md")
        with open(path, "w") as f:
            f.write(credits_markdown())
        print("wrote %s" % os.path.relpath(path, ROOT))
        raise SystemExit(0)

    found = pack_names()
    if not found:
        print("no packs installed (assets/packs/ is empty)")
        raise SystemExit(0)
    bad = False
    for name in found:
        manifest = load(name)
        issues = problems(manifest)
        if issues:
            bad = True
            for issue in issues:
                print("  x %s" % issue)
            continue
        dx, dy = offset(manifest)
        print("  ok %-20s %d tiles, offset %+d%+d" % (name, len(manifest["tiles"]), dx, dy))
        for tile_name in sorted(manifest["tiles"]):
            _, spilled = cell_pixels(manifest, tile_name)
            if spilled:
                bad = True
                print("     x '%s' spills %d pixels outside the atlas cell -- "
                      "move the anchor, or adopt the pack's geometry in tiles.json"
                      % (tile_name, len(spilled)))
    raise SystemExit(1 if bad else 0)
