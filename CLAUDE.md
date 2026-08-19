# Port Azure

A SNES-era **isometric** tile RPG in Godot 4. There is no game engine running
on anyone's desktop: every change is made by editing text files, validated by
headless Godot in GitHub Actions, and published to GitHub Pages as a playable
web build.

Assume you are running headless. You cannot open the editor, click a node, or
look at a scene. Everything below exists so that you do not have to.

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
  Never open-code `cell * 16` anywhere. `tests/test_iso.gd` pins `Iso` against
  a real `TileMapLayer`, so if you change one you will hear about it.

A tile is a 32×16 diamond drawn inside a 32×64 atlas cell. The extra height is
headroom for walls, roofs and trees; `assets/tiles/tiles.json` documents the
layout, and `tools/gen_art.py` gives you `ground()`, `block()` and
`small_block()` so you never have to think about it.

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
pixels. One level is `Iso.ELEVATION_HEIGHT` (8px — half a diamond, the same
lift as stepping one row toward the back), mirrored by `level_px()` in
`tools/pixel.py`. Never write an `8` yourself.

**The flat plane is the simulation; elevation is applied at render time.**
Actor bodies, physics, y-sorting and `Iso.cell_at()` all live on the level-0
plane — `MapData.flat_world_position(cell)` — and the drawing is lifted:
raised tiles go into per-level `TileMapLayer`s shifted up by
`z * ELEVATION_HEIGHT` (keeping their y-sort at the flat cell, so occlusion
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
tools/ci.sh import     # re-import assets; run this after touching anything
tools/ci.sh test       # the whole suite, ~2 seconds
tools/ci.sh generate   # only after editing tiles.json or tools/gen_art.py
tools/ci.sh export     # web build into build/web/ (needs export templates)
tools/ci.sh sheets     # re-render docs/art/ only (no Godot needed)
tools/ci.sh art        # check every tile stands on the grid (no Godot needed)
```

**Working on art?** You cannot judge a 32×16 diamond at 1:1, and you certainly
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
| A reusable lighting mood | `data/lighting/<profile>.json` | `tools/ci.sh test` |
| Who someone is | `data/npcs/<id>.json` | `tools/ci.sh test` |
| What someone says | `dialogue/<id>.json` | `tools/ci.sh test` |
| The tiles that exist | `assets/tiles/tiles.json` + `tools/gen_art.py` | `tools/ci.sh generate` then `test` |
| What a tile does to light (emit, block, glow) | `"lighting"` block in `tiles.json` (+ `e_<name>` painter for glow) | `tools/ci.sh generate` then `test` |
| Bring in bought or downloaded art | `assets/packs/<name>/` + `tiles.json` | `tools/ci.sh art`, then `generate` |
| Movement, interaction, saving | `scripts/*.gd` | `tools/ci.sh test` |
| Key bindings | `tools/setup_input.gd` | run that script, commit `project.godot` |

Lighting is metadata end to end — maps pick profiles, tiles declare behaviour,
and the runtime builds the nodes. Never hardcode a tile name to get a lighting
effect and never place a map's lights in a scene file.
`docs/architecture/AGENTS.md` is the checklist; `docs/architecture/lighting.md`
is the design.

```
maps/*.json          ASCII grids + a legend. One character per tile. Optional
                     "lighting" block: a profile name + overrides.
data/npcs/*.json     display name, sprite, dialogue id, behaviour.
data/lighting/*.json named lighting profiles (ambient + directional).
dialogue/*.json      a node graph: text, choices, flags.
assets/tiles/        tiles.json is the source (atlas cells, solidity, lighting
                     metadata); terrain*.png and terrain.tres are generated.
assets/lights/       GENERATED light falloff textures.
assets/shaders/      hand-written canvas shaders (tile emission).
assets/packs/        imported art. Sheets are sources; see the README in there.
scripts/             game code. map_data.gd holds the validator, iso.gd the
                     projection, world_lighting.gd the lighting runtime.
tools/pixel.py       canvas, PNG, palette, and the diamond primitives. Shared by all renderers.
docs/art/            GENERATED contact sheets and map renders. Look at these.
docs/architecture/   lighting design doc + the scoped AGENTS.md for maps/assets.
scenes/              player, npc, dialogue box, world, title. Nothing content-shaped.
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
renderer cannot drift apart about where a tile is. A stray `x * 16` puts a sign
in a wall on one of the three and nowhere else.

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
