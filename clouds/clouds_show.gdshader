// Lays the compute pass's finished clouds (premultiplied colour and alpha, already cut out behind solid things)
// over the picture. Drawn first among the see-through things, so trails, smoke and rain go over the clouds.
shader_type spatial;
render_mode unshaded, depth_draw_never, depth_test_disabled, cull_disabled, blend_premul_alpha, fog_disabled, shadows_disabled;

uniform sampler2D clouds : filter_nearest;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec4 c = texture(clouds, SCREEN_UV);
	if (c.a < 0.002) {
		discard;
	}
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
