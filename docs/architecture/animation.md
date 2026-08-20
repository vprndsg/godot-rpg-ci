# Animation — the actor manifest

Everything about a character is data. `scripts/actor_sprite.gd` knows no
character's name, no frame size, no walk speed and no number of directions; it
reads `assets/sprites/actors.json` through `scripts/actor_manifest.gd` and
draws what it says.

That indirection is the whole feature. A Blender → PixelOver character with
eight directions, a 96 × 128 frame, an eight-frame walk at 10fps and a
one-shot `sniff` drops in as JSON. The four legacy townspeople — 32 × 48, four
directions, `idle` and `walk` — are the same schema with less filled in.

## The schema

```json
{
  "version": 2,
  "directions": ["down", "down_left", "left", "up_left",
                 "up", "up_right", "right", "down_right"],
  "clip_fallbacks": { "run": "walk", "trot": "walk", "sniff": "idle" },

  "sheets": {
    "coyote": {
      "texture": "res://assets/packs/coyote/sheet.png",
      "frame_size": [96, 96],
      "anchor": [48, 88],
      "normal": "res://assets/packs/coyote/sheet_normal.png"
    }
  },

  "actors": {
    "coyote": {
      "sheet": "coyote",
      "directions": ["down", "down_left", "left", "up_left",
                     "up", "up_right", "right", "down_right"],
      "clips": {
        "idle":  { "row": 0,  "frames": 2, "fps": 3,  "loop": true },
        "walk":  { "row": 8,  "frames": 8, "fps": 10, "loop": true },
        "trot":  { "row": 16, "frames": 6, "fps": 14, "loop": true },
        "sniff": { "row": 24, "frames": 6, "fps": 8,  "loop": false,
                   "directions": ["down", "right"] }
      },
      "fallbacks": { "sit": "idle" }
    }
  }
}
```

Four things are separated on purpose, because they change independently:

| concern | lives in |
| --- | --- |
| identity (who this actor is) | the key under `actors` |
| the pixels (which sheet, how big a frame, where the feet are) | `sheets` |
| the clips (what it can do, for how many frames, how fast) | `clips` |
| the directions (which ones were authored) | `directions`, per actor or per clip |

`frame_size` and `anchor` may be stated per actor to override the sheet's, so
two characters can share one texture at different sizes.

**Rows.** A clip's `row` is the sheet row of its **first** direction; direction
*d* of that clip is `row + d` in the clip's own direction order. Frames run
horizontally from column 0. That is the only layout rule, and it is what lets a
contact sheet, a validator and the runtime agree without a second file.

## The eight directions

They are **grid** directions, like everything else in this project — so on
screen the four grid axes are the diagonals, and the four grid diagonals are
the screen axes.

```
      grid                              screen
        up                       up_right    up    down_right
   up_left  up_right                   \     |     /
      \     |     /                      \   |   /
 left ----  o  ---- right      left ------  o  ------ right
      /     |     \                      /   |   \
 down_left  |  down_right               /    |    \
       down                       up_left   down   down_left
```

`down` and `right` come toward the camera and show a face; `up` and `left`
show a back. `down_right` is straight down the screen.

**Facing is chosen by angle against the real step**, not by quantising first.
A step of (2, 1) faces `right` even for a character with all eight authored,
because it really is closer to right than to down-right. Ties go to the grid
axes, which reproduces the four-direction rule this project shipped with: a
step of exactly (1, 1) faces `down`, not `right`. `tests/test_animation.gd`
pins every one of those cases.

## Sparse sets and fallback

A character need not author everything, and asking for something it lacks is
not an error:

- **Missing clip** → the actor's own `fallbacks`, then the manifest-wide
  `clip_fallbacks`, then `idle`, then whatever clip it does have. `run` falls
  back to `walk`; a sheet is never undrawable.
- **Missing direction** → the nearest authored one, by angle. A `sniff`
  authored only for `down` and `right` still draws when the actor faces
  `up_left`.

**Missing is fine. Malformed is never fine.** A zero-frame clip, a row off the
end of the sheet, a frame count with no frame rate, an anchor outside its own
frame, a fallback pointing at a clip that does not exist, an unknown direction
name — all of these fail `ActorManifest.validate()` loudly, because a manifest
that silently half-works is the worst outcome for headless authoring.

## The runtime

```gdscript
sprite.actor = "coyote"          # which character
sprite.facing = "up_right"       # snapped to the nearest authored direction
sprite.moving = true             # the walk/idle convenience
sprite.play("sniff")             # an explicit clip; one-shots clear themselves
sprite.stop_action()             # back to walk/idle
sprite.ground_lift = 32.0        # elevation, applied to the drawing only
```

`clip_finished` fires when a non-looping clip reaches its last frame, so a
cutscene can await it.

Two rules the node will not bend:

- **The origin is the feet.** `offset` is computed from the manifest's anchor,
  so the node's position is the patch of ground the actor stands on whatever
  the picture does above it. A 300px character sorts exactly like a 48px one.
- **Elevation is drawn, not simulated.** `ground_lift` moves the picture up
  the hill; the body underneath never leaves the flat plane. See
  `MapData.flat_world_position`.

## Adding a character

1. Put the sheet somewhere — a pack directory is the usual answer for
   imported art, and carries the licence with it.
2. Add a `sheets` entry: texture, frame size, anchor. The anchor is the pixel
   the character stands on.
3. Add an `actors` entry: the sheet, the directions authored, the clips.
4. `tools/ci.sh generate` then `tools/ci.sh test` — the manifest validates,
   the sheet is checked for every clip's rows and columns, and
   `docs/art/actors.png` re-renders with the new layout (the contact sheet
   reads the manifest; it does not assume four directions and four frames).
5. Look at `docs/art/actors.png`.

## The legacy cast

`assets/sprites/actors.json` is **generated** by `tools/gen_art.py` — never
hand-edit it. The four townspeople in it are placeholders: drawn for a 16 × 24
frame, magnified ×2 into 32 × 48 by the same integer scaling the tiles get
(see [`rendering.md`](rendering.md)). They author four of the eight directions
and two of the clips. Everything above works on them because the fallback
rules are what make a sparse set legal — not because the runtime special-cases
them.
