#[compute]
#version 450

// The volumetric clouds' ray march, at half the screen's resolution. Same model as volumetric_clouds.gdshader:
// a layer between base and top, a weather map for where, two 3D noises for the shape, a third for the edges,
// Beer-Lambert light with two scattering lobes and a few multiple-scattering octaves. Writes the clouds'
// premultiplied colour and alpha, and how far away they start, for clouds_composite.glsl to put on the screen.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Params {
	mat4 inv_proj;
	mat4 inv_view;
	vec4 layer;      // base, top, coverage, density
	vec4 shape;      // cloud type, shape scale, detail scale, map scale
	vec4 misc;       // detail strength, darkness, light absorption, time
	vec4 wind_steps; // wind offset x, z, steps, light steps
	vec4 sun_dir;    // towards the light; w fog density
	vec4 sun_color;  // linear, times energy; w max distance
	vec4 amb_top;
	vec4 amb_bottom;
	vec4 tint;
	vec4 fog_color;
	vec4 flash;      // position, energy
	vec4 size;       // half width, half height, full width, full height
	vec4 rain;       // rain amount 0..1; near distance (detail and full light march inside it); step growth with
	                 // distance; transmittance at which the march stops
} p;

layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler3D shape_noise;
layout(set = 0, binding = 3) uniform sampler3D erosion_noise;
layout(set = 0, binding = 4) uniform sampler3D detail_noise;
layout(set = 0, binding = 5) uniform sampler2D weather_map;
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D out_cloud;
layout(r32f, set = 0, binding = 7) uniform restrict writeonly image2D out_front;

const float PI = 3.14159265;

float remap(float v, float a, float b, float c, float d) {
	return c + (v - a) / max(b - a, 1e-4) * (d - c);
}

float height_profile(float h, float type) {
	float stratus = smoothstep(0.0, 0.07, h) * (1.0 - smoothstep(0.18, 0.32, h));
	float cumulus = smoothstep(0.0, 0.1, h) * (1.0 - smoothstep(0.45, 1.0, h));
	return mix(stratus, cumulus, type);
}

float cloud_density(vec3 pos, bool detail) {
	float base = p.layer.x;
	float top = p.layer.y;
	float h = (pos.y - base) / (top - base);
	if (h < 0.0 || h > 1.0) {
		return 0.0;
	}
	vec2 drift = p.wind_steps.xy;
	float coverage = p.layer.z;
	float w = texture(weather_map, (pos.xz + drift + drift * 0.002 * h * (top - base)) / p.shape.w).r;
	float c = smoothstep(1.0 - coverage - 0.2, 1.0 - coverage + 0.2, w);
	c = clamp(c - h * h * 0.45 * (1.0 - c * c), 0.0, 1.0);
	float g = height_profile(h, p.shape.x);
	if (g * c < 0.005) {
		return 0.0;
	}
	vec3 q = (pos + vec3(drift.x, 0.0, drift.y)) / p.shape.y;
	float body = texture(shape_noise, q).r;
	float cells = texture(erosion_noise, q * 2.3).r;
	float s = clamp(remap(body, (1.0 - cells) * 0.4, 1.0, 0.0, 1.0), 0.0, 1.0) * g;
	s = clamp(remap(s, (1.0 - c) * 0.9, 1.0, 0.0, 1.0), 0.0, 1.0);
	if (detail && s > 0.0) {
		float d = texture(detail_noise, (pos + vec3(drift.x, -p.misc.w * 1.5, drift.y)) / p.shape.z).r;
		float m = mix(1.0 - d, d, clamp(h * 6.0, 0.0, 1.0));
		s = clamp(remap(s, m * p.misc.x, 1.0, 0.0, 1.0), 0.0, 1.0);
	}
	return s;
}

