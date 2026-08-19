---
name: build-map
description: Use when adding, editing or debugging a map — a town, a building interior, a dungeon floor, a room — or when a request mentions maps/*.json, tiles, walls, doors, portals, spawns, or "the player can't get to X". Covers the ASCII grid format and the reachability rules the validator enforces.
---

# Building a map

A map is one JSON file in `maps/`. It is an ASCII drawing with a legend, and
that is deliberate: you can read it, review it in a diff, and reason about
whether a room works without ever opening an editor.

## The format

```json
{
  "id": "port_azure_inn_ground",
  "display_name": "The Salt & Sextant",
  "legend": { "f": "wood_floor", "W": "wall_stone", "D": "door" },
  "ground":  ["ffff", "ffff", "ffff"],
  "objects": ["WWWW", "W  W", "WWDW"],
  "spawns":  { "start": [2, 1], "from_town": [2, 1] },
  "portals": [
    { "at": [2, 2], "to": "port_azure_town", "spawn": "from_inn",
      "prompt": "Out to the street", "interact": false }
  ],
  "npcs":  [ { "npc": "bartender", "at": [1, 1], "facing": "down" } ],
  "signs": [ { "at": [3, 0], "text": "NO SINGING AFTER TWO BELLS." } ]
}
```

- `id` must equal the filename without `.json`.
- `ground` is the floor. `objects` sits on top and is y-sorted with characters,
  so the player walks behind a tree and in front of it correctly.
- A space in a layer means "nothing here". Every other character must be in the
  legend, and the legend must not define characters no layer uses.
- Coordinates are `[x, y]`, origin top-left. The grid is square even though
  the world draws isometric — the projection happens on the way to the screen
  and changes nothing about authoring a map.
- `background` (optional, html hex like `"101c18"`) is what the camera sees
  past the corners of the map. A diamond map cannot fill a rectangular view,
  so pick something that reads as "beyond here" — open water off a coast,
  unlit dark around a room. Defaults to a near-black slate.
- `spawns` names arrival points. Portals in other maps refer to them by name.
- `portals` fire when the player steps on the tile. Set `"interact": true` to
  require a key press instead, and give it a `prompt`.
- `facing` is one of `down`, `left`, `right`, `up`. These name **grid**
  directions: `down` is +y, `right` is +x. On screen they come out as the four
  diagonals, and `down`/`right` are the two that face the camera — so an NPC
  meant to be looking at the player wants one of those.

Tile names come from `assets/tiles/tiles.json` — read it first, and use
`"solid": true` there to know what blocks movement. Do not invent tile names;
see the **Adding a tile** section below.

## Rules the validator will hold you to

Run `tools/ci.sh test -- --only maps` and it will tell you, by name, what is
wrong. The checks that catch real mistakes:

**Every layer must be a perfect rectangle.** All rows in `ground` and
`objects` the same length. Count them; a row one character short silently
becomes empty space and usually opens a hole in a wall.

**Everything must be reachable.** A flood fill runs from the `start` spawn and
must reach every portal, every NPC and a tile adjacent to every sign. If you
put a fireplace in front of the stairs, or a table against the only door, this
is what fails. When it does, the message names the cell — walk the grid by hand
from the spawn and find where the path pinches shut.

**Doors lead both ways.** If map A has a portal to map B, map B needs one back
to A, and each portal's `spawn` must exist in the map it points at. A door
whose target spawn is missing quietly drops the player at `start`.

**Nothing stands inside a wall.** Spawns and NPCs must be on walkable tiles.
Signs are the exception: a sign is normally mounted *on* a solid tile, and what
is checked is that a walkable tile sits next to it.

## How to actually draw one

1. Decide the size and write the outer wall first. Interiors: a `wall_top` row
   along the top, `wall_stone` or `wall_wood` down the sides and along the
   bottom, with the door punched into the bottom wall.
2. Fill `ground` completely — every cell, including under walls. The object
   layer covers it.
3. Place furniture, then **trace the player's path from the spawn to every
   door, NPC and sign before running anything.** Two solid tiles diagonally
   adjacent do not block, but a solid tile in a one-tile corridor does.
4. Leave at least one clear tile in front of every door and every NPC.
5. Add the spawns, then the portals, then the NPCs.
6. `tools/ci.sh test -- --only maps`, then `tools/ci.sh test`.
7. **Look at it.** `python3 tools/render_map.py <id> --scale 4 --grid --annotate`
   writes `docs/art/map_<id>.png` with a coordinate grid and markers on every
   spawn, portal, NPC and sign. Reading a room back as a picture catches
   layout mistakes that pass every validator -- a bar with no way behind it, a
   corridor one tile too narrow to feel like a corridor.

Interior maps are usually 14–20 wide and 10–14 tall. Outdoor maps up to about
40×28. Anything larger should be split into several maps joined by portals —
big maps are unreviewable and the validator caps them at 256.

## Adding a tile that does not exist yet

1. Add an entry to `assets/tiles/tiles.json` with a free `atlas` cell and the
   right `solid` flag.
2. Add a `t_<name>` painter to `tools/gen_art.py` and register it in `PAINTERS`.
   The world is isometric, so build from the helpers at the top of that file
   rather than from raw rectangles: `ground()` for flat terrain, `block()` for
   a full-cell solid, `small_block()` for furniture, `foot_shadow()` under a
   prop, `axis_line()` for anything lying along the grid. Speckle with
   `noise()`, never `random`, so the output stays byte-identical.
3. `tools/ci.sh generate` — this redraws `terrain.png` and rebakes
   `terrain.tres`. Commit all three files.
4. **Look at `docs/art/atlas.png`.** Your tile is drawn with its ground diamond
   outlined; art that floats above the outline or spills past it will not line
   up with its neighbours. `AGENTS.md` has the full art loop.
5. `tools/ci.sh test`. The data suite checks the bake matches the registry.

Never write an atlas coordinate anywhere except `tiles.json`.
