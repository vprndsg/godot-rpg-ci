---
name: run-inbox
description: Use when something has been dropped in inbox/ and the request is to "run the pipeline", process the inbox, or turn a 3D model into a game asset — or when a request mentions inbox/, a .glb or .gltf, baking a sprite sheet, or adding a character from a model. Covers the one command, the settings, and the short list of things that can go wrong.
---

# Running the inbox pipeline

One command does all of it. Run it first, read what it says, and only then
decide whether anything needs thinking about.

```
tools/ci.sh inbox
```

It identifies everything in `inbox/`, bakes each model into an isometric
sprite sheet at the production geometry, installs it as a pack under
`assets/packs/<name>/`, folds it into the generated actor manifest, and runs
`art`, `import`, `generate` and `test`. Takes about half a minute. It ends
with either `all gates green` or one specific error.

**Do not** read `tools/glb.py`, `tools/sprite_bake.py` or `tools/inbox.py` to
work out what it will do. Do not hand-edit `assets/sprites/actors.json` — it
is generated, and `tools/ci.sh generate` will overwrite it. Do not compute a
frame size, an anchor or a projection yourself; all of it is derived from
`assets/tiles/tiles.json`.

## Before the first run, once

`data/inbox.json` needs `author`, `source` and `license` under `defaults`.
The pipeline refuses to guess them — this repo publishes to the web on every
merge. Set them once and every future asset inherits them.

## If it fails

The error names the fix. In practice it is one of these, and the answer is a
setting in `data/inbox.json` under `defaults.bake` (or in
`inbox/<name>.json`, which wins) followed by a re-run:

| what you see | change |
| --- | --- |
| sprite faces the wrong way | `forward` — try `+z`, then `+x`, `-x` |
| far too big or too small | `cell_metres` (default 1.5 m per cell), or `fit_height` for an exact pixel height |
| too tall or too flat next to the tiles | `height_scale` — 1.0 is true dimetric, ~0.8 matches the shipped placeholders |
| muddy or too busy | fewer `colours`, fewer `bands` |
| ragged edges | raise `supersample` |
| sheet is enormous | lower `max_frames` |
| `texture … is image/jpeg` | re-export the model with PNG textures, or set `no_textures: true` |
| `has no author or source or license` | fill in `data/inbox.json` |
| `is neither a GLB nor a .gltf` | the file is not a model — say so, do not try to convert it |

Re-running is cheap and safe. It overwrites the pack it made before.

## The one thing worth looking at

Everything else is checked by a gate, but **nothing can tell you a character
is facing the wrong way**. After a green run, look at the panel for the new
actor in `docs/art/actors.png`:

- `down` and `right` come toward the camera and should show a face.
- `down_right` is straight down the screen — head-on, the narrowest silhouette.
- `up_left` is straight up the screen — the same silhouette from behind.

If those are wrong, it is `forward` and nothing else. Change it, re-run.

## Useful variations

```
tools/ci.sh inbox -- --dry-run       # what it would do, writes nothing
tools/ci.sh inbox -- --no-verify     # bake only, skip the gates
tools/ci.sh inbox -- --keep          # leave the source in inbox/
tools/ci.sh inbox -- coyote          # just one asset
```

## After a green run

Commit `assets/packs/<name>/` together with the regenerated
`assets/sprites/actors.json`, `assets/sprites/actors.png`, `CREDITS.md` and
`docs/art/`. The pack's `source/model.glb` belongs in the commit too — it is what a
re-bake reads if the production scale ever moves.

To put the character in the world, it is now an ordinary actor: give it a
`data/npcs/<id>.json` with `"sprite": "<name>"` and place it on a map. The
`create-npc` skill covers that.

`docs/architecture/inbox.md` is the design, including the camera and why the
sheet is a committed source rather than a CI-regenerated output.
