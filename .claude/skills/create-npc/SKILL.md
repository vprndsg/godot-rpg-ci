---
name: create-npc
description: Use when adding or changing a character in the world — a villager, shopkeeper, guard, quest-giver — or when a request mentions data/npcs/*.json, an NPC's name, sprite, wandering, or placing someone on a map. Covers the definition format, sprites, and wiring an NPC to a conversation.
---

# Creating an NPC

An NPC is two files and one line: a definition, a conversation, and a placement
on a map. There is no per-character scene — `scenes/npc.tscn` is instantiated
and configured from data.

## 1. The definition — `data/npcs/<id>.json`

```json
{
  "display_name": "Mira Solvang",
  "sprite": "bartender",
  "dialogue": "bartender",
  "behavior": "idle",
  "wander_radius": 1,
  "notes": "Keeps the Salt & Sextant. Holds half the ledger errand."
}
```

- `<id>` is lowercase snake_case and is how maps refer to them.
- `sprite` must be an actor in `assets/sprites/actors.json`. Today that is
  `player`, `bartender`, `harbormaster`, `villager`. Reuse `villager` for
  background characters rather than adding art you do not need.
- `dialogue` names `dialogue/<that>.json`. Defaults to the NPC id.
- `behavior` is `idle` or `wander`. `wander` drifts within `wander_radius`
  tiles of where the map placed them — only give it to someone with clear
  floor around them, and never to someone standing in a doorway.
- `notes` is for humans and future you. It is not read by the game.

## 2. The conversation — `dialogue/<id>.json`

Every NPC needs one; the tests fail on an NPC that points at a dialogue file
that does not exist. See the `create-quest` skill for the graph format. The
smallest useful one:

```json
{
  "id": "cooper",
  "start": "open",
  "nodes": {
    "open": { "speaker": "Odd", "text": "Mind the third table. It has opinions about elbows.", "next": "" }
  }
}
```

`"next": ""` ends the conversation.

## 3. Place them on a map

```json
"npcs": [ { "npc": "cooper", "at": [12, 2], "facing": "down" } ]
```

The cell must be walkable, reachable from the spawn, and not shared with
another NPC. The validator checks all three.

**Talking range is one tile.** The player stands on an adjacent cell, faces the
NPC, and presses interact. So an NPC behind a solid counter cannot be talked
to across it — put them at the open end of the bar, or leave a gap. This is the
single most common mistake; `test_facing_an_interactable_finds_it` catches it.

## Adding a new sprite

Only if an existing one genuinely will not do.

1. Add a row to `ACTORS` in `tools/gen_art.py`: name plus four hex colours
   (skin, hair, shirt, trousers).
2. `tools/ci.sh generate`. This redraws the sheet and rewrites
   `assets/sprites/actors.json`. Commit both.
3. `tools/ci.sh test`.

## Giving an NPC real behaviour

Only when data cannot express it. Write a script that `extends Npc`, override
`_physics_process` or `interact`, and point at it from the definition (put it under `scripts/npcs/`):

```json
{ "script": "res://scripts/npcs/shopkeeper.gd" }
```

Then add a test. An NPC with custom code and no test is how a shop breaks
silently three commits later.

## Finish with

```
tools/ci.sh test
```
