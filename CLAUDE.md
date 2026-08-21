# Port Azure

An **isometric** tile RPG in Godot 4. There is no game engine running on
anyone's desktop: every change is made by editing text files, validated by
headless Godot in GitHub Actions, and published to GitHub Pages as a playable
web build.

Assume you are running headless. You cannot open the editor, click a node, or
look at a scene. Everything below exists so that you do not have to.

**The world is 64×32 in a 640×360 frame. All the shipped art is placeholder.**
The tiles and characters you will see were drawn for the old 32×16 grid and are
magnified ×2 by the build — a migration path, not the visual target. Read
`docs/architecture/rendering.md` before drawing any conclusion from a
screenshot, and author new art at the production geometry.

## The world is isometric, the data is not

A cell is `[x, y]` in a square ASCII grid. It always was and it still is.
Isometric is a **projection** — applied when a cell becomes a screen position,
and nowhere else. Nothing about authoring a map changes because of it:
walkability is still 4-connected, the flood fill is still a flood fill, and a
legend character is still one tile.

```
grid                      screen
(0,0) (1,0) (2,0)              (0,0)
(0,1) (1,1) (2,1)          (0,1)   (1,0)
(0,2) (1,2) (2,2)      (0,2)  (1,1)   (2,0)
                           (1,2)   (2,1)
                               (2,2)
```

Three consequences worth holding on to:

- **Grid +x runs down-right on screen; grid +y runs down-left.** So screen
  depth is `x + y`, which is what orders the world. The movement keys drive
  grid axes, not screen axes: `move_right` is grid +x. Press two at once for
  the screen-aligned diagonals.
- **`down`, `left`, `right`, `up`** — in map JSON, in NPC facings, in the
  sprite sheet — name grid directions. On screen they are the four diagonals.
  `down` and `right` come toward the camera and show a face; `up` and `left`
  show a back.
- **`scripts/iso.gd` is the only place the projection is written down** in
  GDScript, and `tools/pixel.py` holds the same arithmetic for the renderers.
  Never open-code `cell * 32` anywhere. `tests/test_iso.gd` pins `Iso` against
  a real `TileMapLayer`, so if you change one you will hear about it.

A tile is a **64×32** diamond drawn inside a **64×128** atlas cell. The extra
height is headroom for walls, roofs and trees.

## One source of truth for every dimension

```
assets/tiles/tiles.json      tile_size [64,32]  cell_size [64,128]  legacy_art
data/rendering.json          viewport [640,360]  scaling  the CanvasLayer budget
```

Everything else is derived: `Iso`, the camera limits, the collision shapes, the
elevation lift, the light radii, the tileset bake, all three Python renderers.
**Never type 64, 32, 640 or 360 into a script** — ask `TileRegistry`, `Iso` or
`Presentation`, and `pixel.geometry()` / `pixel.viewport()` on the Python side.
The engine cannot read `data/rendering.json` at boot, so `project.godot` mirrors
it and `tests/test_rendering.gd` fails CI when the two drift.

Moving the production scale is a two-number edit in `tiles.json`.
`docs/architecture/rendering.md` has the procedure.

## Elevation: the grid gains a z

A cell is `[x, y]` **plus a height**. Maps may carry an `elevation` layer next
to `ground` and `objects` — same rectangle, one digit `0`–`9` per cell:

```json
"elevation": [
  "00000",
  "01110",
  "01210",
  "01110",
  "00000"
]
```

No `elevation` layer means a flat map: everything at level 0, exactly as
before. Like the diamond itself, elevation is a *projection*: the grid stays
square, `z` is data, and only on the way to the screen does a level become
pixels. One level is `Iso.elevation_height()` (half a diamond — 16px at the production
scale, the same lift as stepping one row toward the back), mirrored by
`level_px()` in `tools/pixel.py`. Both derive it from the registry; never write
the number yourself.

**The flat plane is the simulation; elevation is applied at render time.**
Actor bodies, physics, y-sorting and `Iso.cell_at()` all live on the level-0
plane — `MapData.flat_world_position(cell)` — and the drawing is lifted:
raised tiles go into per-level `TileMapLayer`s shifted up by
`z * elevation_height()` (keeping their y-sort at the flat cell, so occlusion
still orders by ground contact), and an actor's sprite is lifted off its own
body by the elevation under its feet. `MapData.world_position(cell)` is the
lifted surface — where the top of the hill visibly is. This split is what
will someday let a jump be `terrain elevation + jump offset` without touching
the world model.

