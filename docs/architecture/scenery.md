# Scenery — depth planes, anchors, and four different footprints

How a scene stops being a tilemap and starts being a composition, without the
gameplay noticing.

Companion to [`rendering.md`](rendering.md) (the geometry these planes are
measured in) and [`camera.md`](camera.md) (what frames them).

## The problem

The visual target is a fixed-camera isometric scene: a redwood trunk four
hundred pixels tall, foliage cropped by the top of the frame, a ridge in the
far distance, a character walking behind all of it. Almost none of that is a
tile. Pushing it through the tile grid would mean a tree consuming forty cells
because its canopy is wide — and the moment that happens, "solid" has two
meanings and the flood fill is lying.

So the playable tile world is no longer responsible for everything visible. It
is one plane of five, and the only one that is gameplay.

## The five planes

```
  screen_foreground   CanvasLayer  2    framing art, letterbox, lens dirt
  ---------------------------------------------------------------------
  foreground          Node2D  z=+100    giant cropped trunks, branches
  playable            Node2D  y-sorted  THE WORLD: tiles, actors, collision,
                                        elevation, interactables
  far_background      Node2D  z=-100    distant ridges, silhouettes
  ---------------------------------------------------------------------
  screen_background   CanvasLayer -10   flat skies behind everything
```

`scripts/scene_planes.gd` owns them. `ScenePlanes.PLANES` is the back-to-front
order and the only thing that decides which plane draws over which.

Four rules make this worth having:

1. **Only `playable` is y-sorted.** Depth inside the world is ground contact,
   as it always was. The other planes are ordered by being different planes,
   and within one plane by a placement's `sort` key. Deterministic and cheap.
2. **Only `playable` contains gameplay.** Nothing in a scenery plane collides,
   is interacted with, or is walked on. `tests/test_rendering.gd` asserts that
   every `CollisionObject2D` in the running world is inside it.
3. **Everything is placed by its anchor** — the pixel that touches the ground.
   A 400px redwood and a 48px villager on the same cell are positioned by the
   same rule and sort by the same rule.
4. **The screen planes bracket the world** on the CanvasLayer stack, below
   every effect and far below the UI.

At runtime the scene is:

```
World
├── Lighting            ambient, sun, tile-driven point lights
├── Planes              ScenePlanes
│   ├── ScreenBackground   CanvasLayer
│   ├── FarBackground      Node2D
│   ├── Playable           Node2D, y-sorted
│   │   ├── MapLoader      tiles, NPCs, signs, portals
│   │   └── Player
│   ├── Foreground         Node2D
│   └── ScreenForeground   CanvasLayer
├── Fx                  WorldFx
└── DialogueBox         CanvasLayer
```

`Playable` is the one plane the scene file authors, because MapLoader and
Player have to be parented somewhere at edit time. `ScenePlanes` adopts and
configures it rather than building a second one, so the plane's properties
still come from one file.

## The four footprints

This is the separation the whole visual target rests on. A thing that is
visually enormous is not therefore large in any other sense.

| footprint | what it is | who owns it | how big |
| --- | --- | --- | --- |
| **visual** | the image | the renderer | any size at all |
| **logical** | the cells it occupies in the world model | `"footprint"` in the scenery registry | usually one |
| **collision** | what stops the player | **the map's solid tiles** | the grid, always |
| **occlusion** | what blocks light | `"occluder"` | ≤ logical, often smaller |
| **anchor** | where it touches the ground | `"anchor"` | one pixel |

**Scenery never collides.** That is the load-bearing rule, and it is the one
that keeps simulation and presentation apart. A redwood blocks movement
because the *map* puts a solid tile on its anchor cell. The prop can declare
`"requires_solid": true` and the validator will prove the map did — so the two
cannot silently disagree, and neither one has to know how the other works.

```
      the picture                the world model
   +--------------+
   |    canopy    |            . . . . . . . .
   |   ~~~~~~~~   |            . . . . . . . .
   |  ~~~~~~~~~~  |    <->     . . . # . . . .     one solid tile
   |      ||      |            . . . . . . . .
   |     _||_     |            . . . . . . . .
   +--------------+
     400px tall            one cell of collision
     anchored at its       one small occluder polygon
     trunk's contact       zero cells of anything else
```

