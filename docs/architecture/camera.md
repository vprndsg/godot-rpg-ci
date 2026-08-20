# Camera — four modes and one borrow

`scripts/game_camera.gd`. The node is a child of the player scene, so
following costs nothing: the transform is already the player's. The other
modes detach it and put it where the map asked, which is what lets the player
walk *through* a composed frame instead of dragging it around.

## The modes

| mode | transform | clamped to | for |
| --- | --- | --- | --- |
| `FOLLOW` | rides the player | the whole map | ordinary play. The default, and what every shipped map gets |
| `ROOM_LOCKED` | rides the player inside a room, or holds its centre | the room | interiors, deliberately composed outdoor areas |
| `FIXED` | an authored point | nothing | the fixed-camera isometric composition the visual target is built around |
| `CINEMATIC` | borrowed — whatever was in force, plus an `offset` a cutscene drives | unchanged | scripted moments |

```
        map data                       runtime
   "camera": {...}  --->  CameraConfig  --->  GameCamera.fit_to_map()
                                                   |
                     +-----------------+-----------+------------+
                     v                 v                        v
                  FOLLOW          ROOM_LOCKED                 FIXED
              child of player   child, limited to      top_level, sitting
              limited to map    the room  -- or        exactly where the
                                held centred when      map put it
                                the room is smaller
                                than the screen
                     \                |                        /
                      +-------- borrow() --------> CINEMATIC --+
                                                        |
                                                    release()
                                          returns to the mode it took
```

**`ROOM_LOCKED` has two behaviours on purpose.** A room bigger than the screen
scrolls, clamped to the room. A room *smaller* than the screen cannot be
scrolled without showing what is outside it, so the camera detaches and holds
the room's centre — the composition is the room, not the player's position in
it. That is the case an interior actually hits.

**`FIXED` is not clamped.** The whole point of an authored composition is that
it is exactly what was authored; clamping it to map bounds would quietly shift
the frame.

**`CINEMATIC` is a borrow, not a fifth framing.** `focus_on()` takes the
camera and remembers what it was doing; `release_focus()` gives it back to
*that* — FIXED returns to FIXED, not to FOLLOW. A cutscene that assumed FOLLOW
on the way out would silently turn a composed scene into a player-chasing one,
which is precisely the bug the mode system exists to prevent. Everything a
cutscene does happens through `offset`, so the transform underneath is never
disturbed and there is nothing to restore but the mode.

Borrowing twice is harmless; the first borrow is the one remembered.

## What a map may say

A map's optional `"camera"` block, validated by `scripts/camera_config.gd` as
part of `MapData.validate()` — so a broken framing fails CI, not a black
screen.

```json
"camera": { "mode": "room_locked", "room": [4, 2, 12, 9] }
"camera": { "mode": "fixed", "at": [12, 8], "offset": [0, -24], "zoom": 1.0 }
"camera": { "mode": "fixed", "position": [640.0, 320.0], "smoothing": false }
```

| key | meaning |
| --- | --- |
| `mode` | `follow`, `room_locked` or `fixed` |
| `room` | `[x, y, w, h]` in cells. Required by `room_locked` |
| `at` | the cell a `fixed` camera centres on |
| `position` | a raw screen position, for framing that lands between cells |
| `offset` | screen pixels added to the resolved anchor |
| `zoom` | default 1.0 |
| `smoothing` | defaults on for `follow`, off for `fixed` |

`cinematic` is deliberately **not** authorable, and asking for it produces a
validation error that says why.

**A map with no `"camera"` block gets FOLLOW over the whole map** — bit for
bit what every map did before modes existed. None of the shipped maps has one,
and `tests/test_camera.gd` asserts they do not, so the compatibility promise is
checked rather than assumed.

## Bounds

`FOLLOW` clamps to `Iso.grid_bounds()` of the map, with the top pushed up by
`TileRegistry.footprint_top()` plus a level's worth of `Iso.elevation_height()`
for every level the terrain rises — so the back row keeps the headroom its tall
art draws into, instead of having its roofs sliced off. Only the top moves; the
bottom stays where the ground ends.

`ROOM_LOCKED` clamps to `Iso.cell_bounds(room)`. That function is the general
form of `grid_bounds()`: the four extremes of a block of diamonds belong to
four different cells, which is easy to get wrong by hand and is pinned in
`tests/test_iso.gd`.

Everything is measured in production tiles, so the limits scale with the
geometry on their own. See [`rendering.md`](rendering.md).

## Costs nothing per frame

No mode runs `_process`. A following camera is moved by its parent; a detached
one does not move at all. The cost of a mode is paid once, when it is entered.