**Movement between levels is one rule**, `MapData.can_move(from, to)`, used
by gameplay, the reachability flood fill and anything that will ever
pathfind:

- same level → walk freely;
- exactly one level apart → only across a tile with
  `"elevation_transition": true` in `tiles.json` (`stairs_up` today)
  standing on the **lower** cell — that is the cell a staircase occupies,
  and its art climbs toward grid **-y**, so put the higher ground north of
  the stairs;
- anything else is a cliff and blocks, up **and** down (falling is a later
  mechanic).

Cliff sides draw themselves: `MapLoader` and `tools/render_map.py` stack the
generated `cliff` tile under every raised cell, one band per level. Maps
never place it. To raise terrain you edit digits, add stairs, and run
`tools/ci.sh test` — the validator checks the elevation rectangle, and the
flood fill walks `can_move()`, so a plateau whose stairs you forgot fails CI
with "unreachable", not a silent hole. See the hill in
`maps/port_azure_town.json` (and in `docs/art/map_port_azure_town.png`) for
the pattern to copy; `python3 tools/render_map.py <id> --scale 4 --annotate`
prints each raised cell's level on the render.

## The loop

```
tools/ci.sh inbox      # bake whatever is in inbox/ into a pack, then verify
tools/ci.sh import     # re-import assets; run this after touching anything
tools/ci.sh test       # the whole suite, ~2 seconds
tools/ci.sh generate   # only after editing tiles.json or tools/gen_art.py
tools/ci.sh export     # web build into build/web/ (needs export templates)
tools/ci.sh sheets     # re-render docs/art/ only (no Godot needed)
tools/ci.sh art        # check every tile stands on the grid (no Godot needed)
```

**Working on art?** You cannot judge a 64×32 diamond at 1:1, and you certainly
cannot judge whether it lines up with its neighbours outside a map. Run
`tools/ci.sh sheets`, then look at `docs/art/atlas.png` (every tile at 5x,
named, with its ground diamond outlined) and
`docs/art/map_port_azure_town.png` (the town composited from real map data).
Never change a painter without regenerating and looking at the result.
`AGENTS.md` has the full art loop and the current list of what needs improving.

`tools/ci.sh test` is the gate. It fails on assertion failures **and** on any
`SCRIPT ERROR` or `ERROR:` the engine prints, because Godot otherwise exits 0
with a broken project. Run it before you open a pull request; CI runs the same
script, so a green local run means a green CI run.

To run one suite: `tools/ci.sh test -- --only maps`.

## How the game is put together

Content is data, not scenes. Scenes exist only for things with behaviour
(the player, the generic NPC, the dialogue box). Everything a map is made of
lives in JSON you can read and diff.

| You want to change | Edit | Then |
| --- | --- | --- |
| A room, a town, a building | `maps/<id>.json` | `tools/ci.sh test` |
| Terrain height — hills, cliffs, stairs | `maps/<id>.json` `elevation` layer | `tools/ci.sh test`, then look at the render |
| How a map is lit (mood, sun) | `"lighting"` block in `maps/<id>.json` | `tools/ci.sh test` |
| How a map is framed (follow / room / fixed) | `"camera"` block in `maps/<id>.json` | `tools/ci.sh test` |
| A map's atmosphere (fog, grading, quantize) | `"fx"` block in `maps/<id>.json` | `tools/ci.sh test` |
| Background / foreground scenery | `"scenery"` block in `maps/<id>.json` | `tools/ci.sh test`, then `shots` |
| A reusable lighting mood | `data/lighting/<profile>.json` | `tools/ci.sh test` |
| A reusable effect stack | `data/fx/<preset>.json` | `tools/ci.sh test` |
| The effects that exist at all | `data/fx/effects.json` + a shader | `tools/ci.sh test` |
| Who someone is | `data/npcs/<id>.json` | `tools/ci.sh test` |
| What someone says | `dialogue/<id>.json` | `tools/ci.sh test` |
| A character's frames, clips or directions | `assets/sprites/actors.json` (generated — via `tools/gen_art.py`) | `tools/ci.sh generate` then `test` |
| The tiles that exist | `assets/tiles/tiles.json` + `tools/gen_art.py` | `tools/ci.sh generate` then `test` |
| Scenery props that exist | `assets/scenery/scenery.json` | `tools/ci.sh test` |
| What a tile does to light (emit, block, glow) | `"lighting"` block in `tiles.json` (+ `e_<name>` painter for glow) | `tools/ci.sh generate` then `test` |
| Bring in bought or downloaded art | `assets/packs/<name>/` + a registry entry | `tools/ci.sh art`, then `generate` |
| Turn a 3D model into a character | drop the `.glb` in `inbox/` | `tools/ci.sh inbox` — it bakes, installs and verifies |
| The world's geometry or the frame | `assets/tiles/tiles.json` / `data/rendering.json` | `tools/ci.sh generate` then `test` |
| Movement, interaction, saving | `scripts/*.gd` | `tools/ci.sh test` |
| Key bindings | `tools/setup_input.gd` | run that script, commit `project.godot` |

