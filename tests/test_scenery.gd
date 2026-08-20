## Scenery: the picture around the world, and its separation from the world.
##
## The claim this suite exists to protect is the one everything about the
## visual target rests on: **a sprite may be enormous and still occupy one
## cell.** A 400px redwood is placed by its anchor, sorts by its anchor,
## occludes light on its trunk, and blocks movement only because the map put
## a solid tile under it. Four footprints, four owners, no confusion.
##
## There is no production scenery yet, so most of this drives registries built
## in memory -- props this game does not have, to prove it could place them.
extends TestCase

const MAIN_SCENE := "res://scenes/main.tscn"

var main: Node = null
var world: World = null


func after_each() -> void:
	SceneryRegistry.clear_cache()
	if main != null:
		main.queue_free()
		main = null
		world = null
	GameState.reset()


func _boot() -> World:
	GameState.reset()
	main = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await frames(2)
	world = main.world()
	return world


## A registry with the two shapes the target needs: something enormous with a
## one-cell footprint, and something purely decorative with none at all.
## `texture` points at a shipped image so path validation is exercised for
## real; the pixels are irrelevant to every assertion here.
func _registry() -> SceneryRegistry:
	return SceneryRegistry.from_dict({
		"props": {
			"tall_thing": {
				"texture": "res://assets/tiles/terrain.png",
				"anchor": [180, 396],
				"plane": "playable",
				"footprint": [[0, 0]],
				"requires_solid": true,
				"occluder": {"shape": "diamond", "scale": 0.4},
			},
			"backdrop": {
				"texture": "res://assets/tiles/terrain.png",
				"anchor": [0, 0],
				"plane": "far_background",
			},
			"overhead": {
				"texture": "res://assets/tiles/terrain.png",
				"anchor": [32, 0],
				"plane": "foreground",
			},
			"frame_edge": {
				"texture": "res://assets/tiles/terrain.png",
				"anchor": [0, 0],
				"plane": "screen_foreground",
			},
		},
	})


## A map with one solid cell, so a prop that claims to block the way has
## something to claim.
func _map(placements: Array) -> MapData:
	return MapData.from_dict({
		"legend": {".": "grass", "#": "wall_stone"},
		"ground": [
			"........",
			"...#....",
			"........",
			"........",
			"........",
			"........",
		],
		"spawns": {"start": [0, 0]},
		"scenery": placements,
	}, "scenery_fixture")


# --------------------------------------------------------------------------
# the registry
# --------------------------------------------------------------------------

func test_the_shipped_registry_validates() -> void:
	expect_no_errors(SceneryRegistry.load_default().validate(), "assets/scenery/scenery.json")


## The migration ships the contract, not the forest. If props appear here
## before the art does, somebody skipped a step.
func test_no_production_scenery_ships_yet() -> void:
	equal(SceneryRegistry.load_default().names().size(), 0,
		"assets/scenery/scenery.json has props but this is a pre-production migration")
	for map_id: String in MapData.all_ids():
		equal(MapData.load_map(map_id).scenery.size(), 0,
			"map '%s' places scenery; the shipped maps must be unchanged" % map_id)


func test_a_prop_may_be_enormous_and_still_occupy_one_cell() -> void:
	var registry := _registry()
	expect_no_errors(registry.validate(), "the fixture registry")
	equal(registry.footprint("tall_thing").size(), 1,
		"a giant sprite occupies one logical cell, not dozens")
	equal(registry.anchor("tall_thing"), Vector2(180, 396),
		"and is placed by the pixel that touches the ground, wherever that is in the image")
	# Occlusion is a third footprint again: smaller than the cell, unrelated
	# to the picture.
	equal(registry.occluder_polygon("tall_thing"), Iso.diamond(0.4),
		"light occlusion is the trunk, not the canopy and not the cell")
	equal(registry.footprint("backdrop").size(), 0,
		"a backdrop occupies nothing at all")