// Rain falling out of the thick middle of a storm cell, below the cloud base: thin grey curtains with vertical
// streaks, seen from far away. Returned on the same scale as cloud_density.
float rain_density(vec3 pos) {
	float base = p.layer.x;
	if (p.rain.x < 0.01 || pos.y >= base || pos.y < 0.0) {
		return 0.0;
	}
	vec2 drift = p.wind_steps.xy;
	float coverage = p.layer.z;
	float w = texture(weather_map, (pos.xz + drift) / p.shape.w).r;
	// only under the thickest cores of the weather map, so the rain hangs in separate curtains
	float cell = smoothstep(1.0 - coverage * 0.6, 1.0 - coverage * 0.3, w);
	if (cell < 0.01) {
		return 0.0;
	}
	// streaks: the fine noise stretched tall, sliding down
	float streaks = texture(detail_noise, vec3((pos.x + drift.x) / 250.0, pos.y / 3000.0 + p.misc.w * 0.08, (pos.z + drift.y) / 250.0)).r;
	float fade = smoothstep(0.0, base * 0.15, pos.y) * 0.6 + 0.4;
	return p.rain.x * cell * (0.3 + 0.7 * streaks) * fade * 0.035;
}

float hg(float cos_t, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_t, 1e-4), 1.5));
}

float light_depth(vec3 pos) {
	float thickness = p.layer.y - p.layer.x;
	int steps = int(p.wind_steps.w);
	float step_len = thickness * 0.3 / float(steps);
	float od = 0.0;
	vec3 q = pos + p.sun_dir.xyz * step_len * 0.5;
	for (int i = 0; i < steps; i++) {
		od += cloud_density(q, false) * step_len;
		step_len *= 1.4;
		q += p.sun_dir.xyz * step_len;
	}
	return od;
}

