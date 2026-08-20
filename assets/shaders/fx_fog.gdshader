// Drifting atmosphere: two layers of procedural value noise, no texture.
//
// Procedural on purpose. A video overlay or a big noise PNG would be the
// obvious way to do this and the wrong one for a build that ships to GitHub
// Pages -- this costs a few instructions and no download, and it is
// deterministic, so a screenshot taken twice looks the same.
//
// It is a *mechanism*, not a look: density, colour, scale, speed and the
// vertical gradient are all parameters. The redwood-forest mist is a preset
// somebody writes later, in data/fx/, with no shader change.
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform vec4 color : source_color = vec4(0.72, 0.78, 0.82, 1.0);
uniform float density : hint_range(0.0, 1.0) = 0.25;
uniform float scale : hint_range(0.5, 32.0) = 4.0;
uniform vec2 speed = vec2(0.012, 0.004);
// 0 spreads the fog evenly; 1 pools it at the bottom of the frame.
uniform float floor_bias : hint_range(0.0, 1.0) = 0.35;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
	           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	vec2 uv = UV * scale;
	// Two layers at different rates: one drifting mass, one finer and faster,
	// which is what stops a single octave reading as a moving wallpaper.
	float a = value_noise(uv + TIME * speed);
	float b = value_noise(uv * 2.03 - TIME * speed * 1.7);
	float n = a * 0.65 + b * 0.35;
	float gradient = mix(1.0, UV.y, floor_bias);
	COLOR = vec4(color.rgb, clamp(n * density * gradient, 0.0, 1.0) * color.a);
}
