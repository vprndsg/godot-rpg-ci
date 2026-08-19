# Rendering & lighting — agent guide

You are adding a map, a prop, a building, an art pack, or a light to Port
Azure. This file tells you where everything goes and what will fail CI if you
put it somewhere else. The implementation reference with schemas and diagrams
is [`lighting.md`](lighting.md); the repo-wide guide is the root `AGENTS.md`.

Everything here is done by editing text files and running `tools/ci.sh`.
There is no editor, and nothing below needs one.

## The two rules everything else hangs off

**Isometric is a projection, not a data format.** The game is 2D. A cell is
`[x, y]` in a square ASCII grid; it becomes a screen position only through
`scripts/iso.gd` (`Iso.cell_centre()`, `MapData.world_position()`), and
`tools/pixel.py` holds the same arithmetic for the Python renderers. Never
introduce 3D nodes to get perspective or lighting, never open-code
`cell * 16`, and never bend `Iso` to fake a camera angle — `tests/test_iso.gd`
pins it against a real `TileMapLayer` and will catch you.

**Lighting is metadata, not code.** A lamp glows because
`assets/tiles/tiles.json` says it emits; a wall blocks light because its
metadata says it occludes; a room is dim because its map JSON names a profile.
The runtime (`scripts/world_lighting.gd`, `scripts/map_loader.gd`,
`tools/build_tileset.gd`) turns metadata into `PointLight2D`s, occluder
polygons and shader inputs. If you are typing a tile name into an `if` to get
a lighting behaviour, stop: add metadata instead.

## Checklist: a new room / map

1. **Choose or define a lighting profile.** Look in `data/lighting/` first:
   `outdoor_day`, `outdoor_evening`, `moonlit`, `warm_interior`,
   `dark_interior`. A map that says nothing gets `default` — full-bright,
   exactly the pre-lighting look. New mood used by more than one map → new
   profile file; one-off tweak → override keys on the map.
2. **Decide the ambient tone.** `"lighting": {"profile": "warm_interior"}`,
   plus overrides if needed:
   `{"profile": "warm_interior", "ambient_energy": 0.6}`. Keep interiors
   playable — below ~0.4 ambient you owe the player local lights.
3. **Decide whether the sun applies.** Interiors: `"directional": {"enabled":
   false}` (the interior profiles already do this). Exteriors: the profile's
   sun is a subtle wash; leave its numbers alone unless you are tuning on a
   rendered result.
4. **Identify local emitters.** Emitters are tiles: place `lamp`, `fireplace`
   (or a new emitting tile — see the asset checklist) in the map grid, and
   lights appear there. Do not place light nodes anywhere.
5. **Verify occluders.** Walls already occlude. If your map leans on a
   shadow-casting light, check the tiles ringing it declare `occluder`
   metadata, and that no emitting tile occludes its own cell.
6. **Verify headless loading.** `tools/ci.sh test` — the runtime suite boots
   your map, and `tests/test_lighting.gd` checks its lights spawn and its
   profile resolves.
7. **Test the transitions.** Walk in and out through every portal
   (`test_doors_move_the_player_to_the_other_side` does this in CI); lighting
   glides between environments on entry and old lights must be gone — if you
   added mechanics around this, add the test that would fail without them.

## Checklist: a new prop / building / environment asset

1. **Diffuse artwork.** A `t_<name>` painter in `tools/gen_art.py` plus an
   entry in `tiles.json` (or a pack, below). Root `AGENTS.md` covers the cell
   layout and the ground-diamond rule.
2. **Collision.** The `solid` flag — the whole footprint diamond, used by
   walkability, reachability and physics.
3. **Does it block light?** Add `"lighting": {"occluder": ...}`. `true` for
   wall-like things; `{"shape": "diamond", "scale": 0.5}` for a trunk under a
   canopy; `{"points": [[x, y], ...]}` (pixels, relative to the diamond
   centre) for anything odd. Occlusion ≤ footprint; visual size is irrelevant.
4. **Does it emit light?** Add `"lighting": {"emit": {"color": "ffd27a",
   "energy": 0.9, "radius": 40, "offset": [0, -22]}}`. `offset` moves the
   light to the visible source — a lamp head, a firebox — in screen pixels
   from the diamond centre, negative y upward. `"shadows": true` only when
   the map moment needs it (see performance). An emitting tile must **not**
   also occlude its own cell.
5. **Normal map useful?** Only once a `terrain_normal.png` pipeline ships
   (see `lighting.md` — the engine wiring exists, the atlas does not).
   Don't block an asset on this.
6. **Emission map useful?** If pixels should stay lit in the dark (glass,
   flame, embers): flag `"emission": true` and write an `e_<name>` painter in
   `tools/gen_art.py` drawing *only the glowing pixels* at the same
   coordinates as the diffuse painter. The generator fails if flag and
   painter disagree.
