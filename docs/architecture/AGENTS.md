# Rendering, scenery & lighting — agent guide

You are adding a map, a prop, a building, a character, an art pack, a light,
a camera framing or an atmospheric effect to Port Azure. This file tells you
where everything goes and what will fail CI if you put it somewhere else.

The design references, each owning one subsystem:

| doc | owns |
| --- | --- |
| [`rendering.md`](rendering.md) | the geometry and presentation contract — **read this first** |
| [`scenery.md`](scenery.md) | depth planes, anchors, the four footprints |
| [`animation.md`](animation.md) | the actor manifest: directions, clips, frame rates |
| [`camera.md`](camera.md) | FOLLOW / ROOM_LOCKED / FIXED / CINEMATIC |
| [`fx.md`](fx.md) | fog, grading, quantization and who owns them |
| [`lighting.md`](lighting.md) | ambient, sun, emitters, occluders, emission |

The repo-wide guide is the root `AGENTS.md`. Everything here is done by
editing text files and running `tools/ci.sh`. There is no editor, and nothing
below needs one.

## The rules everything else hangs off

**Isometric is a projection, not a data format.** The game is 2D. A cell is
`[x, y]` in a square ASCII grid; it becomes a screen position only through
`scripts/iso.gd` (`Iso.cell_centre()`, `MapData.world_position()`), and
`tools/pixel.py` holds the same arithmetic for the Python renderers. Never
introduce 3D nodes to get perspective or lighting, never open-code
`cell * 32`, and never bend `Iso` to fake a camera angle — `tests/test_iso.gd`
pins it against a real `TileMapLayer` and will catch you.

**The geometry has one source of truth.** `assets/tiles/tiles.json` says a
ground diamond is 64x32 in a 64x128 cell; `data/rendering.json` says the frame
is 640x360. Every other dimension in the project — collision shapes, camera
limits, elevation lift, light radii, the renderers' output — is derived from
those. A `64` typed into a script is a bug waiting for the day the contract
moves.

**Simulation is a grid; presentation is everything else.** The world model
knows cells, walkability, height, collision, actors, portals, interaction.
Presentation knows 400-pixel trees, parallax, fog, normal maps, fixed cameras
and eight-direction sheets. A giant redwood occupies **one** logical cell and
one collision footprint however much of the screen its picture covers. Never
let a presentation problem grow a second definition of "solid".

**Behaviour is metadata, not code.** A lamp glows because `tiles.json` says it
emits; a room is dim because its map names a lighting profile; a scene is
framed because its map names a camera mode; fog drifts because its map names
an effect. If you are typing an asset name into an `if` to get a behaviour,
stop: add metadata instead.

## Checklist: a new room / map

0. **Decide how it is framed.** Nothing → FOLLOW, exactly as before. A
   composed interior → `"camera": {"mode": "room_locked", "room": [x, y, w, h]}`.
   A fixed cinematic shot → `{"mode": "fixed", "at": [x, y]}`.
   [`camera.md`](camera.md) has the rest; the validator checks the room is on
   the map and that a fixed camera has somewhere to sit.
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
6. **Verify headless loading, then look at it.** `tools/ci.sh test` — the
   runtime suite boots your map, and `tests/test_lighting.gd` checks its
   lights spawn and its profile resolves. Then `tools/ci.sh shots` and open
   `docs/shots/`: tests prove a light exists, only the frame tells you the
   room is readable. Add your map to `SHOTS` in `tools/shoot.gd` if it is
   worth a standing reference.
7. **Test the transitions.** Walk in and out through every portal
   (`test_doors_move_the_player_to_the_other_side` does this in CI); lighting
   glides between environments on entry and old lights must be gone — if you
   added mechanics around this, add the test that would fail without them.
8. **Atmosphere, if the room wants it.** `"fx": {"preset": "..."}` or a list
   of effects. Nothing means nothing, which is what every shipped map has.
   [`fx.md`](fx.md); mind the two-backbuffer budget.
