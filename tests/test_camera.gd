## Camera modes: what a map may ask for, and what the camera does about it.
##
## FOLLOW is the one that has to be exactly what it always was -- every
## shipped map relies on it and none of them says so, which is the whole
## backward-compatibility claim. The other three are new, and each is
## exercised on a map built in memory rather than a demo map added to the game.
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


func _boot(map_id: String = "") -> World:
	GameState.reset()
	if not map_id.is_empty():
		GameState.current_map = map_id
	main = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await frames(2)
	world = main.world()
	return world


## A map big enough that a room can be smaller than it, built in memory --
## the camera schema does not need a demo map in the game to be tested.
func _wide_map(camera_spec: Dictionary) -> MapData:
	var rows: Array = []
	for y: int in 24:
		rows.append(".".repeat(24))
	return MapData.from_dict({
		"legend": {".": "grass"},
		"ground": rows,
		"spawns": {"start": [2, 2]},
		"camera": camera_spec,
	}, "camera_fixture")


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

func test_a_map_with_no_camera_block_is_follow() -> void:
	equal(CameraConfig.mode_of({}), "follow", "the default mode is follow")
	expect_no_errors(CameraConfig.validate_spec({}, "camera", Vector2i(10, 10)),
		"an absent camera block must be legal")
	for map_id: String in MapData.all_ids():
		var map := MapData.load_map(map_id)
		ok(map.camera.is_empty(),
			"map '%s' grew a camera block; the shipped maps must keep the pre-migration framing" % map_id)


func test_camera_configuration_validates() -> void:
	var size := Vector2i(20, 20)
	var good := {
		"follow": {"mode": "follow"},
		"room locked": {"mode": "room_locked", "room": [2, 2, 10, 8]},
		"fixed at a cell": {"mode": "fixed", "at": [5, 5]},
		"fixed at a pixel": {"mode": "fixed", "position": [100.0, 40.0], "zoom": 1.0},
		"framing nudged": {"mode": "fixed", "at": [5, 5], "offset": [0, -12], "smoothing": false},
	}
	for label: String in good:
		expect_no_errors(CameraConfig.validate_spec(good[label], "camera", size),
			"'%s' should be a legal camera block" % label)

	var bad := {
		"unknown mode": {"mode": "orbit"},
		"cinematic is not authorable": {"mode": "cinematic"},
		"room_locked with no room": {"mode": "room_locked"},
		"fixed with no anchor": {"mode": "fixed"},
		"room off the map": {"mode": "room_locked", "room": [15, 15, 10, 10]},
		"room with no area": {"mode": "room_locked", "room": [2, 2, 0, 5]},
		"anchor off the map": {"mode": "fixed", "at": [99, 99]},
		"both anchors": {"mode": "fixed", "at": [1, 1], "position": [10, 10]},
		"zero zoom": {"mode": "follow", "zoom": 0.0},
		"unknown key": {"mode": "follow", "lens": 35},
		"non-bool smoothing": {"mode": "follow", "smoothing": "yes"},
	}
	for label: String in bad:
		var errors := CameraConfig.validate_spec(bad[label], "camera", size)
		ok(errors.size() > 0, "'%s' should be a validation error and was accepted" % label)


## The mistake worth naming: cinematic is a borrow, not a framing, and a map
## asking for it should be told why rather than getting a generic refusal.
func test_asking_a_map_for_cinematic_says_why() -> void:
	var errors := CameraConfig.validate_spec({"mode": "cinematic"}, "camera", Vector2i(8, 8))
	ok("\n".join(errors).contains("borrows"),
		"a map asking for cinematic should be told it is a runtime state, got %s" % [errors])


func test_a_broken_camera_block_fails_map_validation() -> void:
	var map := MapData.from_dict({
		"legend": {".": "grass"},
		"ground": ["........", "........", "........", "........", "........", "........"],
		"spawns": {"start": [0, 0]},
		"camera": {"mode": "fixed"},
	})
	ok("\n".join(map.validate()).contains("needs an 'at' cell"),
		"a fixed camera with nowhere to sit must fail the map, not the frame")


# --------------------------------------------------------------------------
# behaviour
# --------------------------------------------------------------------------

func test_follow_is_exactly_what_it_always_was() -> void:
	await _boot()
	if not ok(world != null, "the main scene never created a World"):
		return
	var camera := world.camera
	equal(camera.mode, GameCamera.Mode.FOLLOW, "a map with no camera block follows")
	ok(not camera.top_level, "a following camera rides the player's transform")

	var map := world.loader.current
	var bounds := Iso.grid_bounds(Vector2i(map.width, map.height))
	equal(camera.limit_left, int(bounds.position.x), "left limit is the map's own left edge")
	equal(camera.limit_right, int(bounds.end.x), "right limit is the map's own right edge")
	equal(camera.limit_bottom, int(bounds.end.y), "the bottom limit is where the ground ends")
	# The top gets the headroom a tall tile on the back row draws into, plus a
	# level's worth for every level the terrain can rise.
	equal(camera.limit_top,
		int(bounds.position.y) - TileRegistry.footprint_top()
			- int(map.max_elevation() * Iso.elevation_height()),
		"the top limit must leave the back row its headroom")


func test_room_locked_constrains_the_composition() -> void:
	await _boot()
	if world == null:
		return
	var camera := world.camera
	var room := Rect2i(2, 2, 16, 14)
	camera.fit_to_map(_wide_map({"mode": "room_locked", "room": [2, 2, 16, 14]}))
	equal(camera.mode, GameCamera.Mode.ROOM_LOCKED, "the map asked for room_locked")
	equal(camera.clamp_bounds(), Iso.cell_bounds(room),
		"a room-locked camera clamps to the room, not to the map")
	equal(camera.limit_left, int(Iso.cell_bounds(room).position.x),
		"the room rectangle must reach the camera's own limits")


