# Imported art packs

Art in this project does not have to be drawn by `tools/gen_art.py`. Drop a
sheet you bought or downloaded in here, point a tile at it, and it ships.

## Why this does not cost the reproducibility gate

The rule everywhere else in this repo is that generated files are never
hand-edited, and CI proves it by regenerating them and failing on any
difference. Imported art does not break that, because a pack's sheet is a
**source**, like `tiles.json` — not an output. `tools/ci.sh generate` still
rebuilds `assets/tiles/terrain.png` from scratch every time, cutting some
cells from painters and some from pack sheets, and the CI drift check still
means exactly what it meant before.

The one thing that *would* break it is pasting pixels straight into
`terrain.png`. Don't; they will be gone on the next build.

## Installing a pack

1. `mkdir assets/packs/<name>/` and put the sheet in it.
2. Copy `example-harbour/pack.json` next to it and fill it in.
3. `tools/ci.sh art` — tells you whether the sprites fit the cell and land on
   the ground diamond, before you have wired anything up.
4. Add tiles to `assets/tiles/tiles.json` with `"pack": "<name>"`:

   ```json
   "quay": { "atlas": [4, 4], "solid": true, "pack": "seaside-iso" }
   ```

   The tile is looked up in the pack by the same name. Add `"pack_tile"` if
   the pack calls it something else.
5. `tools/ci.sh generate` then `tools/ci.sh test`. Look at
   `docs/art/atlas.png`: every tile is drawn with its ground diamond outlined.

## The manifest

```json
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
```

`source`, `author` and `license` are required. `CREDITS.md` is generated from
them, and `tests/test_data.gd` fails if a tile names a pack that cannot say
where it came from — this repo publishes to the web on every merge, so that is
not paperwork.

**`anchor` is the number that matters.** It is the pixel *inside a source
cell* that should end up at the centre of the ground diamond — normally the
point the sprite stands on. Everything else about fitting foreign art to this
grid falls out of it. If a sprite lands too high or too low, the anchor is
wrong; nothing else needs touching.

## When a pack does not fit

`tools/ci.sh art` reports two distinct failures, with different fixes.

**"spills N pixels outside the atlas cell"** — the sprite is bigger than a
`cell_size` from `tiles.json` (currently 32×64: a 32×16 diamond with 24px of
headroom above it). Either the anchor is wrong, or the pack is simply drawn at
a larger scale.

If it is scale, **adopt the pack's geometry instead of fighting it.** Change
`tile_size` and `cell_size` in `tiles.json` to match, and the engine, the
projection in `scripts/iso.gd`, the collision shapes, the camera and the map
renderer all follow — they read the registry rather than hardcoding numbers,
and `tests/test_iso.gd` re-checks the projection against Godot at the new size.
The hand-drawn painters in `tools/gen_art.py` are the one thing that will not
follow: they are composed for a 32×16 diamond and would need redrawing. If the
pack is replacing them anyway, that cost is zero.

Do not downscale pixel art to make it fit. It will look worse than anything
this repo can draw.

**"sinks below its own ground"** — the sprite hangs below the diamond it
stands on. That breaks y-sorting: the whole ordering of the world assumes a
sprite may rise as far above its cell as it likes and never sink below it.
Usually the anchor is too high, or the sheet has a drop shadow baked in below
the contact point.

## About the example

`example-harbour` is a placeholder authored for this repository, not something
worth shipping. It exists so `tools/ci.sh generate` slices a real pack on every
run, which means the import path is tested even when no real pack is installed.
Delete the directory and its two entries in `tiles.json` once you have art you
actually want.