Presentation is metadata end to end — maps pick lighting profiles, camera
modes, effect stacks and scenery; tiles, actors and props declare behaviour;
the runtime builds the nodes. Never hardcode an asset name to get a behaviour
and never place a map's lights, effects or scenery in a scene file.
`docs/architecture/AGENTS.md` is the checklist, and it links to one design doc
per subsystem: `rendering.md`, `scenery.md`, `animation.md`, `camera.md`,
`fx.md`, `lighting.md`, `inbox.md`.

## Simulation and presentation are separate, deliberately

The game model knows: **cell, walkable, height, collision, actor, portal,
interaction.** That is all, and it is a square grid.

Presentation knows: 64×32 projection, a 300-pixel-tall tree, a foreground
branch, a parallaxed ridge, a normal map, fog, an eight-direction sheet, a
fixed camera.

A giant redwood occupies **one** logical cell and one collision footprint
however much of the screen its picture covers. Scenery never collides; what
stops the player is a solid tile in the map grid, and the validator proves the
two agree. Never let a presentation problem grow a second definition of
"solid".

```
maps/*.json          ASCII grids + a legend. One character per tile. Optional
                     "lighting", "camera", "fx" and "scenery" blocks.
data/rendering.json  THE presentation contract: viewport, scaling, layer budget.
data/npcs/*.json     display name, sprite, dialogue id, behaviour.
data/lighting/*.json named lighting profiles (ambient + directional).
data/fx/effects.json the effect vocabulary: shader, space, order, parameters.
data/fx/*.json       named effect stacks a map can ask for.
dialogue/*.json      a node graph: text, choices, flags.
assets/tiles/        tiles.json is THE geometry source + the tile registry;
                     terrain*.png and terrain.tres are generated.
assets/sprites/      actors.png + actors.json (GENERATED): the animation manifest.
assets/scenery/      scenery.json: props that are not tiles. Ships empty.
assets/lights/       GENERATED light falloff textures.
assets/shaders/      hand-written canvas shaders (tile emission, the fx set).
assets/packs/        imported art. Sheets are sources; see the README in there.
scripts/             game code. map_data.gd holds the validator, iso.gd the
                     projection, presentation.gd the frame, scene_planes.gd the
                     depth planes, actor_manifest.gd the animation contract,
                     camera_config.gd + game_camera.gd the framing,
                     world_lighting.gd the light, world_fx.gd the atmosphere.
tools/pixel.py       canvas, PNG, palette, the geometry contract, and the
                     diamond primitives. Shared by all renderers.
docs/art/            GENERATED contact sheets and map renders. Look at these.
docs/architecture/   one design doc per subsystem + the scoped AGENTS.md.
inbox/               a doorway, not a library: drop a .glb in and run
                     `tools/ci.sh inbox`. The source is consumed into a pack.
scenes/              player, npc, dialogue box, world, title. Containers only:
                     nothing content-shaped, no map data, no lights, no effects.
tests/               the suite. Add to it whenever you add a mechanic.
tools/               generators and ci.sh.
```

## Rules that keep the headless loop working

**Never hand-edit a generated file.** `assets/tiles/terrain.png`,
`assets/tiles/terrain.tres`, `assets/sprites/actors.png`, `CREDITS.md` and
everything in `docs/art/` are built by `tools/ci.sh generate`. CI regenerates
them and fails if the result differs from what is committed.

**Art may be imported instead of drawn.** A tile in `tiles.json` can name a
`pack`, and its pixels are then cut from a sheet in `assets/packs/<name>/`
rather than from a painter. That does not weaken the rule above: a pack's
sheet is a *source*, terrain.png is still the *output*, and the drift check
still holds. `assets/packs/README.md` is the whole workflow, including what to
do when a downloaded sheet is drawn at a different scale.