9. **Scenery, if the room is composed rather than tiled.** A `"scenery"`
   array places props from `assets/scenery/scenery.json` into the background
   and foreground planes. [`scenery.md`](scenery.md) — and remember that
   anything which blocks the way needs a solid tile under it, not a bigger
   picture.

## Checklist: a new character

1. **Get the sheet in.** A pack directory for imported art, so the licence
   travels with the pixels. Frames run horizontally; each direction is a row.
2. **Describe it in `assets/sprites/actors.json`**: a `sheets` entry (texture,
   frame size, anchor) and an `actors` entry (sheet, directions authored,
   clips with their own frame counts and frame rates).
   [`animation.md`](animation.md) is the schema.
3. **The anchor is the pixel that touches the ground.** Sorting is by ground
   contact, so this — not the middle of the image — is what the node's origin
   is placed at. A 300px character sorts exactly like a 48px one.
4. **Author what you have.** Four directions is legal; eight is legal; a clip
   authored for two directions is legal. Missing falls back. *Malformed* fails
   validation, loudly, and that difference is the point.
5. `tools/ci.sh generate` then `tools/ci.sh test`, then look at
   `docs/art/actors.png` — the contact sheet reads the manifest, so it lays
   itself out around whatever you declared.

Note that `assets/sprites/actors.json` is **generated** for the legacy cast.
A character that is not drawn by `tools/gen_art.py` needs the generator to
emit its entry, or its own manifest file merged in — do not hand-edit the
generated one.

## Checklist: a new scenery prop

1. **Art in** (painter, pack, PixelOver render — all sources, all
   reproducible).
2. **Entry in `assets/scenery/scenery.json`**: texture and `anchor`, at
   minimum.
3. **Decide the footprints separately.** Visual is the image and nobody's
   business. Logical is `footprint`, usually one cell. Collision is the map's
   solid tiles — set `requires_solid` and the validator will prove the map
   agrees. Occlusion is `occluder`, no bigger than the logical footprint.
4. **Place it** in a map's `"scenery"` array: a plane, a space, optionally a
   parallax.
5. `tools/ci.sh test`, then `tools/ci.sh shots` and look at the frame.

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
   `tools/ci.sh generate` then `tools/ci.sh test` prove the round trip, and
   `tools/ci.sh shots` shows you whether the result is worth shipping.
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
  centre of its diamond for a tile, `anchor` for a pack, an actor or a scenery
  prop. One idea, four spellings, because the thing being anchored differs.
- **Collision footprint** — the `solid` flag; always the full diamond today.
  Scenery never has one: what blocks the way is a tile.
- **Occlusion footprint** — `lighting.occluder`; at most the diamond, often
  smaller. Deliberately separate from both collision and visual bounds.
- **Light origin** — `lighting.emit.offset`, screen pixels from the diamond
  centre to where the light visibly comes from. Screen pixels are production
  pixels: they scaled with the world in the 64x32 migration.
- **Legacy art** — every shipped tile and character is a placeholder drawn at
  the old 32x16 geometry and magnified by an exact integer factor. It is a
  migration path, not a look. New art is authored at 64x32.
  [`rendering.md`](rendering.md) has the details and the retirement plan.

## Performance rules (web + small GPUs)

The game ships to GitHub Pages under GL Compatibility. Budget accordingly:

- A few meaningful lights beat many dim ones. The runtime warns past 32
  dynamic lights on a map; treat the warning as a design failure.
- `"shadows": true` is the expensive flag. One shadowed light per map is a
  statement; five is a slideshow. Occluder polygons are free until a shadowed
  light overlaps them.
- Keep the default light texture and radii modest (a radius is screen pixels
  on a 640×360 viewport — 80 is already a quarter of the screen tall).
- Reuse metadata: a second lamp costs a map character, not new schema, new
  textures or new code.
