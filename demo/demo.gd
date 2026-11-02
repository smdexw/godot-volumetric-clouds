## The demo: a sky, a sun, a sea and a camera you fly through the clouds.
##
##   mouse            look (click to capture, Esc to let go)
##   W A S D          fly, Space / Ctrl up / down, Shift faster, wheel changes speed
##   1 - 6            weather: clear, fair, cloudy, showers, overcast, storm
##   F1 F2 F3         quality: low, medium, high
##   Z / X, C / V     sun lower / higher, turn the sun left / right
##   H                hide this help
##
## Command line (after --): --weather=storm --quality=low --height=1500 --pitch=-20 --shot=4 --quit=5
extends Node3D

const WEATHER_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6]
const WEATHER_NAMES := ["clear", "fair", "cloudy", "showers", "overcast", "storm"]

var clouds: VolumetricClouds
var sun: DirectionalLight3D
var cam: Camera3D
var sea_mat: ShaderMaterial
var label: Label
var speed := 120.0
var weather := "fair"
var quality := "high"
var _yaw := 0.0
var _pitch := 4.0
var _ms := 0.0
var _shot_at := -1.0
var _quit_at := -1.0
var _time := 0.0

func _ready() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.42, 0.78)
	sky_mat.sky_horizon_color = Color(0.65, 0.76, 0.86)
	sky_mat.ground_horizon_color = Color(0.65, 0.76, 0.86)
	sky_mat.ground_bottom_color = Color(0.1, 0.2, 0.28)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.65, 0.76, 0.86)
	env.fog_density = 0.00012
	env.fog_aerial_perspective = 0.6
	env.fog_sky_affect = 0.3
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 30, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)

	var plane := PlaneMesh.new()
	plane.size = Vector2(60000, 60000)
	sea_mat = ShaderMaterial.new()
	sea_mat.shader = load("res://demo/sea.gdshader")
	var sea := MeshInstance3D.new()
	sea.mesh = plane
	sea.material_override = sea_mat
	add_child(sea)

	clouds = VolumetricClouds.new()
	clouds.world_environment = world_env
	clouds.sun = sun
	add_child(clouds)
	if clouds.effect != null:
		clouds.effect.timing = true
		sea_mat.set_shader_parameter("cloud_map", clouds.noise_texture("map"))
		sea_mat.set_shader_parameter("cloud_noise", clouds.noise_texture("shape"))

	cam = Camera3D.new()
	cam.far = 60000.0
	cam.fov = 60.0
	cam.position = Vector3(0, 300, 0)
	add_child(cam)
	cam.make_current()

	var layer := CanvasLayer.new()
	add_child(layer)
	label = Label.new()
	label.position = Vector2(16, 12)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("outline_size", 4)
	layer.add_child(label)

	_parse_args()
	_set_weather(weather)
	_set_quality(quality)

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=")
		var value := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"weather":
				weather = value
			"quality":
				quality = value
			"height":
				cam.position.y = float(value)
			"pitch":
				_pitch = float(value)
			"shot":
				_shot_at = float(value)
			"quit":
				_quit_at = float(value)

func _set_weather(w: String) -> void:
	if not VolumetricClouds.WEATHERS.has(w):
		return
	weather = w
	clouds.apply_weather(w)

func _set_quality(q: String) -> void:
	if not VolumetricClouds.QUALITIES.has(q):
		return
	quality = q
	clouds.apply_quality(q)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = minf(speed * 1.25, 3000.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = maxf(speed / 1.25, 10.0)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.15
		_pitch = clampf(_pitch - event.relative.y * 0.15, -89.0, 89.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		var i := WEATHER_KEYS.find(event.keycode)
		if i >= 0:
			_set_weather(WEATHER_NAMES[i])
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_F1:
				_set_quality("low")
			KEY_F2:
				_set_quality("medium")
			KEY_F3:
				_set_quality("high")
			KEY_H:
				label.visible = not label.visible

func _process(dt: float) -> void:
	_time += dt
	cam.rotation_degrees = Vector3(_pitch, _yaw, 0)
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move.z -= 1
	if Input.is_key_pressed(KEY_S): move.z += 1
	if Input.is_key_pressed(KEY_A): move.x -= 1
	if Input.is_key_pressed(KEY_D): move.x += 1
	if Input.is_key_pressed(KEY_SPACE): move.y += 1
	if Input.is_key_pressed(KEY_CTRL): move.y -= 1
	var fast := 4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	cam.position += cam.global_basis * move.normalized() * speed * fast * dt
	cam.position.y = maxf(cam.position.y, 5.0)

	# the sun: lower / higher, round
	var sr := sun.rotation_degrees
	if Input.is_key_pressed(KEY_Z): sr.x = minf(sr.x + 20.0 * dt, -2.0)
	if Input.is_key_pressed(KEY_X): sr.x = maxf(sr.x - 20.0 * dt, -88.0)
	if Input.is_key_pressed(KEY_C): sr.y += 30.0 * dt
	if Input.is_key_pressed(KEY_V): sr.y -= 30.0 * dt
	sun.rotation_degrees = sr

	# the sea's cloud shadows follow the clouds
	sea_mat.set_shader_parameter("coverage", clouds.coverage)
	sea_mat.set_shader_parameter("cloud_base", clouds.cloud_base)
	sea_mat.set_shader_parameter("cloud_top", clouds.cloud_top)
	sea_mat.set_shader_parameter("wind", clouds.drift())
	var to_sun := sun.global_basis.z.normalized()
	to_sun.y = maxf(to_sun.y, 0.05)
	sea_mat.set_shader_parameter("sun_dir", to_sun.normalized())

	if clouds.effect != null:
		_ms = lerpf(_ms, clouds.effect.march_ms + clouds.effect.composite_ms, 0.05)
	label.text = ("Weather %s (1-6)   Quality %s (F1-F3)   Clouds %.2f ms on the GPU   %d fps\n"
		+ "Height %d m   Speed %d m/s (wheel, Shift)   Sun %d deg (Z/X, C/V)\n"
		+ "Click to look around, WASD to fly, Space/Ctrl up/down, H hides this") % [
		weather, quality, _ms, Engine.get_frames_per_second(), roundi(cam.position.y), roundi(speed), roundi(-sun.rotation_degrees.x)]

	if _shot_at > 0.0 and _time >= _shot_at:
		_shot_at = -1.0
		_screenshot()
	if _quit_at > 0.0 and _time >= _quit_at:
		get_tree().quit()

func _screenshot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	img.save_png(ProjectSettings.globalize_path("res://docs/shot_%s_%d.png" % [weather, roundi(cam.position.y)]))
