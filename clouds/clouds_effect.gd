## The volumetric clouds as a compositor effect. Before the transparent pass, one compute shader ray-marches the
## clouds at a fraction of the screen's size (clouds_march.glsl); a second scales them up, blends in the last frame
## to smooth the noise and cuts them out behind anything solid nearer than where they start
## (clouds_composite.glsl). The result is `display`, a texture that a full-screen quad draws first among the
## see-through things, so smoke, trails and particles go over the clouds. VolumetricClouds feeds it the textures
## and the numbers; everything with the RenderingDevice happens on the render thread.
class_name CloudsEffect
extends CompositorEffect

## the clouds' numbers by the shader's uniform names, swapped in whole by VolumetricClouds every frame
var params := {}
var shape_noise: Texture3D
var erosion_noise: Texture3D
var detail_noise: Texture3D
var weather_map: Texture2D
## the finished clouds, premultiplied, for the quad that shows them
var display := Texture2DRD.new()
## the march runs at the screen's size over this: 2 half, 4 quarter, 1 full
var divisor := 2
## measure the GPU time of the two passes: march_ms and composite_ms, a frame or two late
var timing := false
var march_ms := 0.0
var composite_ms := 0.0

var _rd: RenderingDevice
var _march_shader: RID
var _march_pipeline: RID
var _comp_shader: RID
var _comp_pipeline: RID
var _linear: RID
var _nearest: RID
var _repeat: RID
var _march_params: RID
var _comp_params: RID
var _cloud: RID
var _front: RID
var _final: RID
var _history: Array[RID] = [RID(), RID()]
var _flip := 0
var _size := Vector2i.ZERO
var _divisor_used := 0
var _last_basis := Basis()
var _last_origin := Vector3.INF
var _frames := 0

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()
	if _rd != null:
		RenderingServer.call_on_render_thread(_create)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		for rid in [_march_pipeline, _march_shader, _comp_pipeline, _comp_shader, _linear, _nearest, _repeat,
				_march_params, _comp_params, _cloud, _front, _final, _history[0], _history[1]]:
			if rid.is_valid():
				_rd.free_rid(rid)

func _create() -> void:
	var march: RDShaderFile = load("res://clouds/clouds_march.glsl")
	var comp: RDShaderFile = load("res://clouds/clouds_composite.glsl")
	_march_shader = _rd.shader_create_from_spirv(march.get_spirv())
	_comp_shader = _rd.shader_create_from_spirv(comp.get_spirv())
	if not _march_shader.is_valid() or not _comp_shader.is_valid():
		push_error("CloudsEffect: the cloud shaders did not compile")
		return
	_march_pipeline = _rd.compute_pipeline_create(_march_shader)
	_comp_pipeline = _rd.compute_pipeline_create(_comp_shader)
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_linear = _rd.sampler_create(s)
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_repeat = _rd.sampler_create(s)
	var n := RDSamplerState.new()
	_nearest = _rd.sampler_create(n)
	_march_params = _rd.storage_buffer_create(84 * 4)
	_comp_params = _rd.storage_buffer_create(24 * 4)

func _texture(size: Vector2i, format: int) -> RID:
	var f := RDTextureFormat.new()
	f.width = size.x
	f.height = size.y
	f.format = format
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return _rd.texture_create(f, RDTextureView.new())

