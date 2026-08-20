---
name: test-game
description: Use when running, writing or debugging tests for this project, when CI is red, when a change needs verifying before a pull request, or when a request mentions tests/, tools/ci.sh, headless Godot, or "check that it works". Covers the suites, how to run one, and how to write a test that catches real bugs.
---

# Testing

Everything runs headless. There is no editor and no way to look at the game, so
the suite is the only thing standing between a change and a broken build.

## Running

```
tools/ci.sh test                    # everything, ~2 seconds
tools/ci.sh test -- --only maps     # one suite: maps, dialogue, data, project, runtime
tools/ci.sh import                  # after changing assets, scenes or project.godot
tools/ci.sh generate                # after changing tiles.json or tools/gen_art.py
tools/ci.sh export                  # web build, needs export templates
```

`tools/ci.sh test` fails on assertion failures **and** on any `SCRIPT ERROR`,
`Parse Error` or `ERROR:` the engine prints. That second part matters: a
GDScript parse error makes Godot skip the autoload and keep going with exit
code 0, so a project that is fundamentally broken otherwise looks fine.

If a change touches scenes, `project.godot` or anything in `assets/`, run
`tools/ci.sh import` first or the suite tests the previous version.

## The suites

| Suite | Proves |
| --- | --- |
| `test_project` | Every script parses, every scene instantiates, autoloads exist, input actions are bound. |
| `test_data` | The baked tileset matches `tiles.json`; sprites exist; every NPC definition resolves and is placed somewhere. |
| `test_maps` | Every map validates: rectangular, legend complete, everything reachable, doors two-way, world connected. |
| `test_dialogue` | Every graph is sound and every conversation can be played to an end. |
| `test_runtime` | The game boots, the player walks, walls stop them, doors move them, every NPC and sign can actually be interacted with. |
| `test_iso` | The projection matches a real `TileMapLayer` at the production 64×32 geometry, and every derived dimension comes from the registry. |
| `test_elevation` | Terrain height parses, cliffs block, stairs carry, and the player really climbs the hill. |
| `test_lighting` | Profiles, tile lighting metadata, baked occluders, the emission atlas, and lights spawning and being swept. |
| `test_rendering` | The presentation contract matches `project.godot`; the five depth planes exist; all collision is in the playable plane. |
| `test_animation` | Eight directions, variable clips and frame rates, per-actor frame sizes, fallbacks, and malformed manifests. |
| `test_camera` | FOLLOW / ROOM_LOCKED / FIXED, and a cinematic returning the camera to the mode it borrowed. |
| `test_fx` | The effect catalog, deterministic compositing order, preset overrides, and world effects staying below the UI. |
| `test_scenery` | Enormous sprites with one-cell footprints, and scenery never becoming collision. |
| `test_packs` | Imported art: the `_normal`/`_emission` naming contract, licences, and pack tiles behaving like drawn ones. |

## Writing a test

Subclass `TestCase`, name methods `test_*`, and put the file in `tests/` as
`test_<area>.gd`. The runner finds it automatically.

```gdscript
extends TestCase

func test_a_wall_stops_the_player() -> void:
    var map := MapData.load_map("port_azure_town")
    ok(map.is_solid(Vector2i(0, 19)), "the border row should block movement")
```

Assertions: `ok(condition, message)`, `equal(actual, expected, message)`,
`not_empty(value, message)`, `fail(message)`, and
`expect_no_errors(errors, subject)` for anything returning a list of problems.
Messages are read by someone who cannot see the game — name the map, the cell,
the NPC.

For anything needing the live tree, `await frames(n)` or
`await physics_frames(n)`. Area overlaps and collisions need at least two
physics frames to settle. `tests/test_runtime.gd` shows booting the real scene
and driving it with `Input.action_press`.

## Test the path, not the function

The bug that shipped in this repo's first pass: signs were unreadable, because
`find_interactable()` looked at the wrong node for anything built in code.
`test_every_npc_can_be_talked_to` passed the whole time — it called
`npc.interact()` directly, which proved the dialogue worked but not that a
player could ever trigger it.

The test that catches it stands the player on a neighbouring cell, faces them
at the target, waits for physics, and asserts `find_interactable()` returns
something. Write that kind. Ask: *what does the player actually do, and what
would silently not happen?*

## When CI is red

1. Read the failure. Every validator message names the file, and usually the
   cell, node or NPC.
2. Reproduce locally with the narrowest suite: `tools/ci.sh test -- --only maps`.
3. Fix the cause, not the assertion. If a check is genuinely wrong, change it
   deliberately and say why in the commit message.
4. Re-run the full suite before pushing — the suites overlap, and a map fix
   frequently breaks a runtime expectation.