## A room smaller than the screen cannot be scrolled without showing what is
## outside it, so it is held centred instead. That is the composition-first
## half of the mode, and the case an interior actually hits.
func test_a_room_smaller_than_the_screen_is_held_centred() -> void:
	await _boot()
	if world == null:
		return
	var camera := world.camera
	var room := Rect2i(0, 0, 3, 3)
	camera.fit_to_map(_wide_map({"mode": "room_locked", "room": [0, 0, 3, 3]}))
	ok(camera.top_level, "a small room detaches the camera from the player")
	equal(camera.global_position, Iso.cell_bounds(room).get_center(),
		"and holds the room's centre")
	ok(not camera.position_smoothing_enabled, "a held camera has nothing to ease toward")


func test_fixed_holds_its_authored_frame_while_the_player_moves() -> void:
	await _boot()
	if world == null:
		return
	var camera := world.camera
	var map := _wide_map({"mode": "fixed", "at": [8, 8], "offset": [0, -24]})
	camera.fit_to_map(map)
	equal(camera.mode, GameCamera.Mode.FIXED, "the map asked for fixed")
	ok(camera.top_level, "a fixed camera does not ride the player")
	equal(camera.global_position, map.world_position(Vector2i(8, 8)) + Vector2(0, -24),
		"a fixed camera sits exactly where the map put it, offset included")
	equal(camera.clamp_bounds(), Rect2(),
		"nothing clamps an authored composition -- that is what makes it authored")

	# The player moving must not move the frame.
	var before := camera.global_position
	world.player.global_position += Vector2(64, 32)
	await frames(2)
	equal(camera.global_position, before, "the player walks through a fixed frame, not with it")


func test_a_fixed_camera_may_be_anchored_in_pixels() -> void:
	await _boot()
	if world == null:
		return
	var camera := world.camera
	camera.fit_to_map(_wide_map({"mode": "fixed", "position": [120.0, -40.0]}))
	equal(camera.global_position, Vector2(120.0, -40.0),
		"a pixel anchor is the escape hatch for framing that lands between cells")


# --------------------------------------------------------------------------
# cinematic borrowing
# --------------------------------------------------------------------------

## The specific bug the mode system exists to prevent: a cutscene that ends by
## assuming FOLLOW, and silently turns an authored composition into a
## player-chasing one.
func test_a_cinematic_returns_the_camera_to_the_mode_it_borrowed() -> void:
	await _boot()
	if world == null:
		return
	var camera := world.camera
	for mode: GameCamera.Mode in [GameCamera.Mode.FOLLOW, GameCamera.Mode.FIXED]:
		var spec: Dictionary = {"mode": "fixed", "at": [8, 8]} if mode == GameCamera.Mode.FIXED else {}
		camera.fit_to_map(_wide_map(spec))
		equal(camera.mode, mode, "the fixture should start in the mode under test")
		camera.borrow()
		equal(camera.mode, GameCamera.Mode.CINEMATIC, "borrowing enters cinematic")
		equal(camera.borrowed_from(), mode, "and remembers what it borrowed from")
		camera.release()
		equal(camera.mode, mode, "releasing must return to that mode, never to a default")


func test_focus_on_borrows_and_release_focus_hands_back() -> void:
	await _boot()
	if world == null:
		return
	var camera := world.camera
	camera.fit_to_map(_wide_map({"mode": "fixed", "at": [8, 8]}))
	var tween := camera.focus_on(Vector2(400, 200), 0.02)
	equal(camera.mode, GameCamera.Mode.CINEMATIC, "focus_on takes the camera")
	await tween.finished
	ok(camera.offset != Vector2.ZERO, "the focus must actually move the view")

	var back := camera.release_focus(0.02)
	await back.finished
	await frames(1)
	equal(camera.offset, Vector2.ZERO, "releasing must return the view")
	equal(camera.mode, GameCamera.Mode.FIXED, "and the mode it borrowed, not FOLLOW")


## Borrowing twice must not lose the original mode -- a cutscene that nests a
## lighting beat inside a camera move would otherwise never get home.
func test_borrowing_twice_still_remembers_the_original_mode() -> void:
	await _boot()
	if world == null:
		return
	var camera := world.camera
	camera.fit_to_map(_wide_map({"mode": "room_locked", "room": [2, 2, 16, 14]}))
	camera.borrow()
	camera.borrow()
	equal(camera.borrowed_from(), GameCamera.Mode.ROOM_LOCKED, "the first borrow is the one that counts")
	camera.release()
	equal(camera.mode, GameCamera.Mode.ROOM_LOCKED, "and it is what we come back to")


## Camera bounds still work at the production scale: a map's limits have to
## grow with the tile, or a 64x32 world would be clamped as if it were 32x16.
func test_camera_bounds_scale_with_the_geometry() -> void:
	await _boot()
	if world == null:
		return
	var map := world.loader.current
	var bounds := Iso.grid_bounds(Vector2i(map.width, map.height))
	equal(bounds.size.x, (map.width + map.height) * Iso.tile().x * 0.5,
		"the bounds must be measured in production tiles")
	ok(bounds.size.x > Presentation.viewport().x,
		"the town is wider than the 640px frame, so the camera has somewhere to scroll")