func _resize(full: Vector2i) -> void:
	if full == _size and divisor == _divisor_used:
		return
	_divisor_used = divisor
	for rid in [_cloud, _front, _final, _history[0], _history[1]]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_size = full
	var half := Vector2i(maxi(full.x / divisor, 1), maxi(full.y / divisor, 1))
	_cloud = _texture(half, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_front = _texture(half, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	_history[0] = _texture(full, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_history[1] = _texture(full, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_final = _texture(full, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	# the quad's texture follows on the main thread
	display.set_deferred("texture_rd_rid", _final)
	_frames = 0

static func _rd_tex(t: Texture) -> RID:
	if t == null:
		return RID()
	return RenderingServer.texture_get_rd_texture(t.get_rid())

static func _push_projection(a: PackedFloat32Array, m: Projection) -> void:
	for c in [m.x, m.y, m.z, m.w]:
		a.append_array([c.x, c.y, c.z, c.w])

static func _push4(a: PackedFloat32Array, x: float, y: float, z: float, w: float) -> void:
	a.append_array([x, y, z, w])

static func _push_colour(a: PackedFloat32Array, c, w: float = 1.0) -> void:
	if c is Color:
		a.append_array([c.r, c.g, c.b, w])
	else:
		a.append_array([c.x, c.y, c.z, w])

static func _uniform(type: int, binding: int, ids: Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u

func _render_callback(_type: int, render_data: RenderData) -> void:
	if _rd == null or not _march_pipeline.is_valid() or params.is_empty():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	if buffers == null or scene == null:
		return
	var full := buffers.get_internal_size()
	if full.x == 0 or full.y == 0:
		return
	var shape := _rd_tex(shape_noise)
	var erosion := _rd_tex(erosion_noise)
	var detail := _rd_tex(detail_noise)
	var map := _rd_tex(weather_map)
	if not (shape.is_valid() and erosion.is_valid() and detail.is_valid() and map.is_valid()):
		return
	_resize(full)
	var half := Vector2i(maxi(full.x / divisor, 1), maxi(full.y / divisor, 1))
	var depth := buffers.get_depth_layer(0)
	var inv_proj := scene.get_view_projection(0).inverse()
	var cam := scene.get_cam_transform()
	var v := params

	var a := PackedFloat32Array()
	_push_projection(a, inv_proj)
	_push_projection(a, Projection(cam))
	_push4(a, v.cloud_base, v.cloud_top, v.coverage, v.density)
	_push4(a, v.cloud_type, v.shape_scale, v.detail_scale, v.map_scale)
	_push4(a, v.detail_strength, v.darkness, v.light_absorption, Time.get_ticks_msec() / 1000.0)
	_push4(a, v.wind_offset.x, v.wind_offset.y, v.steps, v.light_steps)
	_push_colour(a, v.sun_dir, v.fog_density)
	_push_colour(a, v.sun_color, v.max_distance)
	_push_colour(a, v.ambient_top)
	_push_colour(a, v.ambient_bottom)
	_push_colour(a, v.cloud_tint)
	_push_colour(a, v.fog_color)
	_push_colour(a, v.flash_pos, v.flash_energy)
	_push4(a, half.x, half.y, full.x, full.y)
	_push4(a, v.get("rain", 0.0), v.get("near_distance", 6000.0), v.get("step_growth", 0.01), v.get("min_trans", 0.02))
	var bytes := a.to_byte_array()
	_rd.buffer_update(_march_params, 0, bytes.size(), bytes)

	# the camera turning fast: trust the last frame less, it is in the wrong place
	var turn := cam.basis.get_rotation_quaternion().angle_to(_last_basis.get_rotation_quaternion())
	_last_basis = cam.basis
	var keep := clampf(0.85 - turn * 40.0, 0.0, 0.85) if _frames > 1 else 0.0
	_frames += 1
	var moved := 0.0 if _last_origin == Vector3.INF else cam.origin.distance_to(_last_origin)
	_last_origin = cam.origin
	var focal := scene.get_view_projection(0).y.y * full.y * 0.5
	var b := PackedFloat32Array()
	_push_projection(b, inv_proj)
	_push4(b, half.x, half.y, full.x, full.y)
	_push4(b, keep, moved, focal, 0.0)
	var bbytes := b.to_byte_array()
	_rd.buffer_update(_comp_params, 0, bbytes.size(), bbytes)

	var march_set := UniformSetCacheRD.get_cache(_march_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_march_params]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_nearest, depth]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_repeat, shape]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_repeat, erosion]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [_repeat, detail]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5, [_repeat, map]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 6, [_cloud]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 7, [_front]),
	])
	var read_hist: RID = _history[_flip]
	var write_hist: RID = _history[1 - _flip]
	_flip = 1 - _flip
	var comp_set := UniformSetCacheRD.get_cache(_comp_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [_comp_params]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_nearest, depth]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_linear, _cloud]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_nearest, _front]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [_linear, read_hist]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 5, [_final]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 6, [write_hist]),
	])

	if timing:
		_read_timing()
		_rd.capture_timestamp("clouds_begin")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _march_pipeline)
	_rd.compute_list_bind_uniform_set(list, march_set, 0)
	_rd.compute_list_dispatch(list, (half.x + 7) / 8, (half.y + 7) / 8, 1)
	_rd.compute_list_end()
	if timing:
		_rd.capture_timestamp("clouds_march")

	list = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _comp_pipeline)
	_rd.compute_list_bind_uniform_set(list, comp_set, 0)
	_rd.compute_list_dispatch(list, (full.x + 7) / 8, (full.y + 7) / 8, 1)
	_rd.compute_list_end()
	if timing:
		_rd.capture_timestamp("clouds_done")

## The GPU times of the last frame whose timestamps have come back.
func _read_timing() -> void:
	var t := {}
	for i in _rd.get_captured_timestamps_count():
		t[_rd.get_captured_timestamp_name(i)] = _rd.get_captured_timestamp_gpu_time(i)
	if t.has("clouds_begin") and t.has("clouds_march") and t.has("clouds_done"):
		# the timestamps are in nanoseconds
		march_ms = (t.clouds_march - t.clouds_begin) / 1000000.0
		composite_ms = (t.clouds_done - t.clouds_march) / 1000000.0