- No per-frame material churn, and no full-screen effect without measuring on
  the web export first. Screen-reading effects (`color_grade`, `quantize`)
  cost a backbuffer copy each; `WorldFx` warns past two. See [`fx.md`](fx.md).

## Ownership — where a change belongs

| You are changing | Edit |
| --- | --- |
| The world's geometry (tile size, cell size) | `assets/tiles/tiles.json` — and nothing else |
| The frame (viewport, scaling, layer budget) | `data/rendering.json` + the mirror in `project.godot` |
| The projection itself | `scripts/iso.gd` + `tools/pixel.py` (both, always) |
| Camera modes and framing | `scripts/camera_config.gd` + `scripts/game_camera.gd` |
| Depth planes, plane ownership | `scripts/scene_planes.gd` |
| Scenery metadata & its schema | `assets/scenery/scenery.json` + `scripts/scenery_registry.gd` |
| A scenery prop's runtime behaviour | `scripts/scenery_prop.gd` |
| Actor sheets, clips, directions | `assets/sprites/actors.json` + `scripts/actor_manifest.gd` |
| Actor drawing at runtime | `scripts/actor_sprite.gd` |
| Map parsing / validation | `scripts/map_data.gd` |
| Map → nodes (layers, entities, materials) | `scripts/map_loader.gd` |
| Tile metadata & its schema | `assets/tiles/tiles.json` + `scripts/tile_registry.gd` |
| Environment profiles | `data/lighting/*.json` + `scripts/lighting_profile.gd` |
| Lighting runtime (ambient, sun, dynamic lights) | `scripts/world_lighting.gd` |
| The effect vocabulary | `data/fx/effects.json` + a shader in `assets/shaders/` |
| Effect stacks a map can name | `data/fx/<preset>.json` |
| Effect runtime (build, bind, sweep) | `scripts/world_fx.gd` |
| Tileset bake (collision, occluders, normal wiring) | `tools/build_tileset.gd` |
| Generated pixels (tiles, emission, normals, light falloff, actors) | `tools/gen_art.py` |
| Importing somebody else's art | `tools/packs.py` + `assets/packs/README.md` |

## Forbidden shortcuts

Each of these has been cheap once and expensive forever:

- **Placing ordinary map lights in a `.tscn`.** Lights come from tile
  metadata; scenes exist only for things with behaviour.
- **Matching asset names in code** (`if tile_name == "lamp"`). Metadata or
  nothing.
- **Modifying `Iso` to fake camera perspective.** The projection is pinned
  by tests against the engine; the camera is `scripts/game_camera.gd`.
- **Hardcoding a dimension.** 64, 32, 640, 360, 16 — every one of them is
  derived. Ask `TileRegistry`, `Iso` or `Presentation`.
- **Giving scenery collision.** There is one definition of solid and it lives
  in the map grid. A picture that stops the player is a picture standing on a
  solid tile.
- **Making a prop's logical footprint match its picture.** A redwood is one
  cell. That separation is the whole reason the visual target is affordable.
- **Assuming a cutscene ends in FOLLOW.** `release_focus()` returns the camera
  to whatever borrowed it. A FIXED scene must still be FIXED afterwards.
- **Growing screen effects onto `WorldLighting`.** They have an owner:
  `scripts/world_fx.gd`.
- **Converting anything to 3D** for lighting, shadows or perspective. This
  is a 2D canvas with 2D lights, by architectural decision.
- **Baking dynamic light into diffuse art.** A painted glow cannot be turned
  off, dimmed by a profile, or occluded. Painted *ambient occlusion* (a
  contact shadow) is fine; painted lamplight on the ground is not.
- **Bypassing `TileRegistry`** — reading `tiles.json` ad hoc or hardcoding
  atlas coordinates. One registry, one schema, one validator.
- **Breaking headless CI for an editor-only feature.** If it cannot be
  built, validated and tested from the command line, it does not ship.