**Never put map content in a `.tscn`.** A `TileMapLayer` stores its cells as a
binary blob. You cannot read it, review it, or diff it. Maps are ASCII grids
for exactly this reason. `scripts/map_loader.gd` builds the tile layers at
runtime.

**Never add a tile by picking an atlas coordinate in code.** Add it to
`assets/tiles/tiles.json`, draw it in `tools/gen_art.py`, run
`tools/ci.sh generate`. The registry is the only place a coordinate is written
down.

**Never turn a cell into a position by hand.** `Iso.cell_centre()` and
`MapData.world_position()` exist so the engine, the game code and the map
renderer cannot drift apart about where a tile is. A stray `x * 32` puts a sign
in a wall on one of the three and nowhere else.

**Never hardcode a dimension.** 64, 32, 640, 360, 16 are all derived from
`assets/tiles/tiles.json` and `data/rendering.json`. The same goes for
collision shapes: they are built from `Iso.diamond_shape()` at runtime, not
saved as pixel coordinates in a `.tscn`.

**Never give scenery collision.** There is one definition of solid and it is
the map grid.

**Keep every layer of a map rectangular.** Every row of `ground` and `objects`
must be the same length. The validator rejects ragged grids, because a short
row silently becomes empty space.

**A change is not done until the suite passes.** If you add a mechanic, add the
test that would fail without it. Look at
`tests/test_runtime.gd::test_facing_an_interactable_finds_it` for the shape of
a good one: it exercises the path a player actually takes, not the function you
just wrote.

## What the validators already check

You get these for free; do not re-implement them.

- Every map layer is rectangular, and every character used appears in the legend.
- Every map's optional `camera`, `fx` and `scenery` blocks resolve: the mode
  exists, a room is on the map, a fixed camera has somewhere to sit, every
  effect and parameter is in the catalog and in range, every scenery prop is
  in the registry, and **a prop that claims to block the way stands on a solid
  tile**.
- The actor manifest is sound: every clip's rows and columns fit its sheet,
  every direction is one of the eight, every anchor is inside its own frame,
  and every fallback points at a clip that exists.
- `data/rendering.json` and `project.godot` agree about the frame.
- Gameplay lives only in the y-sorted playable plane: no collision object
  anywhere else in the scene.
- Every legend entry names a tile that exists in `tiles.json`.
- Spawn points, NPCs, signs and portals stand on walkable ground.
- The `elevation` layer, when present, is a full rectangle of digits `0`–`9`.
- **Everything is reachable.** A flood fill from the spawn must reach every
  portal, NPC and sign — walking by `can_move()`, so cliffs block it exactly
  as they block the player. This is what catches a door sealed behind a
  fireplace, an NPC walled into a closet, or a plateau with no stairs — the
  bugs you cannot see in a text diff.
- Every portal names a map that exists and a spawn that map defines, and every
  door leads both ways.
- Every dialogue node is reachable from `start`, every jump lands on a real
  node, and every node can still reach an ending.
- Every flag a conversation sets is read by some conversation.
- The baked tileset matches `tiles.json`, tile for tile and solid for solid,
  and is still an isometric diamond grid of the size the registry declares.
- Every map's `lighting` block resolves: the profile exists and every value is
  well-formed. Every tile's lighting metadata fits the schema, baked occluder
  polygons and generated emission pixels match it exactly, emitting tiles
  spawn real lights that are cleared on map change, and a map with no
  `lighting` block renders full-bright, exactly as it did before the system.
- `scripts/iso.gd` still projects cells exactly where a real `TileMapLayer`
  puts them, in both directions.
- Every tile stands on its ground diamond: art may rise as far above its cell
  as it likes and may never sink below the footprint, which is what makes
  sorting by ground contact correct. `tools/ci.sh art` is the gate.
- Every imported tile names a pack that records its author, source and licence,
  and `CREDITS.md` lists them.

## Writing style for the game itself

Dialogue is terse and dry. People in Port Azure are working, tired, and
specific. No quest-giver exposition dumps, no "brave adventurer". A line is
usually one or two sentences. Give NPCs an opinion about something small.

## GDScript conventions

Match the surrounding code. Static typing everywhere (`var x: int`, `-> void`).
`snake_case` for members, `PascalCase` for `class_name`. Signals are past tense
(`map_changed`, not `change_map`). Comment the *why*; the *what* is in the code.

Prefer a `static func` on the relevant class over a new autoload. There are
three autoloads (`GameState`, `Dialogue`, `Router`) and that is enough.
