## The lighting architecture holds its contract.
##
## Three layers get pinned here: the data (profiles in data/lighting/ and the
## "lighting" blocks in tiles.json), the bake (occluders and the emission
## atlas that generators wrote from that data), and the runtime (the world's
## Lighting node building and tearing down real lights as maps change).
## docs/architecture/lighting.md is the map of what all of this is.
extends TestCase

const TILESET_PATH := "res://assets/tiles/terrain.tres"
const MAIN_SCENE := "res://scenes/main.tscn"

var main: Node = null
var world: World = null


func after_each() -> void:
	TileRegistry.reload()
	if main != null:
		main.queue_free()
		main = null
		world = null
	GameState.reset()


# --------------------------------------------------------------------------
# profiles
# --------------------------------------------------------------------------

func test_every_lighting_profile_validates() -> void:
	var ids := LightingProfile.all_ids()
	ok(ids.size() > 0, "there are no profiles in data/lighting/")
	for profile_id: String in ids:
		expect_no_errors(LightingProfile.validate_profile(profile_id), "data/lighting/%s.json" % profile_id)


func test_baseline_profiles_exist() -> void:
	# The set the architecture promises; maps rely on these names.
	for profile_id: String in ["default", "outdoor_day", "outdoor_evening", "moonlit", "warm_interior", "dark_interior"]:
		ok(LightingProfile.exists(profile_id), "data/lighting/%s.json is missing" % profile_id)


## The whole backward-compatibility story: no "lighting" key means the world
## renders exactly as it did before the lighting system existed.
func test_default_environment_is_identity() -> void:
	var profile := LightingProfile.defaults()
	equal(profile.ambient(), Color.WHITE, "default ambient must be full-bright white")
	equal(profile.directional_enabled, false, "default environment must have no sun")


func test_profile_resolves_from_file() -> void:
	var profile := LightingProfile.resolve({"profile": "warm_interior"})
	equal(profile.ambient_color.to_html(false), "e6c69e", "warm_interior ambient colour did not load")
	ok(absf(profile.ambient_energy - 0.78) < 0.001, "warm_interior ambient energy did not load")
	equal(profile.directional_enabled, false, "warm_interior must not have a sun")


func test_map_overrides_layer_over_profile() -> void:
	var profile := LightingProfile.resolve({
		"profile": "warm_interior",
		"ambient_energy": 0.5,
		"directional": {"enabled": true, "energy": 0.3},
	})
	equal(profile.ambient_color.to_html(false), "e6c69e", "override lost the profile's ambient colour")
	ok(absf(profile.ambient_energy - 0.5) < 0.001, "ambient_energy override was ignored")
	equal(profile.directional_enabled, true, "directional override was ignored")
	ok(absf(profile.directional_energy - 0.3) < 0.001, "directional energy override was ignored")


func test_unknown_profile_is_reported_and_survivable() -> void:
	var errors := LightingProfile.validate_spec({"profile": "does_not_exist"}, "test")
	ok(errors.size() == 1 and errors[0].contains("does_not_exist"),
		"an unknown profile name must be exactly one validation error, got %s" % [errors])
	# Resolution must not crash or half-apply: it falls back to the identity.
	var profile := LightingProfile.resolve({"profile": "does_not_exist"})
	equal(profile.ambient(), Color.WHITE, "a missing profile must resolve to the identity default")


func test_malformed_lighting_specs_are_reported() -> void:
	var cases := {
		"unknown key": {"ambient_colour": "ffffff"},
		"bad ambient colour": {"ambient_color": "not-a-colour"},
		"non-numeric energy": {"ambient_energy": "bright"},
		"directional not an object": {"directional": "yes"},
		"unknown directional key": {"directional": {"angle": 10}},
		"bad directional colour": {"directional": {"color": "zzz"}},
		"non-bool enabled": {"directional": {"enabled": "yes"}},
	}
	for label: String in cases:
		var errors := LightingProfile.validate_spec(cases[label], "test")
		ok(errors.size() > 0, "'%s' should be a validation error and was accepted" % label)
	ok(LightingProfile.validate_spec({}, "test").is_empty(), "an empty lighting block must be valid")
	ok(LightingProfile.validate_spec({"_comment": "hi"}, "test").is_empty(), "underscore keys are comments")


