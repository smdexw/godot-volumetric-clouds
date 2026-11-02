// A plain sea with small moving waves and the clouds' shadows on it. The shadows come from the same weather map and
// body noise the clouds are made of, looked up where the sunlight crosses the lower part of the layer.
shader_type spatial;

uniform vec4 sea_color : source_color = vec4(0.05, 0.22, 0.36, 1.0);
uniform sampler2D cloud_map : repeat_enable, filter_linear;
uniform sampler3D cloud_noise : repeat_enable, filter_linear;
uniform float coverage = 0.4;
uniform float cloud_base = 900.0;
uniform float cloud_top = 2600.0;
uniform vec2 wind = vec2(0.0);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);

varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float cloud_shadow(vec3 wp) {
	float mid = mix(cloud_base, cloud_top, 0.25);
	vec2 xz = wp.xz + sun_dir.xz / max(sun_dir.y, 0.1) * (mid - wp.y);
	float w = texture(cloud_map, (xz + wind) / 36000.0).r;
	float c = smoothstep(1.0 - coverage - 0.2, 1.0 - coverage + 0.2, w);
	float body = texture(cloud_noise, vec3(xz.x + wind.x, mid, xz.y + wind.y) / 5000.0).r;
	float edge = (1.0 - c) * 0.9;
	return clamp((body * 0.75 - edge) / max(1.0 - edge, 0.05) * 3.0, 0.0, 1.0);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz * 0.08;
	float t = TIME * 0.6;
	float e = 0.15;
	float h0 = noise(p + t) * 0.6 + noise(p * 2.3 - t) * 0.4;
	float hx = noise(p + vec2(e, 0.0) + t) * 0.6 + noise((p + vec2(e, 0.0)) * 2.3 - t) * 0.4;
	float hz = noise(p + vec2(0.0, e) + t) * 0.6 + noise((p + vec2(0.0, e)) * 2.3 - t) * 0.4;
	vec3 n = normalize(vec3(-(hx - h0) * 2.0, e, -(hz - h0) * 2.0));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float shade = cloud_shadow(world_pos);
	ALBEDO = sea_color.rgb * (1.0 - shade * 0.7);
	ROUGHNESS = 0.25 + shade * 0.4;
	SPECULAR = 0.6 * (1.0 - shade * 0.8);
}
