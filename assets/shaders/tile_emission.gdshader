// Self-lit tile pixels: lamp flames, firebox glow, window glass.
//
// Applied by scripts/map_loader.gd to both tile layers whenever
// assets/tiles/terrain_emission.png exists. TileMapLayer quads carry UVs into
// the full atlas, and the emission atlas is generated at exactly the same
// size and layout (tools/gen_art.py::build_emission), so the same UV reads
// the matching emission cell.
//
// COLOR arrives already multiplied by the canvas modulate -- the ambient
// darkness scripts/world_lighting.gd applies -- so mixing the raw emission
// colour back in *after* that is what makes these pixels ignore the dark.
// Light2D passes still run afterwards and only ever add, never darken.
//
// This file is also where a future pixel-quantization pass would NOT go:
// that is a whole-screen effect and belongs on a ColorRect under the
// Lighting node's fx hook. See docs/architecture/lighting.md.
shader_type canvas_item;

uniform sampler2D emission_atlas : source_color, filter_nearest;

void fragment() {
	vec4 emission = texture(emission_atlas, UV);
	COLOR.rgb = mix(COLOR.rgb, emission.rgb, emission.a);
}