func test_profile_files_may_not_name_profiles() -> void:
	var errors := LightingProfile.validate_spec({"profile": "default"}, "test", false)
	ok(errors.size() > 0, "a profile file naming another profile must be rejected -- that is a resolution loop")


func test_shipped_maps_carry_valid_lighting() -> void:
	# Both directions of the compatibility promise: maps with lighting blocks
	# validate, and maps without them stay legal. validate() already runs on
	# every map in test_maps.gd; this pins that both cases actually ship.
	var with_lighting := 0
	var without_lighting := 0
	for map_id: String in MapData.all_ids():
		var map := MapData.load_map(map_id)
		if map.lighting.is_empty():
			without_lighting += 1
		else:
			with_lighting += 1
	ok(with_lighting > 0, "no shipped map uses a lighting block; the architecture has no proof")
	ok(without_lighting > 0, "every shipped map has a lighting block; the no-lighting default is untested")


# --------------------------------------------------------------------------
# tile metadata
# --------------------------------------------------------------------------

func test_tiles_json_lighting_metadata_validates() -> void:
	expect_no_errors(TileRegistry.validate_lighting(), "assets/tiles/tiles.json")


func test_emitter_metadata_resolves_with_defaults() -> void:
	var emitters: Array = TileRegistry.emitter_names()
	ok(emitters.size() > 0, "no tile declares a light emitter; the demo is gone")
	for tile_name: String in emitters:
		var spec := TileRegistry.light_emitter(tile_name)
		ok(spec["energy"] > 0.0, "emitter '%s' has no energy" % tile_name)
		ok(spec["radius"] > 0.0, "emitter '%s' has no radius" % tile_name)
		ok(spec["height"] > 0.0,
			"emitter '%s' has zero height; normal-mapped art would receive no light from it" % tile_name)
	ok(TileRegistry.light_emitter("grass").is_empty(), "grass must not emit light")


func test_occluder_metadata_resolves_to_polygons() -> void:
	var occluders: Array = TileRegistry.occluder_names()
	ok(occluders.size() > 0, "no tile declares an occluder")
	for tile_name: String in occluders:
		ok(TileRegistry.occluder_polygon(tile_name).size() >= 3,
			"occluder '%s' resolved to a degenerate polygon" % tile_name)
	ok(TileRegistry.occluder_polygon("grass").is_empty(), "grass must not block light")
	# A plain `true` is the full footprint; a scale shrinks the same diamond.
	equal(TileRegistry.occluder_polygon("wall_stone"), Iso.diamond(),
		"'occluder: true' must be the footprint diamond")
	if TileRegistry.occluder_names().has("tree"):
		equal(TileRegistry.occluder_polygon("tree"), Iso.diamond(0.5),
			"the tree's trunk occluder must be the half-scale diamond")


func test_malformed_tile_lighting_is_reported() -> void:
	# Inject a broken registry, validate, and restore. reload() in after_each
	# re-reads the real file either way.
	var cases := {
		"unknown lighting key": {"lighting": {"emits": true}},
		"emit not an object": {"lighting": {"emit": true}},
		"bad emit colour": {"lighting": {"emit": {"color": "warm"}}},
		"negative radius": {"lighting": {"emit": {"radius": -4}}},
		"bad offset": {"lighting": {"emit": {"offset": [1, 2, 3]}}},
		"unknown occluder shape": {"lighting": {"occluder": {"shape": "cube"}}},
		"occluder scale beyond footprint": {"lighting": {"occluder": {"scale": 1.5}}},
		"occluder shape and points together": {"lighting": {"occluder": {"shape": "diamond", "points": [[0, 0], [1, 0], [0, 1]]}}},
		"too few occluder points": {"lighting": {"occluder": {"points": [[0, 0], [1, 1]]}}},
		"non-bool emission": {"lighting": {"emission": "yes"}},
	}
	for label: String in cases:
		TileRegistry._cache = {"tiles": {"broken": cases[label]}}
		var errors := TileRegistry.validate_lighting()
		ok(errors.size() > 0, "'%s' should fail tile validation and was accepted" % label)
	TileRegistry.reload()


