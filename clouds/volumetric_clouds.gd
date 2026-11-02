## Volumetric clouds for Godot 4 (Forward+ or Mobile: it needs compute shaders).
##
## Add this node to a scene that has a WorldEnvironment and a DirectionalLight3D, point `world_environment` and
## `sun` at them, and there are clouds. It makes the noise textures, adds a CloudsEffect to the environment's
## compositor, holds the full-screen quad that shows the result, and every frame hands the effect the numbers:
## the look (coverage, layer, density...), the quality (resolution, steps), the sun and the drift of the wind.
## `apply_weather()` and `apply_quality()` switch between the presets below.
class_name VolumetricClouds
extends Node3D

@export var world_environment: WorldEnvironment
@export var sun: DirectionalLight3D

@export_group("Look")
## share of the sky with cloud, 0 clear to 1 overcast
@export_range(0.0, 1.0) var coverage := 0.4
## extinction per metre inside a cloud at full density
@export var density := 0.035
## the cloud layer, metres above y = 0
@export var cloud_base := 900.0
@export var cloud_top := 2600.0
## 0 flat stratus to 1 towering cumulus
@export_range(0.0, 1.0) var cloud_type := 0.8
## how much the edges are worn into wisps and billows
@export_range(0.0, 1.0) var detail := 0.22
## storm clouds take less light in
@export_range(0.0, 1.0) var darkness := 0.0
@export var tint := Color(1, 1, 1)
## metres per second the clouds drift
@export var wind := Vector2(6, 2)
## grey curtains of rain under the thickest cells, 0 none
@export_range(0.0, 1.0) var rain := 0.0
## colours the clouds sit in: the sky above, the ground or sea below, the haze far away
@export var ambient_top := Color(0.55, 0.68, 0.88)
@export var ambient_bottom := Color(0.1, 0.25, 0.35)
@export var haze := Color(0.65, 0.76, 0.86)
## how quickly far clouds fade into the haze
@export var haze_density := 0.00006

@export_group("Quality")
## the march runs at the screen's size divided by this: 2 half, 3 a third, 4 a quarter
@export_range(1, 4) var divisor := 2
## steps along the view ray and towards the light
@export var steps := 72
@export var light_steps := 5
## the march stops once this little light gets through
@export var min_trans := 0.03
## metres; nothing is drawn beyond
@export var max_distance := 40000.0

const WEATHERS := {
	"clear": {"coverage": 0.15, "cloud_type": 0.85, "darkness": 0.0, "density": 0.035, "cloud_base": 900.0, "cloud_top": 2600.0, "rain": 0.0, "tint": Color(1, 1, 1)},
	"fair": {"coverage": 0.4, "cloud_type": 0.85, "darkness": 0.0, "density": 0.035, "cloud_base": 900.0, "cloud_top": 2600.0, "rain": 0.0, "tint": Color(1, 1, 1)},
	"cloudy": {"coverage": 0.6, "cloud_type": 0.6, "darkness": 0.1, "density": 0.035, "cloud_base": 800.0, "cloud_top": 2400.0, "rain": 0.0, "tint": Color(1, 1, 1)},
	"showers": {"coverage": 0.5, "cloud_type": 0.95, "darkness": 0.35, "density": 0.04, "cloud_base": 700.0, "cloud_top": 3000.0, "rain": 0.7, "tint": Color(0.92, 0.93, 0.96)},
	"overcast": {"coverage": 0.92, "cloud_type": 0.25, "darkness": 0.35, "density": 0.035, "cloud_base": 700.0, "cloud_top": 1800.0, "rain": 0.0, "tint": Color(0.95, 0.95, 0.97)},
	"storm": {"coverage": 0.85, "cloud_type": 0.95, "darkness": 0.7, "density": 0.05, "cloud_base": 500.0, "cloud_top": 3200.0, "rain": 1.0, "tint": Color(0.78, 0.8, 0.86)},
}
## from the bench in the article: the cheapest settings that show no stacked slices at each size
const QUALITIES := {
	"low": {"divisor": 4, "steps": 48, "light_steps": 4, "min_trans": 0.05},
	"medium": {"divisor": 3, "steps": 48, "light_steps": 5, "min_trans": 0.05},
	"high": {"divisor": 2, "steps": 72, "light_steps": 5, "min_trans": 0.03},
}

var effect: CloudsEffect
var _quad: MeshInstance3D
var _drift := Vector2.ZERO
var _noise := {}

