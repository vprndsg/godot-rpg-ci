## Owns everything about how a map is lit: the ambient tone, the sun, and the
## point lights that tile metadata asks for.
##
## Nothing in here is authored in the editor and nothing in here knows a tile
## by name. Maps choose an environment with a "lighting" block (resolved by
## scripts/lighting_profile.gd); tiles declare "emit" metadata in
## assets/tiles/tiles.json (read by TileRegistry); this node turns both into
## live nodes when World.enter() hands it the freshly loaded MapData:
##
##     Lighting
##     ├── Ambient        CanvasModulate -- the profile's ambient colour
##     ├── Sun            DirectionalLight2D -- the profile's directional light
##     └── DynamicLights  one PointLight2D per emitting cell, rebuilt per map
##
## Fog, colour grading and the pixel-quantization pass used to be a reserved
## `Fx` child here. They are not lighting -- they are what happens to the
## frame after lighting -- and they now have their own owner in
## scripts/world_fx.gd. The dependency runs one way: neither node knows the
## other exists. docs/architecture/fx.md explains the split.
##
## Occlusion never passes through here at runtime: occluder polygons are baked
## into terrain.tres from the same tile metadata by tools/build_tileset.gd,
## and the TileMapLayers apply them on their own.
class_name WorldLighting
extends Node2D

## The generated default falloff texture (tools/gen_art.py::build_lights).
const POINT_LIGHT_TEXTURE := "res://assets/lights/point_light.png"

## How many dynamic lights a map may spawn before this is a design problem
## worth saying out loud. Not a wall -- the compatibility renderer and small
## GPUs stop being happy long before lights stop being legal.
const LIGHT_BUDGET := 32

## How long a map-to-map lighting change takes. The Router's fade covers it,
## so this is felt, not watched. Tests set it to 0 for exact assertions.
var transition_seconds := 0.25

var ambient_node: CanvasModulate
var sun: DirectionalLight2D
var dynamic_lights: Node2D

var _tween: Tween = null
var _point_texture: Texture2D = null


func _ready() -> void:
	_ensure_children()


## Apply a map's whole lighting story: resolve its profile, transition the
## ambient and directional state, and rebuild the tile-driven point lights.
func apply_map(map: MapData) -> void:
	apply_profile(LightingProfile.resolve(map.lighting), transition_seconds)
	clear_dynamic_lights()
	_spawn_tile_lights(map)


## Move the environment to a profile. Ambient and sun colours glide over
## `duration` seconds; geometry (angle, height, shadows) switches instantly.
func apply_profile(profile: LightingProfile, duration := 0.0) -> void:
	_ensure_children()
	if _tween != null:
		_tween.kill()
		_tween = null

	sun.rotation_degrees = profile.directional_angle_degrees
	sun.height = profile.directional_height
	sun.shadow_enabled = profile.directional_shadows
	sun.visible = profile.directional_enabled

	if duration > 0.0 and is_inside_tree():
		_tween = create_tween().set_parallel(true)
		_tween.tween_property(ambient_node, "color", profile.ambient(), duration)
		_tween.tween_property(sun, "color", profile.directional_color, duration)
		_tween.tween_property(sun, "energy", profile.directional_energy, duration)
	else:
		ambient_node.color = profile.ambient()
		sun.color = profile.directional_color
		sun.energy = profile.directional_energy


## One PointLight2D from an emitter spec (TileRegistry.light_emitter shape),
## parented under DynamicLights so the next map change sweeps it away. Also
## the door for future scripted lights -- a spell, a cutscene lantern -- so
## one-off effects go through the same cleanup as tile lights.
func add_point_light(spec: Dictionary, pos: Vector2) -> PointLight2D:
	_ensure_children()
	var light := PointLight2D.new()
	var texture := _texture()
	light.texture = texture
	light.position = pos + Vector2(spec.get("offset", Vector2.ZERO))
	light.color = Color(spec.get("color", Color.WHITE))
	light.energy = float(spec.get("energy", 1.0))
	# The generated texture reaches half its own width, so scale is radius
	# over that half-width -- radius is authored in screen pixels.
	if texture != null:
		light.texture_scale = float(spec.get("radius", TileRegistry.default_radius())) / (float(texture.get_width()) * 0.5)
	light.height = float(spec.get("height", TileRegistry.default_height()))
	light.shadow_enabled = bool(spec.get("shadows", false))
	# Hard-edged shadows: cheapest, and soft penumbras read as vector art here.
	light.shadow_filter = Light2D.SHADOW_FILTER_NONE
	light.blend_mode = Light2D.BLEND_MODE_ADD
	dynamic_lights.add_child(light)
	return light


func clear_dynamic_lights() -> void:
	_ensure_children()
	for child: Node in dynamic_lights.get_children():
		dynamic_lights.remove_child(child)
		child.free()


func dynamic_light_count() -> int:
	_ensure_children()
	return dynamic_lights.get_child_count()


## Every cell whose tile metadata says "emit" becomes a light. Both layers
## are scanned: a glowing floor is as legal as a glowing prop.
func _spawn_tile_lights(map: MapData) -> void:
	for layer_name: String in MapData.LAYERS:
		for y: int in map.height:
			for x: int in map.width:
				var cell := Vector2i(x, y)
				var tile_name := map.tile_at(layer_name, cell)
				if tile_name.is_empty():
					continue
				var spec := TileRegistry.light_emitter(tile_name)
				if spec.is_empty():
					continue
				var light := add_point_light(spec, map.world_position(cell))
				light.name = "%s_%d_%d" % [tile_name, x, y]
	if dynamic_lights.get_child_count() > LIGHT_BUDGET:
		push_warning("Map '%s' spawned %d point lights; consider fewer, brighter sources."
			% [map.id, dynamic_lights.get_child_count()])


func _texture() -> Texture2D:
	if _point_texture == null:
		if not ResourceLoader.exists(POINT_LIGHT_TEXTURE):
			push_warning("Missing %s -- run tools/ci.sh generate; lights will be invisible." % POINT_LIGHT_TEXTURE)
			return null
		_point_texture = load(POINT_LIGHT_TEXTURE)
	return _point_texture


## Children are built in code so no .tscn carries lighting state, and built
## lazily so tests can drive this node before it enters a tree.
func _ensure_children() -> void:
	if ambient_node != null:
		return
	ambient_node = CanvasModulate.new()
	ambient_node.name = "Ambient"
	ambient_node.color = LightingProfile.defaults().ambient()
	add_child(ambient_node)

	sun = DirectionalLight2D.new()
	sun.name = "Sun"
	sun.visible = false
	sun.energy = 0.0
	sun.blend_mode = Light2D.BLEND_MODE_ADD
	add_child(sun)

	dynamic_lights = Node2D.new()
	dynamic_lights.name = "DynamicLights"
	add_child(dynamic_lights)
