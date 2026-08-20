## The presentation contract and the depth planes that hang off it.
##
## Two things get pinned here. First, that `data/rendering.json` and
## `project.godot` still agree -- the engine cannot read the contract at boot,
## so the file is the source and the project setting is a copy, and a copy
## nobody checks is a copy that drifts. Second, that the scene really is
## composed of the five planes `scripts/scene_planes.gd` describes, with
## gameplay in exactly one of them.
extends TestCase

const MAIN_SCENE := "res://scenes/main.tscn"

var main: Node = null
var world: World = null


func after_each() -> void:
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


# --------------------------------------------------------------------------
# the presentation contract
# --------------------------------------------------------------------------

## The headline of the migration: one file says how big the frame is, and
## project.godot carries the same numbers.
func test_the_presentation_contract_matches_project_settings() -> void:
	expect_no_errors(Presentation.validate(),
		"data/rendering.json and project.godot disagree")
	equal(Presentation.viewport(), Vector2i(640, 360),
		"the internal viewport is 640x360 -- change data/rendering.json deliberately")


func test_the_viewport_is_sixteen_by_nine() -> void:
	var view := Presentation.viewport()
	ok(view.x * 9 == view.y * 16,
		"the viewport %s is not 16:9; fixed-camera compositions are authored for that frame" % view)


## Pixel-perfect presentation: whole-number scaling, nearest filtering, and a
## window that is an exact multiple of the frame.
func test_presentation_is_pixel_perfect() -> void:
	equal(Presentation.scale_mode(), "integer",
		"fractional scaling makes some pixels wider than others")
	equal(Presentation.stretch_aspect(), "keep",
		"a fixed composition must letterbox rather than reveal more world on a wide screen")
	equal(Presentation.texture_filter(), 0, "nearest-neighbour filtering is the whole look")
	var view := Presentation.viewport()
	var window := Presentation.window()
	equal(window.x % view.x, 0, "the window width is not a whole multiple of the viewport")
	equal(window.y % view.y, 0, "the window height is not a whole multiple of the viewport")


## The layer budget is a total order, and UI sits above every world effect.
## Grading the dialogue box is the specific failure this prevents.
func test_canvas_layers_put_ui_above_every_world_effect() -> void:
	var order: PackedStringArray = [
		"screen_background", "world", "screen_foreground", "screen_fx", "ui", "title", "fade",
	]
	var previous := -1000
	for band: String in order:
		var layer := Presentation.layer(band)
		ok(layer > previous, "layer '%s' (%d) must sit above the band before it (%d)"
			% [band, layer, previous])
		previous = layer
	ok(Presentation.layer("ui") > Presentation.layer("screen_fx"),
		"UI must be above world grading, or the dialogue box gets colour-graded with the forest")


# --------------------------------------------------------------------------
# the depth planes
# --------------------------------------------------------------------------

func test_the_world_builds_every_expected_plane() -> void:
	await _boot()
	if not ok(world != null, "the main scene never created a World"):
		return
	ok(world.planes is ScenePlanes, "World has no ScenePlanes node")
	for plane_name: String in ScenePlanes.PLANES:
		ok(world.planes.plane(plane_name) != null, "plane '%s' was never built" % plane_name)
	ok(world.planes.plane("nowhere") == null, "an unknown plane must resolve to null, not to a guess")


## Gameplay lives in exactly one plane, and that plane is the y-sorted one.
## Everything about depth in this project rests on that.
func test_gameplay_lives_in_the_y_sorted_playable_plane() -> void:
	await _boot()
	if world == null:
		return
	var playable := world.planes.playable()
	if not ok(playable != null, "there is no playable plane"):
		return
	ok(playable.y_sort_enabled, "the playable plane must sort by ground contact")
	ok(world.loader.is_ancestor_of(world.loader.sorted), "MapLoader lost its sorted container")
	ok(playable.is_ancestor_of(world.loader), "MapLoader is not in the playable plane")
	ok(playable.is_ancestor_of(world.player), "the player is not in the playable plane")
	ok(world.loader.sorted.y_sort_enabled, "the sorted container must stay y-sorted")


## Every collision object in the running world is in the playable plane, and
## there are some -- otherwise this asserts nothing about a world that simply
## has no physics in it. A body anywhere else would mean the world model had
## quietly grown a second, invisible definition of "solid".
func test_collision_exists_only_in_the_playable_plane() -> void:
	await _boot()
	if world == null:
		return
	var playable := world.planes.playable()
	var bodies := 0
	for node: Node in _descendants(world):
		if not (node is CollisionObject2D):
			continue
		bodies += 1
		ok(playable.is_ancestor_of(node),
			"%s '%s' collides from outside the playable plane" % [node.get_class(), node.name])
	ok(bodies > 0, "the running world has no collision objects at all; this test proves nothing")


## Ordering between planes is a fact, not a coincidence of tree order.
func test_plane_ordering_is_deterministic() -> void:
	await _boot()
	if world == null:
		return
	var far := world.planes.far_background()
	var playable := world.planes.playable()
	var front := world.planes.foreground()
	ok(far.z_index < playable.z_index,
		"the far background must draw behind the world (%d vs %d)" % [far.z_index, playable.z_index])
	ok(front.z_index > playable.z_index,
		"the foreground must draw in front of the world (%d vs %d)" % [front.z_index, playable.z_index])
	# The screen planes bracket the world on the CanvasLayer stack.
	var behind: CanvasLayer = world.planes.plane(ScenePlanes.SCREEN_BACKGROUND)
	var ahead: CanvasLayer = world.planes.plane(ScenePlanes.SCREEN_FOREGROUND)
	ok(behind.layer < Presentation.layer("world"), "the screen background must be behind the world")
	ok(ahead.layer > Presentation.layer("world"), "the screen foreground must be in front of the world")
	ok(ahead.layer < Presentation.layer("ui"), "no scenery plane may cover the UI")


## Sorting is by ground contact, so a tall thing and a short thing standing on
## the same cell sort the same. This is the property every oversized asset in
## the visual target depends on.
func test_sorting_is_by_ground_contact_not_by_height() -> void:
	await _boot()
	if world == null:
		return
	var map := world.loader.current
	var cell := map.primary_spawn()
	world.player.place_on(cell)
	await frames(1)
	equal(world.player.global_position, map.flat_world_position(cell),
		"an actor's position is the ground they stand on, whatever their sprite does above it")
	# The sprite may be drawn far from the body; the body is what sorts.
	var sprite: ActorSprite = world.player.sprite
	ok(sprite.offset.y <= 0.0,
		"an actor's art is drawn above its feet, never below (offset %s)" % sprite.offset)


func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	var queue: Array[Node] = [node]
	while not queue.is_empty():
		var current: Node = queue.pop_back()
		for child: Node in current.get_children():
			out.append(child)
			queue.append(child)
	return out
