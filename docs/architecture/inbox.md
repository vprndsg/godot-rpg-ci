# The inbox — a 3D model to a shipped sprite, in one command

```
tools/ci.sh inbox
```

Drop a `.glb` in `inbox/`, run that, and either the asset is installed and
every gate is green, or you get one specific error with the fix in it. There
is no step in between that needs a person to look at something and decide.

That is the whole design goal. `assets/packs/README.md` describes the
production path as *Meshy → Blender → PixelOver → a pack*, and every stage of
that except the last needs a desktop, a licence and a human. This pipeline is
the same path with the middle replaced by something that runs headless in
about thirty seconds.

```
inbox/coyote.glb
      |
      |  tools/glb.py         read mesh, skin, materials, animation
      |  tools/sprite_bake.py point a dimetric camera at it, once per
      |                       grid direction per animation frame
      v
assets/packs/coyote/
      pack.json     the manifest, including an `actors` block
      sheet.png     the baked sprite sheet
      source/       the model it was baked from, kept out of
                    Godot's importer by a .gdignore
      |
      |  tools/gen_art.py     folds pack actors into the generated manifest
      v
assets/sprites/actors.json    -> the runtime, the validator, the contact sheet
```

## What "run the pipeline" actually does

1. **Identify.** Everything in `inbox/` with a suffix the pipeline knows
   (`.glb`, `.gltf`). Anything else is ignored and named in the output, so a
   stray screenshot is never silently mistaken for a job.
2. **Settle the settings.** `data/inbox.json` `defaults`, then that file's
   `assets.<name>` block, then a sidecar `inbox/<name>.json`. Last one wins.
3. **Refuse to guess a licence.** No author, source or licence means a stop
   with the path of the file to write. This repo publishes to Pages on every
   merge; art whose terms nobody wrote down cannot go out.
4. **Bake.** Eight grid directions × every animation frame, at the geometry
   `assets/tiles/tiles.json` declares.
5. **Install.** `assets/packs/<name>/`, with the model kept beside the pixels
   as `source/model.glb` — that is what a re-bake at a new production scale reads.
6. **Verify.** `art`, then `import`, then `generate`, then `test`. The same
   gates a person runs, in the order that fails fastest.

The source file is consumed: it moves into the pack. `inbox/` is a doorway,
not a library.

## The camera

The projection is not a taste, and there is not a number in it that was typed
by hand. A square cell projects to a `tile_size` diamond exactly when the
camera sits at `sin(φ) = tile_h / tile_w` above the horizon, at 45° of azimuth.
Everything else follows:

| quantity | value | at 64×32 |
| --- | --- | --- |
| one cell of grid +x, across | `tile_w / 2` | 32 px |
| one cell of grid +x, down | `tile_h / 2` | 16 px |
| one cell of height, up | `√(tile_w² − tile_h²) / √2` | 39.19 px |

`tests/test_pipeline.py` pins the first two against `pixel.cell_centre()`,
which is the same arithmetic `scripts/iso.gd` uses — so the baker cannot drift
away from where the engine actually puts a cell.

**Height is the one place a choice remains.** 39.19 px per cell is
geometrically correct. The shipped painters are flatter than that — a
cell-high wall is 32 px, about 0.82 cells at true scale — because they are
stylised placeholders, not a camera. `height_scale` squashes the model's up
axis before the camera sees it, so new art can either be correct (1.0, the
default) or sit beside the placeholders (nearer 0.8). Depth is squashed with
it, so the drawing and the occlusion never disagree.

## Directions

The eight rows a clip occupies are **grid** directions, in the order
`docs/architecture/animation.md` fixes. On screen those are the diagonals:
`down_right` is straight down the screen and `up_left` straight up it, so a
character walking `down_right` is coming at the camera and shows a face.

The model is turned, not the camera, and the light stays put — which is why a
baked sprite is lit from the same side as the tiles it stands on, whichever
way it faces. The key light matches what `tools/gen_art.py`'s `block()`
paints: brightest on top, the grid +y face lit, the grid +x face in shadow.

**`forward` is the one setting most likely to need changing.** It says which
glTF axis the model's nose points down before any of this. `-z` is what
Blender and Meshy export and lands on `down`; if a sheet comes out facing the
wrong way, this is the setting, and nothing else needs touching.

## How it becomes pixel art rather than a small render

Three things, in this order:

- **Flat bands.** Lambert against a key and a fill light, quantised to
  `bands` steps (4 by default). Shadows tint cool and highlights warm, using
  the project palette's own `dark` and the daylight profile's sun.
- **A real palette.** Every albedo the model shows, median-cut to `colours`
  entries (10 by default). The final sheet holds at most `colours × bands`
  distinct values, which is what makes it read as painted.
- **A mode filter, not an average.** The frame is rendered at
  `supersample`× and reduced by letting the commonest colour in each block win
  outright. Averaging is what turns pixel art into mush; a vote keeps every
  output pixel exactly on the palette, and coverage below half is background,
  so edges stay hard.

Then a one-pixel outline in the sprite's own darkest tone, because baked 3D at
this size loses its silhouette against a busy tile floor.

## Clips

An exported animation's name is the only clue about what it is, so the names
are matched against the game's vocabulary — `idle`, `walk`, `trot`, `run`,
`sniff`, `sit`, `attack`, `hurt`, `die`, `jump`. Anything unrecognised keeps
its own name rather than being dropped, and `attack`, `hurt`, `die`, `jump`
and `sniff` are one-shots rather than loops.

Frame counts come from the animation's real length at `sample_fps`, capped at
`max_frames`, and the frame rate is then set so the clip plays at the speed it
was authored. A model with no animations at all bakes a single static `idle`,
which is exactly the shape the four legacy townspeople already have.

## Why the sheet is committed and not regenerated in CI

A pack's sheet is a **source**, like `tiles.json` — the rule
`assets/packs/README.md` already sets out. `terrain.png` and `actors.png` are
still rebuilt from scratch on every run and still drift-checked; a baked pack
sheet is an input to that, not an output of it. Keeping it that way means CI
stays fast and does not need a rasteriser in the loop, and the model kept in
the pack's `source/` is what makes the bake repeatable when the production
scale moves.

## What the gates already check

Free, and not worth re-implementing:

- The sprite fits its declared frame, and the anchor is inside it
  (`tools/ci.sh art`, via `packs.actor_problems`).
- Every clip's rows and columns fit the sheet, every direction is one of the
  eight, no clip has frames without a frame rate.
- The generated `actors.json` still validates against
  `scripts/actor_manifest.gd`, and the texture it names actually loads.
- `CREDITS.md` lists the pack, with its author, source and licence.
- `tests/test_pipeline.py` pins the camera against `Iso`, checks the glTF →
  grid conversion does not mirror the model, and proves that end-on directions
  really do come out narrower than broadside ones — which is the failure a
  contact sheet does *not* make obvious.

## When it goes wrong

| symptom | setting |
| --- | --- |
| facing the wrong way | `forward` |
| far too big or too small | `cell_metres`, or `fit_height` for an exact pixel height |
| too tall or too flat beside the tiles | `height_scale` |
| muddy, too many colours | fewer `colours`, fewer `bands` |
| ragged edges | raise `supersample` |
| sheet enormous | lower `max_frames` |
| "texture … is image/jpeg" | re-export with PNG textures, or set `no_textures` |
