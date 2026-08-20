## The FX architecture: a vocabulary of effects, a stack a map composes from
## it, and a controller that owns their whole lifetime.
##
## The load-bearing claims are that the vocabulary is data (adding an effect
## is a shader plus a catalog entry, never a case in a switch), that the stack
## is deterministic (the same effects always composite in the same order,
## whatever order a map lists them in), and that the whole thing stops short
## of the UI.
extends TestCase

const MAIN_SCENE := "res://scenes/main.tscn"

var main: Node = null
var world: World = null


func after_each() -> void:
	FxConfig.clear_cache()
	if main != null:
		main.queue_free()
		main = null
		world = null
	GameState.reset()


func _boot(map_id: String = "") -> World:
	GameState.reset()
	if not map_id.is_empty():
		GameState.current_map = map_id
	main = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await frames(2)
	world = main.world()
	return world


# --------------------------------------------------------------------------
# the catalog
# --------------------------------------------------------------------------

func test_the_effect_catalog_validates() -> void:
	expect_no_errors(FxConfig.validate_catalog(), "data/fx/effects.json")
	ok(FxConfig.effect_names().size() > 0, "the catalog declares no effects")


## Every effect is a shader that exists, in a space the runtime knows, with
## every parameter typed and defaulted. That is what lets a map be validated
## against the catalog rather than against a runtime failure.
func test_every_effect_is_fully_described() -> void:
	for type: String in FxConfig.effect_names():
		ok(ResourceLoader.exists(FxConfig.shader_of(type)),
			"effect '%s' names a shader that is not there" % type)
		ok(["screen", "world"].has(FxConfig.space_of(type)),
			"effect '%s' composites in an unknown space" % type)
		ok(FxConfig.params_of(type).size() > 0,
			"effect '%s' takes no parameters; a fixed effect is a look, not a mechanism" % type)


func test_the_shipped_presets_validate() -> void:
	var presets := FxConfig.all_presets()
	ok(presets.size() > 0, "there are no fx presets in data/fx/")
	for preset_id: String in presets:
		expect_no_errors(FxConfig.validate_preset(preset_id), "data/fx/%s.json" % preset_id)
	ok(not presets.has("effects"), "effects.json is the vocabulary, not a preset")


# --------------------------------------------------------------------------
# resolution
# --------------------------------------------------------------------------

## No "fx" block means no effects: pixel-identical to the world before this
## existed. The same compatibility promise the lighting default makes.
func test_a_map_with_no_fx_block_gets_nothing() -> void:
	equal(FxConfig.resolve({}).size(), 0, "an empty fx block must resolve to an empty stack")
	for map_id: String in MapData.all_ids():
		var map := MapData.load_map(map_id)
		equal(FxConfig.resolve(map.fx).size(), 0,
			"map '%s' grew an effect stack; the shipped maps must look as they did" % map_id)


func test_parameters_fall_back_to_catalog_defaults() -> void:
	var stack := FxConfig.resolve({"effects": [{"type": "vignette"}]})
	equal(stack.size(), 1, "one effect asked for, one resolved")
	var params: Dictionary = stack[0]["params"]
	equal(params["strength"], FxConfig.params_of("vignette")["strength"]["default"],
		"an unstated parameter must come from the catalog")
	equal(params["color"], Color.BLACK, "a colour parameter resolves to a Color")


func test_parameters_are_clamped_to_their_declared_range() -> void:
	var stack := FxConfig.resolve({"effects": [{"type": "quantize", "levels": 9999.0}]})
	equal(stack[0]["params"]["levels"], FxConfig.params_of("quantize")["levels"]["max"],
		"a parameter past its maximum must clamp, not reach the shader")


## The determinism claim: the compositing order is the catalog's, so two maps
## that list the same effects in different orders produce the same frame.
func test_the_stack_composites_in_catalog_order_not_authoring_order() -> void:
	var forwards := FxConfig.resolve({"effects": [
		{"type": "vignette"}, {"type": "fog"}, {"type": "quantize"},
	]})
	var backwards := FxConfig.resolve({"effects": [
		{"type": "quantize"}, {"type": "fog"}, {"type": "vignette"},
	]})
	var names_a: Array = forwards.map(func(e: Dictionary) -> String: return e["type"])
	var names_b: Array = backwards.map(func(e: Dictionary) -> String: return e["type"])
	equal(names_a, names_b, "two orderings of the same effects must composite identically")
	equal(names_a, ["fog", "quantize", "vignette"],
		"and in the catalog's declared order: atmosphere, then grading, then the frame")


func test_a_map_may_retune_or_switch_off_a_preset_entry() -> void:
	var tuned := FxConfig.resolve({
		"preset": "soft_close",
		"effects": [{"type": "vignette", "strength": 0.9}],
	})
	equal(tuned.size(), 1, "the map overrode the preset's entry, not added a second")
	ok(absf(float(tuned[0]["params"]["strength"]) - 0.9) < 0.001,
		"the map's value must win over the preset's")
	ok(absf(float(tuned[0]["params"]["inner"]) - 0.5) < 0.001,
		"and the preset's other values must survive")

	var off := FxConfig.resolve({
		"preset": "soft_close",
		"effects": [{"type": "vignette", "enabled": false}],
	})
	equal(off.size(), 0, "a map must be able to switch an inherited effect off")


