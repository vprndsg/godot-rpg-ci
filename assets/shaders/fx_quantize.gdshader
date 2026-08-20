// Posterizes the frame to a fixed number of levels per channel.
//
// The known gap docs/architecture/lighting.md describes: 2D light gradients
// render at window resolution, not at the internal one, so they read as
// smooth vector washes over crisp pixels. Stepping the finished frame puts
// them back on a ladder the art can live on.
//
// Reads the screen -- one backbuffer copy. See fx_color_grade.
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D screen : hint_screen_texture, filter_nearest;

// Levels per channel. 8 is gentle, 4 is a statement, 2 is a different game.
uniform float levels : hint_range(2.0, 64.0) = 12.0;
uniform float mix_amount : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec3 source = texture(screen, SCREEN_UV).rgb;
	vec3 stepped = floor(source * levels + 0.5) / levels;
	COLOR = vec4(mix(source, stepped, mix_amount), 1.0);
}
