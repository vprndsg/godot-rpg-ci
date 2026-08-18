# Port Azure

A SNES-era tile RPG in Godot 4. There is no game engine running on anyone's
desktop: every change is made by editing text files, validated by headless
Godot in GitHub Actions, and published to GitHub Pages as a playable web build.

Assume you are running headless. You cannot open the editor, click a node, or
look at a scene. Everything below exists so that you do not have to.

## The loop

```
tools/ci.sh import     # re-import assets; run this after touching anything
tools/ci.sh test       # the whole suite, ~2 seconds
tools/ci.sh generate   # only after editing tiles.json or tools/gen_art.py
tools/ci.sh export     # web build into build/web/ (needs export templates)
```

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
| Who someone is | `data/npcs/<id>.json` | `tools/ci.sh test` |
| What someone says | `dialogue/<id>.json` | `tools/ci.sh test` |
| The tiles that exist | `assets/tiles/tiles.json` + `tools/gen_art.py` | `tools/ci.sh generate` then `test` |
| Movement, interaction, saving | `scripts/*.gd` | `tools/ci.sh test` |
| Key bindings | `tools/setup_input.gd` | run that script, commit `project.godot` |

```
maps/*.json          ASCII grids + a legend. One character per tile.
data/npcs/*.json     display name, sprite, dialogue id, behaviour.
dialogue/*.json      a node graph: text, choices, flags.
assets/tiles/        tiles.json is the source; terrain.png and terrain.tres are generated.
scripts/             game code. map_data.gd holds the validator.
scenes/              player, npc, dialogue box, world, title. Nothing content-shaped.
tests/               the suite. Add to it whenever you add a mechanic.
tools/               generators and ci.sh.
```

## Rules that keep the headless loop working

**Never hand-edit a generated file.** `assets/tiles/terrain.png`,
`assets/tiles/terrain.tres` and `assets/sprites/actors.png` are built by
`tools/ci.sh generate`. CI regenerates them and fails if the result differs
from what is committed.

**Never put map content in a `.tscn`.** A `TileMapLayer` stores its cells as a
binary blob. You cannot read it, review it, or diff it. Maps are ASCII grids
for exactly this reason. `scripts/map_loader.gd` builds the tile layers at
runtime.

**Never add a tile by picking an atlas coordinate in code.** Add it to
`assets/tiles/tiles.json`, draw it in `tools/gen_art.py`, run
`tools/ci.sh generate`. The registry is the only place a coordinate is written
down.

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
- **Everything is reachable.** A flood fill from the spawn must reach every
  portal, NPC and sign. This is what catches a door sealed behind a fireplace
  or an NPC walled into a closet — the bugs you cannot see in a text diff.
- Every portal names a map that exists and a spawn that map defines, and every
  door leads both ways.
- Every dialogue node is reachable from `start`, every jump lands on a real
  node, and every node can still reach an ending.
- Every flag a conversation sets is read by some conversation.
- The baked tileset matches `tiles.json`, tile for tile and solid for solid.

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