func test_malformed_props_are_reported() -> void:
	var cases := {
		"no texture": {"anchor": [0, 0]},
		"no anchor": {"texture": "res://assets/tiles/terrain.png"},
		"bad anchor": {"texture": "res://assets/tiles/terrain.png", "anchor": [1, 2, 3]},
		"missing texture file": {"texture": "res://nope.png", "anchor": [0, 0]},
		"unknown plane": {"texture": "res://assets/tiles/terrain.png", "anchor": [0, 0], "plane": "sky"},
		"unknown key": {"texture": "res://assets/tiles/terrain.png", "anchor": [0, 0], "shadow": true},
		"requires_solid with no footprint": {
			"texture": "res://assets/tiles/terrain.png", "anchor": [0, 0], "requires_solid": true},
		"bad footprint": {
			"texture": "res://assets/tiles/terrain.png", "anchor": [0, 0], "footprint": [[1]]},
		"animated with no frame size": {
			"texture": "res://assets/tiles/terrain.png", "anchor": [0, 0],
			"frames": {"count": 4, "fps": 6}},
		"frames with no fps": {
			"texture": "res://assets/tiles/terrain.png", "anchor": [0, 0],
			"frame_size": [16, 16], "frames": {"count": 4}},
	}
	for label: String in cases:
		var errors := SceneryRegistry.from_dict({"props": {"broken": cases[label]}}).validate()
		ok(errors.size() > 0, "'%s' should be a validation error and was accepted" % label)


# --------------------------------------------------------------------------
# placements
# --------------------------------------------------------------------------

func test_valid_placements_are_accepted() -> void:
	var registry := _registry()
	var map := _map([])
	var good: Array = [
		{"prop": "tall_thing", "at": [3, 1]},
		{"prop": "backdrop", "at": [0, 0], "plane": "far_background", "parallax": 0.4},
		{"prop": "overhead", "at": [2, 2], "plane": "foreground", "sort": 3, "flip_h": true},
		{"prop": "backdrop", "space": "camera", "plane": "far_background", "offset": [0, -40]},
		{"prop": "frame_edge", "space": "screen", "plane": "screen_foreground", "screen": [0.5, 1.0]},
	]
	expect_no_errors(registry.validate_placements(good, "scenery", map),
		"these placements should all be legal")


## The separation, enforced: a prop that claims to block the way must have a
## solid tile under it. Scenery cannot make the world solid, so it has to
## agree with the world that already is.
func test_a_prop_that_blocks_the_way_must_stand_on_a_solid_tile() -> void:
	var registry := _registry()
	var map := _map([])
	expect_no_errors(registry.validate_placements([{"prop": "tall_thing", "at": [3, 1]}], "scenery", map),
		"the solid cell is where the fixture map put its wall")
	var errors := registry.validate_placements([{"prop": "tall_thing", "at": [5, 4]}], "scenery", map)
	ok("\n".join(errors).contains("walkable"),
		"a prop claiming a walkable cell must be reported, got %s" % [errors])


func test_malformed_placements_are_reported() -> void:
	var registry := _registry()
	var map := _map([])
	var cases := {
		"no prop": [{"at": [0, 0]}],
		"unknown prop": [{"prop": "redwood", "at": [0, 0]}],
		"unknown key": [{"prop": "backdrop", "at": [0, 0], "rotation": 4}],
		"world prop with no cell": [{"prop": "backdrop"}],
		"cell off the map": [{"prop": "backdrop", "at": [99, 99]}],
		"unknown space": [{"prop": "backdrop", "at": [0, 0], "space": "orbit"}],
		"unknown plane": [{"prop": "backdrop", "at": [0, 0], "plane": "sky"}],
		"screen space in a world plane": [
			{"prop": "backdrop", "space": "screen", "plane": "far_background"}],
		"world space in a screen plane": [
			{"prop": "backdrop", "at": [0, 0], "plane": "screen_background"}],
		"screen space with a cell": [
			{"prop": "frame_edge", "space": "screen", "plane": "screen_foreground", "at": [0, 0]}],
		"parallax out of range": [{"prop": "backdrop", "at": [0, 0], "parallax": 99.0}],
		"parallax on screen space": [
			{"prop": "frame_edge", "space": "screen", "plane": "screen_foreground", "parallax": 0.5}],
		"bad modulate": [{"prop": "backdrop", "at": [0, 0], "modulate": "greenish"}],
		"non-bool flip": [{"prop": "backdrop", "at": [0, 0], "flip_h": "yes"}],
	}
	for label: String in cases:
		var errors := registry.validate_placements(cases[label], "scenery", map)
		ok(errors.size() > 0, "'%s' should be a validation error and was accepted" % label)


