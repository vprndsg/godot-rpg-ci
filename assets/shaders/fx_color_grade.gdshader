// Exposure, tint, saturation and contrast over the finished frame.
//
// Reads the screen, so it costs one backbuffer copy. data/fx/effects.json
// marks it "reads_screen" and scripts/world_fx.gd warns when a map stacks
// more of those than the compatibility renderer should be asked to carry.
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D screen : hint_screen_texture, filter_nearest;

uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float exposure : hint_range(0.0, 2.0) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float contrast : hint_range(0.0, 2.0) = 1.0;
uniform float mix_amount : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec3 source = texture(screen, SCREEN_UV).rgb;
	vec3 graded = source * exposure * tint.rgb;
	// Rec. 601 luma: the weights pixel artists actually mix against.
	float luma = dot(graded, vec3(0.299, 0.587, 0.114));
	graded = mix(vec3(luma), graded, saturation);
	graded = (graded - vec3(0.5)) * contrast + vec3(0.5);
	COLOR = vec4(mix(source, clamp(graded, vec3(0.0), vec3(1.0)), mix_amount), 1.0);
}
