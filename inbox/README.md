# inbox

Drop an asset in here, run one command, get a wired-up pack:

```
tools/ci.sh inbox
```

A `.glb` or `.gltf` becomes an isometric pixel-art character: baked from every
grid direction at the production geometry, installed under
`assets/packs/<name>/`, folded into the generated actor manifest, and put
through the same gates a human would run. The source file is consumed — it
ends up inside the pack under `source/`, which is what a re-bake reads.

Settings are set once in `data/inbox.json`. Anything one asset needs
differently goes in `inbox/<name>.json` beside it. `docs/architecture/inbox.md`
is the whole design, including what to change when a sprite comes out facing
the wrong way.

The empty `.gdignore` here is not decoration: without it Godot's importer
treats a dropped `.glb` as a 3D scene, extracts its textures into this
directory and writes `.import` sidecars all over it.