## A map's scenery block runs through the same validate() every other part of
## a map does, so a broken placement fails CI rather than a frame.
func test_a_broken_placement_fails_map_validation() -> void:
	var map := _map([{"prop": "redwood", "at": [1, 1]}])
	ok("\n".join(map.validate()).contains("not in res://assets/scenery/scenery.json"),
		"a map placing a prop the registry has never heard of must fail validation")


# --------------------------------------------------------------------------
# the runtime
# --------------------------------------------------------------------------

## The anchor is the whole placement rule: the node's position is the ground
## the prop stands on, and the image is offset around it. That is what makes a
## huge prop sort like a small one.
func test_a_prop_is_positioned_and_sorted_by_its_anchor() -> void:
	await _boot()
	if not ok(world != null, "the main scene never created a World"):
		return
	var registry := _registry()
	var image := Image.create(240, 400, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 0, 1, 1))
	var texture := ImageTexture.create_from_image(image)

	var prop := SceneryProp.new()
	prop.configure(registry, "tall_thing", {"prop": "tall_thing", "at": [3, 1]}, texture)
	world.planes.foreground().add_child(prop)
	await frames(1)

	# A 240x400 image anchored at (180, 396) -- far from its centre.
	equal(prop.offset, Vector2(240 * 0.5 - 180, 400 * 0.5 - 396),
		"the image must be offset so its anchor lands on the node's position")
	ok(prop.offset.y < 0.0, "a tall prop draws above its feet, never below them")
	# Its own light occlusion came along; its collision did not.
	var occluders := prop.get_children().filter(func(n: Node) -> bool: return n is LightOccluder2D)
	equal(occluders.size(), 1, "the prop's occluder polygon should be a child of it")
	for child: Node in prop.get_children():
		ok(not (child is CollisionObject2D), "a scenery prop must never carry collision")
	prop.queue_free()


func test_placements_land_in_the_plane_they_name() -> void:
	await _boot()
	if world == null:
		return
	world.planes.use_registry(_registry())
	world.planes.apply_map(_map([
		{"prop": "backdrop", "at": [1, 1], "plane": "far_background", "parallax": 0.5},
		{"prop": "overhead", "at": [2, 2], "plane": "foreground"},
		{"prop": "frame_edge", "space": "screen", "plane": "screen_foreground", "screen": [0.5, 1.0]},
	]))
	await frames(1)
	equal(world.planes.scenery().size(), 3, "all three placements should be live")
	equal(world.planes.far_background().get_child_count(), 1, "one prop in the far background")
	equal(world.planes.foreground().get_child_count(), 1, "one prop in the foreground")
	equal(world.planes.plane(ScenePlanes.SCREEN_FOREGROUND).get_child_count(), 1,
		"one prop on the screen foreground layer")

	# A map change sweeps them, exactly as it sweeps lights and effects.
	world.planes.apply_map(_map([]))
	await frames(1)
	equal(world.planes.scenery().size(), 0, "changing map must clear the old scenery")


## Scenery must never be able to grow into gameplay. The plane containers are
## the boundary, and this is the assertion that keeps them one -- walked as
## plain Nodes, because the day somebody makes SceneryProp a body is exactly
## the day a typed check would stop compiling instead of failing.
func test_scenery_never_becomes_collision() -> void:
	await _boot()
	if world == null:
		return
	world.planes.use_registry(_registry())
	world.planes.apply_map(_map([
		{"prop": "tall_thing", "at": [3, 1]},
		{"prop": "backdrop", "at": [1, 1], "plane": "far_background"},
	]))
	await frames(1)
	ok(world.planes.scenery().size() == 2, "both props should be live")
	for plane_name: String in ScenePlanes.PLANES:
		if plane_name == ScenePlanes.PLAYABLE:
			continue
		var container: Node = world.planes.plane(plane_name)
		var queue: Array[Node] = [container]
		while not queue.is_empty():
			var node: Node = queue.pop_back()
			ok(not node.is_class("CollisionObject2D"),
				"plane '%s' contains a %s -- scenery is presentation only"
					% [plane_name, node.get_class()])
			queue.append_array(node.get_children())

	# The map's own solid tile is what stops the player -- unchanged by any of
	# this, which is the entire point of keeping them apart.
	var fixture := _map([])
	ok(fixture.is_solid(Vector2i(3, 1)), "the map, not the prop, is what makes that cell solid")
	ok(not fixture.is_solid(Vector2i(5, 4)), "and the cells around it stay walkable")