## The registry

`assets/scenery/scenery.json`, read by `scripts/scenery_registry.gd`. It ships
empty on purpose: this migration builds the contract, not the forest.

```json
"redwood_trunk": {
  "texture": "res://assets/packs/redwood/trunk.png",
  "anchor": [180, 396],
  "plane": "playable",
  "footprint": [[0, 0]],
  "requires_solid": true,
  "occluder": { "shape": "diamond", "scale": 0.35 },
  "normal": "res://assets/packs/redwood/trunk_normal.png",
  "pack": "redwood",
  "frames": { "count": 4, "fps": 6, "loop": true },
  "frame_size": [240, 400]
}
```

| key | meaning |
| --- | --- |
| `texture` | any `res://` image — generated, imported, whatever |
| `anchor` | **required.** The pixel that touches the ground |
| `plane` | the default plane; a placement may override it |
| `footprint` | cells occupied, relative to the anchor cell. Empty = none |
| `requires_solid` | the map must make those cells solid, and CI checks |
| `occluder` | light-blocking polygon, same schema as a tile's |
| `normal` / `emission` | layout-identical siblings, same convention as everywhere |
| `pack` | provenance, so imported pixels can name their licence |
| `frames` / `frame_size` | optional animation, sliced from a horizontal strip |

## Placing it

A map grows a `"scenery"` array. These are not tiles: no legend character, no
grid row, no rectangle.

```json
"scenery": [
  { "prop": "ridge_far", "space": "world", "at": [0, 0],
    "plane": "far_background", "parallax": 0.35 },
  { "prop": "redwood_trunk", "at": [12, 8] },
  { "prop": "branch_overhead", "space": "screen",
    "plane": "screen_foreground", "screen": [0.5, 0.0] }
]
```

Three spaces, and which one a prop uses decides what moves it:

| `space` | positioned by | moves with |
| --- | --- | --- |
| `world` | `at` (a cell) + `offset` | the world, scaled by `parallax` |
| `camera` | `offset` from the view's centre | the camera, exactly |
| `screen` | `screen` (fractions of the viewport) + `offset` | nothing; it is part of the frame |

`parallax` is 1.0 for an ordinary world object, below 1.0 to drift behind
(distance), above 1.0 to race ahead (foliage brushing the lens). Props at
parallax 1.0 are never touched per frame, so a map with no scenery costs
nothing.

Validation catches: an unknown prop, a cell off the map, a screen-space prop in
a world plane (or the reverse), parallax on something already fixed to the
frame, a bad colour, and — the important one — a prop claiming to block a cell
the map left walkable.

## Adding a scenery prop

1. Get the art in. Anything that produces a PNG: a painter, a pack, a
   PixelOver render. Whatever it is, it is a **source**, and the build output
   stays reproducible from it.
2. Add an entry to `assets/scenery/scenery.json`. The anchor is the number
   that matters; everything else has a default.
3. If it should block the way, give it a `footprint` and `requires_solid`,
   and put the solid tiles in the map. If it should block light, give it an
   `occluder` no bigger than that footprint.
4. Place it in a map's `"scenery"` array, in a plane, in a space.
5. `tools/ci.sh test`, then `tools/ci.sh shots` and look at the frame. Tests
   prove a prop exists; only the picture tells you the composition works.

## Forbidden

- **Making scenery collide.** If the player should be stopped, a tile stops
  them. There is exactly one definition of solid.
- **Expanding a prop's footprint to match its picture.** The picture is not a
  footprint. That is the entire point.
- **Putting scenery in the playable plane to get it sorted, then relying on
  the sort key.** Inside the playable plane, sorting is ground contact; `sort`
  is for the planes that are not y-sorted.
- **Placing scenery in a `.tscn`.** Same rule as map content and lights: it
  would be an unreviewable blob.
