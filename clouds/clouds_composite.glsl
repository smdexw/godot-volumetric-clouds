#[compute]
#version 450

// Makes the full-size clouds out of the half-size march: a smooth upscale, blended with the last frame where the
// camera has not turned much (that hides the march's jitter), and cut out wherever something solid is nearer
// than where the clouds start, so a plane in front of a cloud keeps its sharp edges. The result goes into
// final_out, which a full-screen quad lays over the picture first thing in the transparent pass, so trails,
// smoke and rain (which have no depth) are drawn over the clouds.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Params {
	mat4 inv_proj;
	vec4 size;   // half width, half height, full width, full height
	vec4 blend;  // history weight, metres the camera moved since the last frame, focal length in pixels
} p;

layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler2D cloud_tex;
layout(set = 0, binding = 3) uniform sampler2D front_tex;
layout(set = 0, binding = 4) uniform sampler2D history_tex;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D final_out;
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D history_out;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 full = ivec2(p.size.zw);
	if (px.x >= full.x || px.y >= full.y) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(full);
	vec4 cloud = texture(cloud_tex, uv);
	// the last frame's clouds at the same place on the screen, kept only as far as they agree with this one's
	vec4 old = texture(history_tex, uv);
	vec2 ht = 1.0 / p.size.xy;
	vec4 lo = min(min(texture(cloud_tex, uv + vec2(ht.x, 0.0)), texture(cloud_tex, uv - vec2(ht.x, 0.0))),
		min(texture(cloud_tex, uv + vec2(0.0, ht.y)), texture(cloud_tex, uv - vec2(0.0, ht.y))));
	vec4 hi = max(max(texture(cloud_tex, uv + vec2(ht.x, 0.0)), texture(cloud_tex, uv - vec2(ht.x, 0.0))),
		max(texture(cloud_tex, uv + vec2(0.0, ht.y)), texture(cloud_tex, uv - vec2(0.0, ht.y))));
	old = clamp(old, min(lo, cloud), max(hi, cloud));
	// the last frame is not moved into place: where the camera's move shifts these clouds by more than about a
	// pixel (near clouds, fast flight) it would leave a shifted copy, so it counts for less there
	float front = texture(front_tex, uv).r;
	float shift = p.blend.y * p.blend.z / max(front, 1.0);
	cloud = mix(cloud, old, p.blend.x * clamp(1.5 - shift, 0.0, 1.0));
	imageStore(history_out, px, cloud);

	// anything nearer than where the clouds begin is in front of them
	float depth = texture(depth_tex, uv).r;
	if (depth > 1e-7) {
		vec4 sp = p.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
		float scene_dist = length(sp.xyz / sp.w);
		if (scene_dist < front) {
			cloud = vec4(0.0);
		}
	}
	imageStore(final_out, px, cloud);
}