# --------------------------------------------------------------------------
# the bake: occluders in terrain.tres, pixels in terrain_emission.png
# --------------------------------------------------------------------------

func test_baked_occluders_match_tiles_json() -> void:
	var tile_set: TileSet = load(TILESET_PATH)
	if not ok(tile_set != null, "could not load %s" % TILESET_PATH):
		return
	ok(tile_set.get_occlusion_layers_count() >= 1,
		"the baked tileset has no occlusion layer -- re-run tools/build_tileset.gd")
	var source: TileSetAtlasSource = tile_set.get_source(0)
	for tile_name: String in TileRegistry.names():
		var data: TileData = source.get_tile_data(TileRegistry.atlas_coords(tile_name), 0)
		if data == null:
			continue
		var declared := TileRegistry.occluder_polygon(tile_name)
		var baked_count := data.get_occluder_polygons_count(0)
		if declared.is_empty():
			equal(baked_count, 0, "tile '%s' has a baked occluder tiles.json does not declare" % tile_name)
			continue
		if not equal(baked_count, 1,
				"tile '%s' declares an occluder but the bake has %d -- re-run tools/build_tileset.gd" % [tile_name, baked_count]):
			continue
		var polygon: OccluderPolygon2D = data.get_occluder_polygon(0, 0)
		equal(polygon.polygon, declared,
			"tile '%s' baked occluder differs from its metadata -- re-run tools/build_tileset.gd" % tile_name)


func test_emission_atlas_matches_flags_and_layout() -> void:
	var terrain_path := ProjectSettings.globalize_path("res://assets/tiles/terrain.png")
	var emission_path := ProjectSettings.globalize_path("res://assets/tiles/terrain_emission.png")
	var terrain := Image.load_from_file(terrain_path)
	var emission := Image.load_from_file(emission_path)
	if not ok(terrain != null and emission != null, "could not read the terrain or emission atlas"):
		return
	# Same UV space or the shader smears glow across the wrong tiles.
	ok(emission.get_size() == terrain.get_size(),
		"terrain_emission.png is %s but terrain.png is %s -- re-run tools/gen_art.py"
			% [emission.get_size(), terrain.get_size()])

	var cell := TileRegistry.cell_size()
	for tile_name: String in TileRegistry.names():
		var coords := TileRegistry.atlas_coords(tile_name)
		var lit := 0
		for y: int in cell.y:
			for x: int in cell.x:
				if emission.get_pixel(coords.x * cell.x + x, coords.y * cell.y + y).a > 0.0:
					lit += 1
		if TileRegistry.is_emissive(tile_name):
			ok(lit > 0, "tile '%s' is flagged emissive but its emission cell is empty -- re-run tools/gen_art.py" % tile_name)
		else:
			equal(lit, 0, "tile '%s' has emission pixels but no emission flag in tiles.json" % tile_name)


# --------------------------------------------------------------------------
# runtime: the Lighting node
# --------------------------------------------------------------------------

func _boot(map_id: String = "", spawn_id: String = "start") -> World:
	GameState.reset()
	if not map_id.is_empty():
		GameState.current_map = map_id
		GameState.current_spawn = spawn_id
	main = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await frames(2)
	world = main.world()
	if world != null:
		# Exact-value assertions need the glide between environments off.
		world.lighting.transition_seconds = 0.0
	return world


## Cells on any layer whose tile metadata declares an emitter -- what the
## Lighting node is contractually obliged to turn into PointLight2Ds.
func _expected_emitters(map: MapData) -> int:
	var count := 0
	for layer_name: String in MapData.LAYERS:
		for y: int in map.height:
			for x: int in map.width:
				if not TileRegistry.light_emitter(map.tile_at(layer_name, Vector2i(x, y))).is_empty():
					count += 1
	return count


