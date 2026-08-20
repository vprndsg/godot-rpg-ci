# FX — atmosphere, grading, and who owns them

Fog, colour grading, pixel quantization, vignettes, and whatever weather comes
later. `scripts/world_fx.gd` owns them; `scripts/fx_config.gd` resolves what a
map asks for; `data/fx/effects.json` is the vocabulary.

## Why this is not part of lighting

`WorldLighting` used to carry a reserved `Fx` child. That was the right hook
and the wrong owner. Fog and grading are not lighting — they are what happens
to the frame *after* lighting — and growing them onto the lighting runtime
would have made one node responsible for ambient tone, sun angle, point
lights, occlusion, shadows and weather.

So they have their own owner, and the dependency runs one way: **WorldFx knows
nothing about WorldLighting, and WorldLighting knows nothing about WorldFx.**
Both are handed the same `MapData` by `World.enter()` and neither talks to the
other.

```
   World.enter(map)
        |
        +--> WorldLighting.apply_map()   ambient, sun, point lights
        +--> ScenePlanes.apply_map()     scenery
        +--> WorldFx.apply_map()         the effect stack
```

## The vocabulary is data

`data/fx/effects.json` declares every effect the game can run: its shader,
where it composites, what it costs, and every parameter with a type and a
default.

```json
"fog": {
  "shader": "res://assets/shaders/fx_fog.gdshader",
  "space": "world",
  "order": 10,
  "reads_screen": false,
  "params": {
    "color":      { "type": "color", "default": "b8c7d1" },
    "density":    { "type": "float", "default": 0.25, "min": 0.0, "max": 1.0 },
    "scale":      { "type": "float", "default": 4.0,  "min": 0.5, "max": 32.0 },
    "speed":      { "type": "vec2",  "default": [0.012, 0.004] },
    "floor_bias": { "type": "float", "default": 0.35, "min": 0.0, "max": 1.0 }
  }
}
```

**Adding an effect is a shader plus an entry.** No new node type, no new
GDScript, no case in a runtime switch — `WorldFx` builds a `ColorRect` with a
`ShaderMaterial` and binds the parameters by name. Because the parameters are
declared, a map can be validated against the catalog rather than against a
runtime failure.

Shipped today, deliberately neutral:

| effect | space | order | reads screen | what it is |
| --- | --- | --- | --- | --- |
| `fog` | world | 10 | no | two layers of procedural value noise, drifting |
| `color_grade` | screen | 20 | **yes** | exposure, tint, saturation, contrast |
| `quantize` | screen | 30 | **yes** | posterizes the frame to N levels per channel |
| `vignette` | screen | 40 | no | closes the composition |

These are **mechanisms, not art direction**. The redwood mist is a preset
somebody writes later, in `data/fx/`, with no shader change.

`quantize` is the fix [`lighting.md`](lighting.md) has been describing as the
known gap since the lighting system shipped: 2D light gradients render at
window resolution, not at the internal one, so they read as smooth vector
washes over crisp art. Stepping the finished frame puts them back on a ladder
the pixels can live on. `data/fx/pixel_quantize.json` is the switch; no map
turns it on yet, because that is an art-direction decision.

## The two spaces

- **screen** — a full-rect `ColorRect` on the fx `CanvasLayer`, above every
  world plane and below all UI. Grading stops at the world's edge; the
  dialogue box is never graded.
- **world** — a `ColorRect` covering the map at a z_index between the depth
  planes, so a mist sits behind the foreground trees and in front of the
  player. See [`scenery.md`](scenery.md) for the plane stack it slots into.

## What a map says

```json
"fx": {
  "preset": "pixel_quantize",
  "effects": [
    { "type": "fog", "density": 0.4, "color": "9fb3bd" },
    { "type": "quantize", "enabled": false }
  ]
}
```

Resolution is the preset first, then the map's own entries, **keyed on type**:
a map may retune one parameter of an inherited effect, or switch it off with
`"enabled": false`, without restating the stack. Named presets live in
`data/fx/<name>.json` and use the same schema minus `preset` — a preset naming
another would be a resolution loop, exactly as it would for a lighting profile.

**The stack composites in the catalog's `order`, never in authoring order.**
Two maps that list the same effects differently produce identical frames, which
is what makes a screenshot a regression test.

**A map with no `"fx"` block gets nothing** — pixel-identical to the world
before this system existed. That is the compatibility contract, and it is the
same one the lighting default makes. Neither shipped map has an `fx` block.

## Performance

This ships to GitHub Pages under GL Compatibility, on whatever hardware a
browser happens to be on. Budget accordingly:

- **`reads_screen` effects cost a backbuffer copy each.** `WorldFx` warns past
  `SCREEN_READ_BUDGET` (2). Prefer one grade that does several things to three
  that each re-read the frame.
- **Procedural over overlays.** The fog is a few instructions of value noise,
  not a video or a large texture. It costs nothing to download, and it is
  deterministic, so a screenshot taken twice looks the same.
- **No per-frame material churn.** Parameters are bound when the stack is
  built. A cutscene that wants to tween one asks `WorldFx.effect("fog")` for
  the live node and tweens its uniform.
- Measure on the web export before shipping a new screen pass.

## Ownership

| concern | owner |
| --- | --- |
| the effect vocabulary | `data/fx/effects.json` |
| named stacks | `data/fx/<preset>.json` |
| resolution + validation | `scripts/fx_config.gd` |
| nodes, binding, lifecycle | `scripts/world_fx.gd` |
| the shaders | `assets/shaders/fx_*.gdshader` |
| what a map asks for | the `"fx"` block in `maps/<id>.json` |

## Forbidden

- **Growing an effect onto `WorldLighting`.** It has enough to do.
- **Hardcoding an effect in a scene.** Same rule as map lights: it would be an
  unreviewable blob, and no map could turn it off.
- **Grading the UI.** The layer budget in `data/rendering.json` puts every
  world effect below `ui`, and `tests/test_fx.gd` asserts it.
- **Adding a `reads_screen` effect without measuring.** Two is a budget, not a
  target.
