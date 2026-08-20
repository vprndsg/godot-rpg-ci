// Darkens the corners of the frame.
//
// Costs no backbuffer copy: it is an alpha wash over the screen, not a
// re-read of it. That is deliberate -- a vignette is the cheapest way to
// close a composition and there is no reason for it to be the expensive one.
//
// Declared in data/fx/effects.json; every uniform below is a parameter a map
// or a preset may set. scripts/world_fx.gd binds them by name.
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// How far in from the edge the darkening starts, 0..1 of the half-diagonal.
uniform float inner : hint_range(0.0, 1.0) = 0.45;
uniform float outer : hint_range(0.0, 1.5) = 1.0;
uniform float strength : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	// UV is the full-rect ColorRect, so this is screen space by construction.
	vec2 centred = (UV - vec2(0.5)) * 2.0;
	float d = length(centred) / 1.4142136;
	float falloff = smoothstep(inner, outer, d);
	COLOR = vec4(color.rgb, falloff * strength * color.a);
}