func test_malformed_fx_specs_are_reported() -> void:
	var cases := {
		"unknown key": {"effect": "fog"},
		"unknown preset": {"preset": "does_not_exist"},
		"effects not a list": {"effects": {"type": "fog"}},
		"entry with no type": {"effects": [{"density": 0.5}]},
		"unknown effect": {"effects": [{"type": "bloom"}]},
		"unknown parameter": {"effects": [{"type": "fog", "thickness": 3}]},
		"parameter out of range": {"effects": [{"type": "fog", "density": 12.0}]},
		"bad colour": {"effects": [{"type": "fog", "color": "misty"}]},
		"bad vec2": {"effects": [{"type": "fog", "speed": 4}]},
		"non-bool enabled": {"effects": [{"type": "fog", "enabled": "no"}]},
		"same effect twice": {"effects": [{"type": "fog"}, {"type": "fog"}]},
	}
	for label: String in cases:
		var errors := FxConfig.validate_spec(cases[label], "fx")
		ok(errors.size() > 0, "'%s' should be a validation error and was accepted" % label)
	ok(FxConfig.validate_spec({}, "fx").is_empty(), "an empty fx block must be valid")
	ok(FxConfig.validate_spec({"_comment": "hi"}, "fx").is_empty(), "underscore keys are comments")


func test_preset_files_may_not_name_presets() -> void:
	var errors := FxConfig.validate_spec({"preset": "soft_close"}, "test", false)
	ok(errors.size() > 0, "a preset naming another preset is a resolution loop waiting to happen")


func test_a_broken_fx_block_fails_map_validation() -> void:
	var map := MapData.from_dict({
		"legend": {".": "grass"},
		"ground": ["........", "........", "........", "........", "........", "........"],
		"spawns": {"start": [0, 0]},
		"fx": {"effects": [{"type": "bloom"}]},
	})
	ok("\n".join(map.validate()).contains("unknown effect 'bloom'"),
		"an effect the catalog has never heard of must fail the map")


# --------------------------------------------------------------------------
# the controller
# --------------------------------------------------------------------------

func test_the_world_owns_an_fx_controller_separate_from_lighting() -> void:
	await _boot()
	if not ok(world != null, "the main scene never created a World"):
		return
	ok(world.fx is WorldFx, "World has no Fx controller")
	ok(world.fx.screen_layer is CanvasLayer, "the fx controller built no screen layer")
	ok(world.fx.world_root is Node2D, "the fx controller built no world-space root")
	# One-way dependency: lighting must not have grown an fx hook back.
	ok(not world.lighting.has_method("fx_root"),
		"WorldLighting owns lights; fog and grading belong to WorldFx")


func test_effects_are_built_bound_and_swept_away() -> void:
	await _boot()
	if world == null:
		return
	equal(world.fx.effect_count(), 0, "a map with no fx block starts with nothing")

	world.fx.apply_stack(FxConfig.resolve({"effects": [
		{"type": "fog", "density": 0.5}, {"type": "vignette"},
	]}), "test")
	equal(world.fx.effect_count(), 2, "both effects should be live")
	equal(world.fx.active_types(), PackedStringArray(["fog", "vignette"]),
		"and in compositing order")

	var fog := world.fx.effect("fog")
	if ok(fog != null, "the fog effect was not built"):
		var material: ShaderMaterial = fog.material
		ok(material != null and material.shader != null, "an effect must carry its shader")
		ok(absf(float(material.get_shader_parameter("density")) - 0.5) < 0.001,
			"the map's parameter must reach the shader uniform")

	# A map change must take them all with it, exactly as lights are swept.
	world.fx.apply_stack([] as Array[Dictionary], "test")
	equal(world.fx.effect_count(), 0, "changing map must clear the old stack")
	equal(world.fx.effect("fog"), null, "and nothing must survive the sweep")


func test_world_and_screen_effects_composite_where_they_say() -> void:
	await _boot()
	if world == null:
		return
	world.fx.apply_stack(FxConfig.resolve({"effects": [
		{"type": "fog"}, {"type": "vignette"},
	]}), "test")
	var fog := world.fx.effect("fog")
	var vignette := world.fx.effect("vignette")
	if not ok(fog != null and vignette != null, "both effects should be live"):
		return
	equal(fog.get_parent(), world.fx.world_root, "a world-space effect goes in the world")
	equal(vignette.get_parent(), world.fx.screen_layer, "a screen-space effect goes on the screen layer")
	ok(fog.z_index > ScenePlanes.PLANE_Z[ScenePlanes.PLAYABLE],
		"world fog must sit in front of the playable plane")
	ok(fog.z_index < ScenePlanes.PLANE_Z[ScenePlanes.FOREGROUND],
		"and behind the foreground, so a branch is never behind the mist")


## Grading the dialogue box is the failure this prevents. World effects live
## below the UI on the layer stack, and there is nowhere for them to reach it.
func test_world_effects_stay_below_the_ui() -> void:
	await _boot()
	if world == null:
		return
	world.fx.apply_stack(FxConfig.resolve({"effects": [{"type": "color_grade"}]}), "test")
	var layer := world.fx.screen_layer.layer
	equal(layer, Presentation.layer("screen_fx"), "the fx layer comes from the presentation contract")
	ok(layer < Presentation.layer("ui"), "the dialogue box must sit above every world effect")
	ok(layer < Presentation.layer("fade"), "and so must the Router's fade")
	ok(layer > Presentation.layer("world"), "while still covering the world it grades")


## The whole point of applying a map: a preset named in map data becomes real
## nodes, with no code that knows what the preset contains.
func test_map_data_drives_the_stack() -> void:
	await _boot()
	if world == null:
		return
	var map := MapData.from_dict({
		"legend": {".": "grass"},
		"ground": ["........", "........", "........", "........", "........", "........"],
		"spawns": {"start": [0, 0]},
		"fx": {"preset": "pixel_quantize"},
	}, "fx_fixture")
	expect_no_errors(map.validate(), "the fixture map should validate")
	world.fx.apply_map(map)
	equal(world.fx.active_types(), PackedStringArray(["quantize"]),
		"a preset named in map data must become the running stack")