7. **Encode all of it in metadata.** Steps 2–6 all live on the tile's entry
   in `tiles.json`. `TileRegistry.validate_lighting()` enforces the schema;
   `tools/ci.sh generate` then `tools/ci.sh test` prove the round trip.
8. **No name checks.** If the behaviour you want cannot be said in metadata,
   extend the schema (`scripts/tile_registry.gd` + its validator + the docs),
   don't special-case your asset in runtime code.

## Art-generation contract

For every texture that feeds the game:

- **Diffuse** — the base art. Must work alone; never bake dynamic light into
  it. Painters in `tools/gen_art.py`, deterministic (use `noise()`, never
  `random`), colours from `P` in `tools/pixel.py`.
- **Normal maps** — optional, layout-identical sibling named `<sheet>_normal`
  (`terrain_normal.png`, pack `sheet_normal.png`). Neutral flat is `8080ff`;
  every cell needs at least that before the file may ship.
- **Emission maps** — optional, layout-identical sibling named
  `<sheet>_emission`. Transparent = not emissive; alpha = emission strength;
  RGB = the colour the pixel holds in darkness (usually the diffuse colour).
- **Atlas placement** — a tile's pixels live in the cell `tiles.json` assigns
  it, in every sibling atlas. Coordinates are written in `tiles.json` and
  nowhere else.
- **Transparent padding** — the 24px headroom above the ground diamond and
  the padding below it stay transparent unless the art genuinely rises;
  nothing may sink below the diamond (`tools/ci.sh art` enforces this).
- **Sprite anchors** — a sprite is anchored where it touches the ground: the
  centre of its diamond. Packs express this with `anchor` in `pack.json`.
- **Collision footprint** — the `solid` flag; always the full diamond today.
- **Occlusion footprint** — `lighting.occluder`; at most the diamond, often
  smaller. Deliberately separate from both collision and visual bounds.
- **Light origin** — `lighting.emit.offset`, screen pixels from the diamond
  centre to where the light visibly comes from.

## Performance rules (web + small GPUs)

The game ships to GitHub Pages under GL Compatibility. Budget accordingly:

- A few meaningful lights beat many dim ones. The runtime warns past 32
  dynamic lights on a map; treat the warning as a design failure.
- `"shadows": true` is the expensive flag. One shadowed light per map is a
  statement; five is a slideshow. Occluder polygons are free until a shadowed
  light overlaps them.
- Keep the default light texture and radii modest (a radius is screen pixels
  on a 320×192 viewport — 40 is already a quarter of the screen tall).
- Reuse metadata: a second lamp costs a map character, not new schema, new
  textures or new code.
- No per-frame material churn, no full-screen effects without measuring on
  the web export first.

## Ownership — where a change belongs

| You are changing | Edit |
| --- | --- |
| The projection itself | `scripts/iso.gd` + `tools/pixel.py` (both, always) |
| Camera behaviour, cinematic framing | `scripts/game_camera.gd` |
| Map parsing / validation | `scripts/map_data.gd` |
| Map → nodes (layers, entities, materials) | `scripts/map_loader.gd` |
| Tile metadata & its schema | `assets/tiles/tiles.json` + `scripts/tile_registry.gd` |
| Environment profiles | `data/lighting/*.json` + `scripts/lighting_profile.gd` |
| Lighting runtime (ambient, sun, dynamic lights, fx) | `scripts/world_lighting.gd` |
| Tileset bake (collision, occluders, normal wiring) | `tools/build_tileset.gd` |
| Generated pixels (tiles, emission, light falloff) | `tools/gen_art.py` |
| Screen-space effects (fog, grading, quantized light) | a node under `WorldLighting.fx_root()` |

## Forbidden shortcuts

Each of these has been cheap once and expensive forever:

- **Placing ordinary map lights in a `.tscn`.** Lights come from tile
  metadata; scenes exist only for things with behaviour.
- **Matching asset names in code** (`if tile_name == "lamp"`). Metadata or
  nothing.
- **Modifying `Iso` to fake camera perspective.** The projection is pinned
  by tests against the engine; the camera is `scripts/game_camera.gd`.
- **Converting anything to 3D** for lighting, shadows or perspective. This
  is a 2D canvas with 2D lights, by architectural decision.
- **Baking dynamic light into diffuse art.** A painted glow cannot be turned
  off, dimmed by a profile, or occluded. Painted *ambient occlusion* (a
  contact shadow) is fine; painted lamplight on the ground is not.
- **Bypassing `TileRegistry`** — reading `tiles.json` ad hoc or hardcoding
  atlas coordinates. One registry, one schema, one validator.
- **Breaking headless CI for an editor-only feature.** If it cannot be
  built, validated and tested from the command line, it does not ship.
