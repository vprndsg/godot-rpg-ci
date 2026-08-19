# Lighting architecture

How Port Azure lights a 2D isometric world from data, headlessly. This is the
implementation reference; the working rules and checklists for agents are in
[`docs/architecture/AGENTS.md`](AGENTS.md).

The system has two halves that never meet in code, only on screen:

- **Environments** — what a *map* says about its light: ambient tone, an
  optional sun. Authored as a profile name plus overrides in the map JSON,
  resolved by `scripts/lighting_profile.gd`, applied by
  `scripts/world_lighting.gd`.
- **Behaviours** — what a *tile* says about light: emits it, blocks it, or
  ignores the dark. Authored in `assets/tiles/tiles.json`, read by
  `scripts/tile_registry.gd`, turned into nodes by the runtime and into baked
  polygons/pixels by the generators.

Nothing anywhere keys lighting off a tile *name*. If you find yourself writing
`if tile_name == "lamp"`, the metadata is missing and that is what to fix.

## Data flow

```
                    MAP JSON  maps/<id>.json
                       │
                "lighting" block ── profile name + overrides
                       │
                       ▼
                   MapData.lighting          (raw, validated)
                       │
                       ▼
              LightingProfile.resolve()      defaults <- data/lighting/<p>.json <- map overrides
                       │
                       ▼
                     World.enter()
                       │
                 WorldLighting.apply_map()
            ┌──────────┼──────────────┐
            ▼          ▼              ▼
        Ambient       Sun        DynamicLights
    CanvasModulate  DirectionalLight2D  PointLight2D per emitting cell


                 TILE METADATA  assets/tiles/tiles.json "lighting"
                       │
         ┌─────────────┼──────────────────┐
         ▼             ▼                  ▼
       emit         occluder           emission
         │             │                  │
   WorldLighting   tools/build_tileset.gd    tools/gen_art.py e_<name> painter
   (runtime)       bakes polygon into     draws pixels into
         │         terrain.tres           terrain_emission.png
         ▼             │                  │
   PointLight2D    TileMapLayer occludes  layer shader keeps them lit
                   shadowed lights        (assets/shaders/tile_emission.gdshader)
```

## The scene shape at runtime

```
World
├── Lighting  (scripts/world_lighting.gd; children built in code)
│   ├── Ambient        CanvasModulate
│   ├── Sun            DirectionalLight2D
│   ├── DynamicLights  container, rebuilt on every map change
│   └── Fx             reserved for screen effects (see "hooks" below)
├── MapLoader          tile layers carry the emission ShaderMaterial
├── Player
│   └── Camera         scripts/game_camera.gd
└── DialogueBox        CanvasLayer -- outside the modulated canvas on purpose
```

UI lives on `CanvasLayer`s (dialogue, title, the Router's fade), so the
ambient `CanvasModulate` darkens the world and the actors in it, never the
interface.

## Map environments

A map opts in with a `"lighting"` block; every field is optional:

```json
"lighting": {
  "profile": "warm_interior",
  "ambient_color": "e6c69e",
  "ambient_energy": 0.72,
  "directional": {
    "enabled": true, "color": "fff0d0", "energy": 0.1,
    "angle_degrees": -35, "height": 0.5, "shadows": false
  }
}
```

Resolution order: identity defaults ← `data/lighting/<profile>.json` ← the
map's own keys. A map with no block resolves to `data/lighting/default.json`,
which is full-bright white with no sun — **pixel-identical to the world before
this system existed**. That default is the backward-compatibility contract;
never make it moodier.

Profile files use the same schema minus `"profile"` (no profile may name
another). Baselines shipped: `default`, `outdoor_day`, `outdoor_evening`,
`moonlit`, `warm_interior`, `dark_interior`. Their art direction is
deliberately unfinished — tune values, keep names.

The directional light is a flat additive wash until art carries normal maps or
a profile enables shadows; `angle_degrees` and `height` are authored now so
scenes read correctly the day they matter.

## Tile behaviours

The `"lighting"` block on a tile in `tiles.json`:

```json
"lamp": {
  "atlas": [5, 3], "solid": true,
  "lighting": {
    "emit": { "color": "ffd27a", "energy": 0.9, "radius": 40, "offset": [0, -22] },
    "emission": true
  }
}
```

**`emit`** — every map cell using the tile gets a `PointLight2D`, spawned by
`WorldLighting._spawn_tile_lights()` and destroyed on map change. Fields (all
optional): `color` (html, default white), `energy` (default 1.0), `radius` in
screen pixels (default 32), `offset` in screen pixels from the centre of the
tile's ground diamond — negative y is up, a lamp head is high (default
`[0, 0]`), `height` for normal-mapped shading (default 12; never zero, or
normal-mapped art receives nothing), `shadows` (default false — shadows are
the expensive part, see the performance rules).