func test_world_has_a_lighting_node() -> void:
	await _boot()
	if not ok(world != null, "the main scene never created a World"):
		return
	ok(world.lighting is WorldLighting, "World has no Lighting node")
	ok(world.lighting.ambient_node is CanvasModulate, "Lighting built no CanvasModulate")
	ok(world.lighting.sun is DirectionalLight2D, "Lighting built no DirectionalLight2D")
	ok(world.lighting.fx_root() != null, "Lighting has no fx hook")


func test_tile_metadata_becomes_point_lights() -> void:
	await _boot("port_azure_inn_ground")
	if world == null:
		return
	world.enter("port_azure_inn_ground")
	await frames(2)
	var expected := _expected_emitters(world.loader.current)
	ok(expected > 0, "the inn should have at least one emitting tile (the fireplace)")
	equal(world.lighting.dynamic_light_count(), expected,
		"emitting cells and spawned lights disagree on the inn")

	# The light carries its tile's metadata, not anybody's hardcoded numbers.
	var fireplace_spec := TileRegistry.light_emitter("fireplace")
	var light: PointLight2D = world.lighting.dynamic_lights.get_child(0)
	equal(light.color, fireplace_spec["color"], "fireplace light colour is not its metadata colour")
	equal(light.shadow_enabled, fireplace_spec["shadows"], "fireplace light ignores its shadows flag")
	ok(light.texture != null, "spawned light has no falloff texture")


func test_lights_are_replaced_when_maps_change() -> void:
	await _boot("port_azure_inn_ground")
	if world == null:
		return
	world.enter("port_azure_town")
	await frames(2)
	var town_expected := _expected_emitters(world.loader.current)
	ok(town_expected > 0, "the town should have emitting lamps")
	equal(world.lighting.dynamic_light_count(), town_expected,
		"switching maps must clear the old map's lights and spawn the new map's")

	world.enter("port_azure_inn_upper")
	await frames(2)
	equal(world.lighting.dynamic_light_count(), _expected_emitters(world.loader.current),
		"a map with no emitters must end up with no dynamic lights")


func test_map_profiles_reach_the_canvas() -> void:
	await _boot()
	if world == null:
		return
	world.enter("port_azure_town")
	await frames(1)
	var day := LightingProfile.resolve(MapData.load_map("port_azure_town").lighting)
	equal(world.lighting.ambient_node.color, day.ambient(), "the town's ambient never reached the CanvasModulate")
	equal(world.lighting.sun.visible, day.directional_enabled, "the town's sun flag never reached the DirectionalLight2D")

	world.enter("port_azure_inn_ground")
	await frames(1)
	var inn := LightingProfile.resolve(MapData.load_map("port_azure_inn_ground").lighting)
	equal(world.lighting.ambient_node.color, inn.ambient(), "the inn's overridden ambient never reached the CanvasModulate")
	equal(world.lighting.sun.visible, false, "the inn has a sun indoors")

	# And the compatibility case: a map with no lighting block gets identity.
	world.enter("port_azure_inn_upper")
	await frames(1)
	equal(world.lighting.ambient_node.color, Color.WHITE,
		"a map with no lighting block must render full-bright, exactly as before the system existed")


func test_tile_layers_carry_the_emission_material() -> void:
	await _boot()
	if world == null:
		return
	var material: ShaderMaterial = world.loader.object_layer.material
	if not ok(material != null, "the object layer has no emission material despite terrain_emission.png existing"):
		return
	ok(material.shader != null, "the emission material has no shader")
	ok(material.get_shader_parameter("emission_atlas") != null, "the emission material has no atlas bound")
	equal(world.loader.ground_layer.material, material, "both tile layers must share one emission material")


## The pixel-art contract this whole feature must not break.
func test_web_and_pixel_configuration_is_preserved() -> void:
	equal(String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")), "gl_compatibility",
		"the renderer changed; web export and low-end targets depend on gl_compatibility")
	equal(int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)), 320, "internal viewport width changed")
	equal(int(ProjectSettings.get_setting("display/window/size/viewport_height", 0)), 192, "internal viewport height changed")
	equal(String(ProjectSettings.get_setting("display/window/stretch/mode", "")), "canvas_items", "stretch mode changed")
	equal(int(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter", -1)), 0,
		"nearest-neighbour filtering changed; pixel art would smear")