float light_depth_far(vec3 pos) {
	float thickness = p.layer.y - p.layer.x;
	return (cloud_density(pos + p.sun_dir.xyz * thickness * 0.08, false) * 0.3
		+ cloud_density(pos + p.sun_dir.xyz * thickness * 0.3, false) * 0.7) * thickness * 0.45;
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 half_size = ivec2(p.size.xy);
	if (px.x >= half_size.x || px.y >= half_size.y) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(half_size);

	// the scene's distance: the furthest of the four full-size pixels under this one, so a thin plane does not
	// cut a hole in the clouds behind it (the composite puts it back in front)
	vec2 texel = 1.0 / p.size.zw;
	float d0 = texture(depth_tex, uv + texel * vec2(-0.5, -0.5)).r;
	float d1 = texture(depth_tex, uv + texel * vec2(0.5, -0.5)).r;
	float d2 = texture(depth_tex, uv + texel * vec2(-0.5, 0.5)).r;
	float d3 = texture(depth_tex, uv + texel * vec2(0.5, 0.5)).r;
	float depth = min(min(d0, d1), min(d2, d3));

	vec4 near_p = p.inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 dir_view = normalize(near_p.xyz / near_p.w);
	vec4 scene_p = p.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	float scene_dist = depth <= 1e-7 ? 1e9 : length(scene_p.xyz / scene_p.w);
	vec3 ro = p.inv_view[3].xyz;
	vec3 rd = normalize((p.inv_view * vec4(dir_view, 0.0)).xyz);

	float base = p.layer.x;
	float top = p.layer.y;
	float max_distance = p.sun_color.w;
	float t0 = 0.0;
	float t1 = max_distance;
	// with rain the march also goes down through the curtains under the clouds
	float bottom = p.rain.x > 0.01 ? 0.0 : base;
	if (abs(rd.y) > 1e-5) {
		float ta = (bottom - ro.y) / rd.y;
		float tb = (top - ro.y) / rd.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = min(max(ta, tb), max_distance);
	} else if (ro.y < bottom || ro.y > top) {
		t1 = -1.0;
	}
	t1 = min(t1, scene_dist);
	if (t1 <= t0 || p.layer.z < 0.005) {
		imageStore(out_cloud, px, vec4(0.0));
		imageStore(out_front, px, vec4(1e9));
		return;
	}

	float cos_t = dot(rd, p.sun_dir.xyz);
	float phase = mix(hg(cos_t, 0.6), hg(cos_t, -0.25), 0.3) * 4.0 * PI;
	float darkness = p.misc.y;
	vec3 sun_light = p.sun_color.rgb * (1.0 - darkness * 0.75);
	float density = p.layer.w;
	int steps = int(p.wind_steps.z);

	float seg = t1 - t0;
	int n = int(mix(float(steps) * 1.8, float(steps) * 0.6, clamp(abs(rd.y) * 3.0, 0.0, 1.0)));
	float base_step = seg / float(n);
	// a different offset each frame, so the composite's blending of frames smooths the steps out
	// a fixed per-pixel pattern stepped on by the golden ratio each frame: over a few frames every pixel tries
	// evenly spread offsets, which the composite's blending of frames then averages
	float frame = floor(p.misc.w * 60.0);
	float jitter = fract(52.9829189 * fract(dot(vec2(px), vec2(0.06711056, 0.00583715))) + frame * 0.61803398875);
	// a whole first step's worth: anything less leaves the slices between steps showing as stacked layers
	float t = t0 + jitter * clamp(max(base_step, t0 * p.rain.z), 10.0, 700.0);
	float trans = 1.0;
	vec3 col = vec3(0.0);
	float front = 1e9;
	for (int i = 0; i < n; i++) {
		if (t >= t1 || trans < p.rain.w) {
			break;
		}
		float ds = clamp(max(base_step, t * p.rain.z), 10.0, 700.0);
		ds = min(ds, t1 - t);
		vec3 pos = ro + rd * (t + ds * 0.5);
		bool near = t < p.rain.y;
		if (pos.y < base) {
			// in the rain under the clouds: grey, lit only by the dim light that gets under a storm
			float rd_ = rain_density(pos);
			if (rd_ > 0.0) {
				float sigma_r = rd_ * density;
				vec3 sr = mix(p.amb_bottom.rgb, p.amb_top.rgb, 0.35) * (1.0 - darkness * 0.5) * 0.55;
				// the haze takes less of the curtains than of the clouds: they are what you see a storm by
				sr = mix(p.fog_color.rgb, sr, exp(-t * p.sun_dir.w * 0.5));
				float tr = exp(-sigma_r * ds);
				col += trans * sr * (1.0 - tr);
				trans *= tr;
			}
			t += ds;
			continue;
		}
		float dens = cloud_density(pos, near);
		if (dens > 0.001) {
			if (front > 1e8) {
				front = t;
			}
			float sigma = dens * density;
			float od = (near ? light_depth(pos) : light_depth_far(pos)) * density * p.misc.z;
			float lum = 0.0;
			float a = 1.0;
			float b = 1.0;
			for (int k = 0; k < 3; k++) {
				lum += a * exp(-od * b) * mix(phase, 1.0, 1.0 - b);
				a *= 0.5;
				b *= 0.35;
			}
			float powder = mix(1.0, 1.0 - exp(-sigma * 120.0), 0.5);
			float h = clamp((pos.y - base) / (top - base), 0.0, 1.0);
			vec3 ambient = mix(p.amb_bottom.rgb, p.amb_top.rgb, h * h) * (1.0 - darkness * 0.55) * mix(0.55, 1.0, h);
			vec3 s = (sun_light * lum * powder + ambient) * p.tint.rgb;
			if (p.flash.w > 0.0) {
				float fd = distance(pos, p.flash.xyz);
				s += vec3(0.75, 0.82, 1.0) * p.flash.w * 2.5e6 / (fd * fd + 2.5e5);
			}
			s = mix(p.fog_color.rgb, s, exp(-t * p.sun_dir.w));
			float step_trans = exp(-sigma * ds);
			col += trans * s * (1.0 - step_trans);
			trans *= step_trans;
		}
		t += ds;
	}
	imageStore(out_cloud, px, vec4(col, 1.0 - trans));
	imageStore(out_front, px, vec4(front));
}