**`occluder`** — the tile blocks light. `true` bakes its footprint diamond;
`{"shape": "diamond", "scale": 0.5}` shrinks it (a trunk); `{"points": [...]}`
supplies pixels relative to the diamond centre. Baked by
`tools/build_tileset.gd` into an occlusion layer in `terrain.tres`, so
occlusion costs nothing at runtime and needs no nodes. Occlusion, collision
and visual bounds are three different footprints on purpose — a tree collides
on its whole diamond, occludes on its trunk, and draws a canopy far outside
both. A tile that *hosts its own light* (the fireplace) must not occlude: a
light inside its own occluder is swallowed whole. Let its wall neighbours
block for it.

**`emission`** — the tile has pixels that ignore the dark. The pixels live in
`assets/tiles/terrain_emission.png`, an atlas laid out exactly like
`terrain.png`, drawn by an `e_<name>` painter in `tools/gen_art.py` (the flag
and the painter table must agree; the generator fails otherwise). At runtime
`MapLoader` puts one `ShaderMaterial`
(`assets/shaders/tile_emission.gdshader`) on both tile layers; tile quads
carry atlas UVs, so the shader mixes each pixel's emission colour back in
after the ambient modulate has darkened everything. Alpha in the emission
atlas is emission strength. Emission is per-pixel where `emit` is per-cell:
the firebox glows (emission) *and* throws light on the floor (emit).

## The material-map contract

An atlas may be accompanied by same-layout siblings:

```
assets/tiles/terrain.png            diffuse -- always present, works alone
assets/tiles/terrain_normal.png     optional; baked into a CanvasTexture
assets/tiles/terrain_emission.png   optional; bound to the layer shader
```

```
                 ASSET
                   │
       ┌───────────┼───────────┐
       ▼           ▼           ▼
    diffuse      normal     emission
       │           │           │
  atlas source  CanvasTexture  layer shader uniform
       │        (build_tileset)  (map_loader)
       └───────────┼───────────┘
                   ▼
              Godot canvas
                   │
                   ▼
              final sprite
```

`tools/build_tileset.gd` checks for `terrain_normal.png`; when it exists the
tileset's texture becomes a `CanvasTexture` (diffuse + normal) and every 2D
light starts shading tiles by their normals — no other code changes. When it
does not exist, nothing changes. No normal atlas ships yet; the wiring is
live, dormant, and tested for absence. Before shipping one: every cell needs
a valid neutral (`8080ff`) where it has no authored normal, and every light
already sets `height > 0` so flat normals still receive light.

The same convention holds for actor sheets (`actors_normal.png` etc.) and
pack sheets (`sheet_normal.png`, `sheet_emission.png`) when someone builds
that wiring; name siblings with `_normal` / `_emission` suffixes, always
layout-identical to their diffuse.

## Pixel-art integrity

Lighting must not read as smooth vector gradients over crisp pixels:

- The point-light falloff texture (`assets/lights/point_light.png`, generated
  by `tools/gen_art.py::build_lights`) is quantized into six rings; with the
  project's nearest filtering it scales chunky, not silky.
- Point-light shadows use `SHADOW_FILTER_NONE` — hard edges are the cheap
  option *and* the correct look.
- Emission replaces pixels with their authored colours; nothing blooms.

The remaining smoothness (light gradients render at window resolution, not at
the 320×192 internal grid) is the known gap. The fix, when wanted, is a
whole-screen quantization pass: a `ColorRect` with a palette/step shader under
`WorldLighting.fx_root()` — that hook exists for exactly this, and no
architecture changes are needed to add it. Do not "fix" it by baking light
into diffuse art.

## Ownership

| Concern | Owner |
| --- | --- |
| Isometric projection | `scripts/iso.gd` (mirrored by `tools/pixel.py`) |
| Map parsing + validation | `scripts/map_data.gd` |
| Map instantiation | `scripts/map_loader.gd` |
| Tile metadata (incl. lighting) | `assets/tiles/tiles.json` via `scripts/tile_registry.gd` |
| Environment profiles | `data/lighting/*.json` via `scripts/lighting_profile.gd` |
| Lighting runtime | `scripts/world_lighting.gd` |
| Emission shader | `assets/shaders/tile_emission.gdshader` |
| Tileset bake (occluders, normal wiring) | `tools/build_tileset.gd` |
| Generated light/emission pixels | `tools/gen_art.py` |
| Camera behaviour | `scripts/game_camera.gd` |

## Hooks left for the future

- `WorldLighting.fx_root()` — parent for fog, colour grading, the
  quantization pass.
- `WorldLighting.add_point_light(spec, pos)` — scripted one-off lights
  (spells, cutscenes) that share tile-light cleanup.
- `GameCamera.focus_on()` / `release_focus()` — cinematic framing that a
  lighting beat can coordinate with, without touching the player transform.
- Time-of-day / weather — a controller that tweens between resolved profiles;
  `apply_profile(profile, duration)` is already the primitive it needs.

## Tests

`tests/test_lighting.gd` pins all of it: profile parsing, the identity
default, malformed data, tile metadata validation, occluder and emission
drift against the bake, runtime light creation and cleanup across map
changes, and the renderer/viewport settings the pixel look depends on.
`tools/ci.sh test` runs it with everything else.