func _ready() -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("VolumetricClouds: needs the Forward+ or Mobile renderer (compute shaders)")
		return
	_noise = {
		"shape": _noise_3d(64, FastNoiseLite.TYPE_PERLIN, 3.0, 4, false, 11),
		"erosion": _noise_3d(64, FastNoiseLite.TYPE_CELLULAR, 6.0, 3, true, 23),
		"detail": _noise_3d(32, FastNoiseLite.TYPE_CELLULAR, 5.0, 3, true, 37),
		"map": _weather_map(),
	}
	effect = CloudsEffect.new()
	effect.shape_noise = _noise.shape
	effect.erosion_noise = _noise.erosion
	effect.detail_noise = _noise.detail
	effect.weather_map = _noise.map
	if world_environment != null:
		var c := world_environment.compositor if world_environment.compositor != null else Compositor.new()
		var list := c.compositor_effects
		list.append(effect)
		c.compositor_effects = list
		world_environment.compositor = c
	# the quad that lays the finished clouds over the picture, first among the see-through things
	var quad_mesh := QuadMesh.new()
	quad_mesh.size = Vector2(2, 2)
	var show := ShaderMaterial.new()
	show.shader = load("res://clouds/clouds_show.gdshader")
	show.render_priority = -100
	show.set_shader_parameter("clouds", effect.display)
	_quad = MeshInstance3D.new()
	_quad.mesh = quad_mesh
	_quad.material_override = show
	_quad.extra_cull_margin = 16384.0
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.top_level = true
	add_child(_quad)

## The textures, for materials that want to agree with the clouds (cloud shadows on the sea).
func noise_texture(name: String) -> Texture:
	return _noise.get(name)

func drift() -> Vector2:
	return _drift

func apply_weather(name: String) -> void:
	for key in WEATHERS[name]:
		set(key, WEATHERS[name][key])

func apply_quality(name: String) -> void:
	for key in QUALITIES[name]:
		set(key, QUALITIES[name][key])

## A tiling 3D noise: frequency is cells per tile.
static func _noise_3d(size: int, type: int, frequency: float, octaves: int, invert: bool, seed: int) -> NoiseTexture3D:
	var n := FastNoiseLite.new()
	n.noise_type = type
	n.seed = seed
	n.frequency = frequency / float(size)
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	if type == FastNoiseLite.TYPE_CELLULAR:
		n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		n.cellular_jitter = 1.0
	var t := NoiseTexture3D.new()
	t.width = size
	t.height = size
	t.depth = size
	t.seamless = true
	t.invert = invert
	t.normalize = true
	t.noise = n
	return t

## Where the clouds are: soft blobs a few kilometres across, tiling every 36 km.
static func _weather_map() -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = 5
	n.frequency = 6.0 / 256.0
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 4
	var t := NoiseTexture2D.new()
	t.width = 256
	t.height = 256
	t.seamless = true
	t.normalize = true
	t.noise = n
	return t

func _process(dt: float) -> void:
	if effect == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		# just in front of the lens, so nothing culls it
		_quad.global_transform = cam.global_transform.translated_local(Vector3(0, 0, -cam.near * 2.0))
	_drift += wind * dt
	var to_sun := Vector3.UP
	var sun_rgb := Vector3.ONE
	if sun != null:
		to_sun = sun.global_basis.z.normalized()
		to_sun.y = maxf(to_sun.y, 0.05)
		to_sun = to_sun.normalized()
		var c := sun.light_color * sun.light_energy
		sun_rgb = Vector3(c.r, c.g, c.b)
	effect.enabled = coverage > 0.005
	effect.divisor = divisor
	# a fresh dictionary every frame: the render thread reads it whole
	effect.params = {
		"cloud_base": cloud_base, "cloud_top": cloud_top, "coverage": coverage, "density": density,
		"cloud_type": cloud_type, "shape_scale": 5000.0, "detail_scale": 700.0, "map_scale": 36000.0,
		"detail_strength": detail, "darkness": darkness, "light_absorption": 1.0,
		"wind_offset": _drift, "steps": steps, "light_steps": light_steps,
		"sun_dir": to_sun, "sun_color": sun_rgb, "fog_density": haze_density, "max_distance": max_distance,
		"ambient_top": ambient_top.srgb_to_linear(), "ambient_bottom": ambient_bottom.srgb_to_linear(),
		"cloud_tint": tint.srgb_to_linear(), "fog_color": haze.srgb_to_linear(),
		"flash_pos": Vector3.ZERO, "flash_energy": 0.0, "rain": rain,
		"near_distance": 6000.0, "step_growth": 0.01, "min_trans": min_trans,
	}
