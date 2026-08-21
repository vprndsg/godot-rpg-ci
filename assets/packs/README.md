# Imported art packs

Art in this project does not have to be drawn by `tools/gen_art.py`. Drop a
sheet you bought, downloaded or rendered in here, point something at it, and
it ships.

This is the intended production pipeline, not a side door:

```
   Meshy / other 3D source
            |
   Blender: cleanup, rigging, animation, camera
            |
   PixelOver: render to pixels at the production scale
            |
   assets/packs/<name>/          <- a SOURCE, committed
            |
   +--------+--------+------------------+
   |                 |                  |
 tiles.json     actors.json      scenery.json
 (a tile)      (a character)     (a prop of any size)
```

All three consumers use the same conventions: an anchor that is the pixel
touching the ground, optional `_normal` / `_emission` siblings, and a licence
that travels with the pixels.

**The middle two stages have a headless substitute.** Drop the model in
`inbox/` and run `tools/ci.sh inbox`: it points a dimetric camera at the mesh,
renders every grid direction and animation frame, quantises the result to a
small palette, and writes the pack directory below — including its `actors`
block — in about thirty seconds with no desktop involved.
`docs/architecture/inbox.md` is that pipeline. Everything from
`assets/packs/<name>/` onward is identical either way, which is the point: a
pack baked here and a pack exported from PixelOver are the same kind of thing.

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
4. Point something at it. **A tile**, in `assets/tiles/tiles.json`:

   ```json
   "quay": { "atlas": [4, 4], "solid": true, "pack": "seaside-iso" }
   ```

   The tile is looked up in the pack by the same name. Add `"pack_tile"` if
   the pack calls it something else.

   **A scenery prop** — anything too big, too oddly shaped or too decorative to
   be a tile — in `assets/scenery/scenery.json`, pointing straight at the sheet:

   ```json
   "redwood_trunk": {
     "texture": "res://assets/packs/redwood/trunk.png",
     "anchor": [180, 396], "plane": "playable",
     "footprint": [[0, 0]], "requires_solid": true,
     "pack": "redwood"
   }
   ```

   **A character** — an `actors` block in `pack.json`, giving its frame size,
   anchor, directions and clips. `tools/gen_art.py` folds that into the
   generated `assets/sprites/actors.json`, which is why a character can be
   imported without hand-editing a generated file. See
   `docs/architecture/animation.md` for the schema, and note that
   `tools/ci.sh inbox` writes this block for you.

5. `tools/ci.sh generate` then `tools/ci.sh test`. Look at
   `docs/art/atlas.png` (tiles, with the ground diamond outlined) or
   `docs/art/actors.png` (characters, laid out from the manifest).

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
  "scale": 1,
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

**`scale` is the second one.** A whole-number nearest-neighbour magnification,
applied to the cell and the anchor together, for a sheet drawn on a smaller
grid than ours. It never goes below 1 — downscaling pixel art destroys it, and
an oversized sheet is a reason to adopt its geometry in `tiles.json` instead.
The bundled `example-harbour` uses `"scale": 2`, because it was drawn for the
grid this project had before the 64×32 migration; that is exactly the case
`scale` exists for.

## Lighting-aware packs

Lighting behaviour is not part of the manifest, because it is not part of the
pixels: it lives on the tile entry in `tiles.json`, exactly as it does for
drawn tiles. An imported bollard that should glow is:

```json
"bollard": {
  "atlas": [2, 4], "solid": true, "pack": "example-harbour",
  "lighting": { "emit": { "color": "ffd27a", "radius": 36, "offset": [0, -12] } }
}
```

and an imported wall that should block light adds
`"lighting": { "occluder": true }`. Emitters, occluders and everything else in
the schema (`docs/architecture/AGENTS.md`) work identically for pack tiles —
the runtime cannot tell where a tile's pixels came from. So a redwood pack
says "collide on my whole diamond, occlude on my trunk
(`{\"shape\": \"diamond\", \"scale\": 0.5}`), emit nothing", and a saloon pack
gives its walls `occluder: true`, its lamps an `emit`, and its windows
`emission` — all in `tiles.json`, no engine changes.

## Material maps

A pack may ship layout-identical siblings beside its diffuse sheet. **The name
is the whole contract** — nothing in `pack.json` declares them, and the slicer
picks them up because they are there:

- `sheet_normal.png` — a normal map, sliced into `terrain_normal.png`.
  `tools/build_tileset.gd` wires that into a `CanvasTexture` the moment it
  exists, and every 2D light starts shading tiles by their normals. Neutral
  flat is `8080ff`; cells no pack supplies are filled with it automatically, so
  a half-authored atlas is not expressible.
- `sheet_emission.png` — self-lit pixels, sliced into `terrain_emission.png`
  alongside the `e_<name>` painters. A pack tile flagged `"emission": true`
  takes its glow from here, and the build fails with a clear message if the
  sibling is missing.

Both are sliced through **exactly the same anchor arithmetic** as the diffuse,
so a normal map cannot drift a pixel away from the art it shades. If the sheets
disagree in size, `tools/ci.sh art` says so.

Actors and scenery props name their material maps explicitly instead
(`"normal"` / `"emission"` in the manifest or the registry), because their
sheets are not sliced into a shared atlas. Same suffixes, same rule: always
layout-identical to the diffuse.

## When a pack does not fit

`tools/ci.sh art` reports two distinct failures, with different fixes.

**"spills N pixels outside the atlas cell"** — the sprite is bigger than a
`cell_size` from `tiles.json` (currently 64×128: a 64×32 diamond with 48px of
headroom above it and 48px of padding below). Either the anchor is wrong, the
`scale` is too high, or the pack is simply drawn at a larger scale.

If it is genuinely just *big* — a redwood, a cliff face, a saloon front — it
may not want to be a tile at all. `assets/scenery/scenery.json` takes sprites
of any size with a one-cell footprint; see `docs/architecture/scenery.md`.

If it is scale, **adopt the pack's geometry instead of fighting it.** Change
`tile_size` and `cell_size` in `tiles.json` to match, and the engine, the
projection in `scripts/iso.gd`, the collision shapes, the camera limits, the
elevation lift and all three renderers follow — they read the registry rather
than hardcoding numbers, and `tests/test_iso.gd` re-checks the projection
against Godot at the new size. `docs/architecture/rendering.md` has the
procedure.

The hand-drawn painters in `tools/gen_art.py` are the one thing that will not
follow: they are composed for a 32×16 diamond and are magnified into the
production cell by an exact integer factor. A new size that is not a whole
multiple of theirs means redrawing them — or deleting `legacy_art` from
`tiles.json`, which retires the magnification entirely. If the pack is
replacing them anyway, that cost is zero.

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
run, which means the import path is tested even when no real pack is installed
— including, since the 64×32 migration, the `"scale": 2` path.

Delete the directory and its two entries in `tiles.json` once you have art you
actually want.

`example-quadruped` is the same idea for the other half of the pipeline: a
model baked by `tools/ci.sh inbox`, kept so that the pack-actor path — a
`pack.json` `actors` block reaching `assets/sprites/actors.json` — is exercised
on every `generate` rather than only when someone has a character to import.
Its `source/model.glb` is generated by `tests/fixtures/make_model.py`. Delete the
directory once a real character has taken its place; nothing places it on a
map, so nothing breaks.
