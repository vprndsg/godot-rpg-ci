# Rendering — geometry, presentation, and where the numbers live

The contract everything else in `docs/architecture/` hangs off: how big a tile
is, how big the frame is, and which file you change when either moves.

Companions: [`scenery.md`](scenery.md) (depth planes and oversized art),
[`animation.md`](animation.md) (actor sheets), [`camera.md`](camera.md)
(framing), [`fx.md`](fx.md) (atmosphere), [`lighting.md`](lighting.md) (light),
and [`AGENTS.md`](AGENTS.md) (the checklists).

## Two files, two halves of one contract

```
assets/tiles/tiles.json          data/rendering.json
    tile_size   [64, 32]             viewport  [640, 360]
    cell_size   [64, 128]            window    [1280, 720]
    legacy_art  { ... }              stretch / scale_mode / filter
        |                                |          layers { ... }
        v                                v
  scripts/tile_registry.gd        scripts/presentation.gd
  tools/pixel.py::geometry()      tools/pixel.py::rendering()
        |                                |
        +----------------+---------------+
                         v
   scripts/iso.gd  ·  the camera  ·  collision shapes  ·  elevation
   the tileset bake  ·  the map renderer  ·  the contact sheets
```

**Nothing may hardcode 64, 32, 640 or 360.** Every dimension in the project is
derived from one of those two files. A `16` typed into a script is a number
that will be wrong the day the contract moves — in exactly one place, silently,
in a way no test can name.

`data/rendering.json` has one wrinkle: the engine cannot read it at boot, so
`project.godot` has to carry the display settings itself. The file is the
**source** and the project setting is the **copy**;
`Presentation.validate()` asserts they agree and `tests/test_rendering.gd`
fails CI when they drift. Change `data/rendering.json` first, then mirror it.

## The production geometry

| | value | derived from |
| --- | --- | --- |
| Ground diamond | **64 × 32** | `tiles.json` `tile_size` |
| Atlas cell | **64 × 128** | `tiles.json` `cell_size` |
| Headroom above the diamond | 48px | `(cell_h − tile_h) / 2` — `TileRegistry.footprint_top()` |
| Padding below | 48px | the same; it is what centres the footprint |
| One elevation level | **16px** | `Iso.elevation_height()` = `tile_h / 2` |
| Internal viewport | **640 × 360** | `rendering.json` `viewport` |
| Tiles across the frame | ~10 wide, ~11 rows deep | falls out of the two |

The diamond stays centred in its cell, which is what keeps the baked
tileset's `texture_origin` at zero — one fewer place for alignment to drift.

```
row 0    +----------------+   headroom, 48px. Walls, roofs, canopies grow
         |                |   up into this. Nothing may be taller.
row 47   |                |
row 48   |      /  \      |   the ground diamond, 64x32. The footprint, and
         |    /      \    |   the only part that meets its neighbours.
row 79   |      \  /      |
row 80   |                |   padding. Never drawn into. It centres the
row 127  +----------------+   footprint, which is why no offset is needed.
```

## Pixel-perfect presentation

`canvas_items` stretch + `integer` scale + `keep` aspect + nearest filtering.
The world is drawn at 640 × 360 and blown up by a whole number, so no pixel is
ever 1.5 pixels wide, and a wide monitor letterboxes rather than revealing more
world — which matters because a fixed-camera composition is authored for a
known frame.

## The CanvasLayer budget

One list, in `data/rendering.json`, read through `Presentation.layer(band)`.
Anything that creates a `CanvasLayer` asks; nothing invents a number.

| band | layer | who |
| --- | --- | --- |
| `screen_background` | −10 | `ScenePlanes` — flat skies behind everything |
| `world` | 0 | the default canvas: every world-space plane |
| `screen_foreground` | 2 | `ScenePlanes` — framing art over the world |
| `screen_fx` | 5 | `WorldFx` — fog, grading, quantization |
| `ui` | 10 | the dialogue box |
| `title` | 50 | the title card |
| `fade` | 100 | the Router's map-change fade |

**UI is above every world effect, always.** Grading the dialogue box along with
the forest is the specific failure that ordering prevents.

## Legacy art — read this before judging a screenshot

**Every shipped tile and every shipped character is placeholder art.**

The painters in `tools/gen_art.py` and the four townspeople were composed for
the pre-migration 32 × 16 diamond and 16 × 24 frame. They have not been
redrawn. The generators still paint at that geometry — recorded as
`legacy_art` in `tiles.json` — and magnify the finished atlas by an exact
integer factor (`pixel.art_scale()`, currently ×2) into the production cell.
Nearest neighbour, deterministic, no new colours.

That is a **migration path, not a look**. It exists so the game keeps booting,
the tests keep meaning something, and the web build keeps shipping while the
real art is made. What it does *not* do is represent the visual target:
`docs/shots/town.png` is a 32 × 16 world at double size, not a 64 × 32 world.

```
   tools/gen_art.py painters  ->  legacy 32x64 canvas  --x2-->  terrain.png
   assets/packs/<name>/sheet.png  --(anchor + pack scale)------>  (64x128 cells)
                                                    ^
                          new art enters HERE, at production scale
```

Two consequences worth holding on to:

- **New art is authored at 64 × 32 and skips all of this.** A pack, a
  PixelOver render, a redrawn painter — none of them go near `legacy_art`.
- **The scaling retires itself.** Delete `legacy_art` from `tiles.json` and
  `art_scale()` becomes 1; the pipeline stops magnifying and nothing else
  changes. Do that once the painters are gone.

The one legacy painter that had to change was `t_fence`: a picket foot sat a
quarter-pixel below its diamond, which magnified into a whole pixel of
overhang and failed `tools/ci.sh art`. That check is right, and the fix was
one pixel.

An imported pack drawn at a smaller grid magnifies too, but through its own
manifest: `"scale": 2` in `pack.json`, applied to the cell and the anchor
together. `assets/packs/README.md` has the details.

## What CI checks

- `tests/test_rendering.gd` — the contract matches `project.godot`, the
  viewport is 16:9, the presentation is pixel-perfect, the layer budget is a
  total order with UI on top, the five planes exist, all collision is in the
  playable plane, plane ordering is deterministic, sorting is by ground contact.
- `tests/test_iso.gd` — the projection matches a real `TileMapLayer` at the
  production scale; the geometry comes from the registry; collision footprints
  derive from the grid; elevation lifts by exactly one level; `cell_bounds()`
  generalises `grid_bounds()`.
- `tools/ci.sh art` — every tile, drawn or imported, stands on its diamond.
- `tools/ci.sh generate` + the CI drift check — the atlas, the emission atlas,
  the light falloff, the actor sheet, the manifest, the contact sheets and the
  map renders are all reproducible from their sources.

## Moving the geometry again

It is a two-number edit, and it is meant to be:

1. Change `tile_size` and `cell_size` in `assets/tiles/tiles.json`. Keep the
   diamond 2:1 and the cell's spare height even, or the footprint stops being
   centred.
2. If the new size is not a whole multiple of `legacy_art`, either redraw the
   painters or drop `legacy_art` — `pixel.art_scale()` refuses a fractional
   factor rather than resampling pixel art.
3. Update the emit radii and offsets in `tiles.json` (they are screen pixels)
   and any pack `scale`.
4. `tools/ci.sh generate`, then `tools/ci.sh test`, then look at
   `docs/art/atlas.png` and `docs/art/map_port_azure_town.png`.

The engine, `Iso`, the collision shapes, the camera limits, the elevation
maths and all three Python renderers follow on their own.
