## The actor animation contract.
##
## The point of the manifest is that a production character -- eight
## directions, a six-frame trot at 12fps, a contextual one-shot, a 96x128
## frame -- needs no new runtime code. So most of this suite drives manifests
## that are not files: characters this game does not have, to prove the
## engine could draw them if it did.
##
## The other half is the failure modes. Missing is fine and falls back;
## malformed is never fine and is reported. Those are different, and a system
## that confused them would silently draw the wrong frame forever.
extends TestCase

const MAIN_SCENE := "res://scenes/main.tscn"

var main: Node = null
var world: World = null


func after_each() -> void:
	ActorManifest.clear_cache()
	if main != null:
		main.queue_free()
		main = null
		world = null
	GameState.reset()


## A character this project does not have: eight directions, four clips, its
## own frame size, a sparse clip and a fallback. Everything the visual target
## needs, as data.
func _production_manifest() -> ActorManifest:
	return ActorManifest.from_dict({
		"version": 2,
		"directions": ActorManifest.DIRECTIONS,
		"clip_fallbacks": {"run": "walk", "trot": "walk", "sniff": "idle"},
		"sheets": {
			"big": {"texture": "res://assets/tiles/terrain.png",
					"frame_size": [96, 128], "anchor": [48, 120]},
		},
		"actors": {
			"quadruped": {
				"sheet": "big",
				"directions": ActorManifest.DIRECTIONS,
				"clips": {
					"idle": {"row": 0, "frames": 2, "fps": 3.0, "loop": true},
					"walk": {"row": 8, "frames": 8, "fps": 10.0, "loop": true},
					"sit": {"row": 16, "frames": 4, "fps": 6.0, "loop": false},
					# Sparse on purpose: authored for two directions only.
					"sniff": {"row": 24, "frames": 6, "fps": 8.0, "loop": false,
							  "directions": ["down", "right"]},
				},
			},
			"cardinal_only": {
				"sheet": "big",
				"directions": ["down", "left", "right", "up"],
				"clips": {"walk": {"row": 0, "frames": 4, "fps": 7.0, "loop": true}},
				"fallbacks": {"idle": "walk"},
			},
		},
	})


# --------------------------------------------------------------------------
# directions
# --------------------------------------------------------------------------

func test_eight_directions_are_supported() -> void:
	equal(ActorManifest.DIRECTIONS.size(), 8, "the contract is eight directions")
	var manifest := _production_manifest()
	equal(manifest.directions("quadruped").size(), 8,
		"an actor may author all eight")
	equal(manifest.directions("cardinal_only").size(), 4,
		"and an actor may author only four")


## The eight are grid directions at 45 degree intervals, which on screen are
## the four diagonals and the four screen axes. Getting this wrong would make
## every character face the wrong way in a way no test of the grid would see.
func test_direction_vectors_are_the_eight_grid_directions() -> void:
	var expected := {
		"down": Vector2(0, 1), "up": Vector2(0, -1),
		"left": Vector2(-1, 0), "right": Vector2(1, 0),
		"down_left": Vector2(-1, 1).normalized(), "down_right": Vector2(1, 1).normalized(),
		"up_left": Vector2(-1, -1).normalized(), "up_right": Vector2(1, -1).normalized(),
	}
	for direction: String in expected:
		var actual := ActorManifest.direction_vector(direction)
		ok(actual.distance_to(expected[direction]) < 0.0001,
			"'%s' should point %s in grid space, got %s" % [direction, expected[direction], actual])
		ok(absf(actual.length() - 1.0) < 0.0001,
			"'%s' must be a unit vector so reach is the same in every direction" % direction)


func test_eight_way_facing_picks_the_diagonals() -> void:
	var cases := {
		"down_right": Vector2(1, 1), "down_left": Vector2(-1, 1),
		"up_left": Vector2(-1, -1), "up_right": Vector2(1, -1),
		"right": Vector2(1, 0), "down": Vector2(0, 1),
	}
	for expected: String in cases:
		equal(ActorSprite.facing_for(cases[expected]), expected,
			"a step of %s should face '%s'" % [cases[expected], expected])


## The pre-migration rule, preserved exactly: a four-direction character
## picks the axis of larger magnitude, and an exact diagonal faces down or up
## rather than left or right. Anything else silently re-animates every NPC.
func test_four_direction_actors_face_exactly_as_they_used_to() -> void:
	var cardinal: PackedStringArray = ["down", "left", "right", "up"]
	var cases := {
		Vector2(1, 1): "down", Vector2(-1, 1): "down",
		Vector2(1, -1): "up", Vector2(-1, -1): "up",
		Vector2(2, 1): "right", Vector2(1, 2): "down",
		Vector2(-2, 1): "left", Vector2(1, -2): "up",
		Vector2(3, 0): "right", Vector2(0, -5): "up",
	}
	for step: Vector2 in cases:
		equal(ActorSprite.facing_for(step, cardinal), cases[step],
			"a four-direction actor stepping %s must face '%s'" % [step, cases[step]])


func test_a_missing_direction_falls_back_to_the_nearest_authored_one() -> void:
	var manifest := _production_manifest()
	var clip := manifest.resolve_clip("quadruped", "sniff")
	var authored: PackedStringArray = clip["directions"]
	equal(authored.size(), 2, "sniff is authored for two directions")
	# down_right sits between the two; the tie rule sends it to down.
	equal(ActorManifest.nearest_direction("down_right", authored), "down",
		"a missing diagonal must snap to the nearest authored direction")
	equal(ActorManifest.nearest_direction("up_right", authored), "right",
		"up_right is nearer to right than to down")
	equal(ActorManifest.nearest_direction("down", authored), "down",
		"an authored direction must be returned unchanged")
	# And the region it slices is a real row of the sheet, not row -1.
	var region := ActorManifest.frame_region(clip, "up_left", 0)
	equal(region.position.y, 24.0 * 128.0, "the fallback direction must land on the clip's first row")


# --------------------------------------------------------------------------
# clips
# --------------------------------------------------------------------------

func test_clips_carry_their_own_length_and_frame_rate() -> void:
	var manifest := _production_manifest()
	var walk := manifest.resolve_clip("quadruped", "walk")
	equal(int(walk["frames"]), 8, "walk is eight frames")
	equal(float(walk["fps"]), 10.0, "walk runs at its own frame rate")
	var idle := manifest.resolve_clip("quadruped", "idle")
	equal(int(idle["frames"]), 2, "idle is a different length")
	equal(float(idle["fps"]), 3.0, "and a different frame rate")
	var sit := manifest.resolve_clip("quadruped", "sit")
	equal(bool(sit["loop"]), false, "a one-shot does not loop")


func test_frame_size_and_anchor_are_per_actor() -> void:
	var manifest := _production_manifest()
	equal(manifest.frame_size("quadruped"), Vector2i(96, 128),
		"a production character is not the size of a legacy villager")
	equal(manifest.anchor("quadruped"), Vector2i(48, 120), "and stands on its own foot point")
	# The shipped cast is a different size on a different sheet entirely.
	var shipped := ActorSprite.manifest()
	equal(shipped.frame_size("player"), Vector2i(32, 48),
		"the legacy cast is 32x48 after the migration -- 16x24 magnified")
	equal(shipped.anchor("player"), Vector2i(16, 44),
		"and its feet are where the old FOOT_ROW was, doubled")


func test_frame_regions_walk_the_sheet_correctly() -> void:
	var manifest := _production_manifest()
	var walk := manifest.resolve_clip("quadruped", "walk")
	equal(ActorManifest.frame_region(walk, "down", 0), Rect2(0, 8 * 128, 96, 128),
		"frame 0 of the first direction is the clip's own row")
	equal(ActorManifest.frame_region(walk, "down", 3), Rect2(3 * 96, 8 * 128, 96, 128),
		"frames run horizontally")
	equal(ActorManifest.frame_region(walk, "left", 0), Rect2(0, 10 * 128, 96, 128),
		"directions run down, one row each, in the clip's own order")
	equal(ActorManifest.frame_region(walk, "down", 99), Rect2(7 * 96, 8 * 128, 96, 128),
		"a frame index past the end clamps rather than reading somebody else's rows")


func test_a_missing_clip_falls_back_rather_than_failing() -> void:
	var manifest := _production_manifest()
	equal(manifest.resolve_clip_name("quadruped", "run"), "walk",
		"run must fall back to walk")
	equal(manifest.resolve_clip_name("quadruped", "trot"), "walk",
		"trot must fall back to walk through the shared chain")
	equal(manifest.resolve_clip_name("cardinal_only", "idle"), "walk",
		"a per-actor fallback must win where the actor has no idle")
	equal(manifest.resolve_clip_name("cardinal_only", "sniff"), "walk",
		"an unresolvable clip ends up at something drawable, never at nothing")


func test_the_shipped_cast_still_walks_and_idles() -> void:
	var manifest := ActorSprite.manifest()
	for actor_name: String in manifest.actor_names():
		equal(manifest.resolve_clip_name(actor_name, "walk"), "walk",
			"actor '%s' must have a walk" % actor_name)
		equal(manifest.resolve_clip_name(actor_name, "idle"), "idle",
			"actor '%s' must have an idle" % actor_name)
		# Every clip in the shared vocabulary resolves to something drawable,
		# on a cast that authors two of them.
		for wanted: String in ActorManifest.KNOWN_CLIPS:
			ok(not manifest.resolve_clip_name(actor_name, wanted).is_empty(),
				"actor '%s' resolved '%s' to nothing" % [actor_name, wanted])


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

func test_the_shipped_manifest_validates() -> void:
	expect_no_errors(ActorSprite.manifest().validate(), "assets/sprites/actors.json")


func test_a_production_shaped_manifest_validates() -> void:
	# Textures are checked off: this manifest names the tile atlas as a stand-in
	# so the schema can be exercised without inventing a character sheet.
	expect_no_errors(_production_manifest().validate(false),
		"an eight-direction, multi-clip, large-frame manifest must be legal")


func test_malformed_manifests_are_reported() -> void:
	var base := {
		"version": 2,
		"sheets": {"s": {"texture": "res://assets/tiles/terrain.png",
						 "frame_size": [32, 48], "anchor": [16, 44]}},
		"actors": {"a": {"sheet": "s", "directions": ["down"],
						 "clips": {"idle": {"row": 0, "frames": 1, "fps": 0.0}}}},
	}
	var cases := {
		"no version": ["version", 1],
		"zero-frame clip": ["clip_frames", 0],
		"frames with no frame rate": ["clip_fps", 0.0],
		"negative row": ["clip_row", -3],
		"unknown direction": ["direction", "northwest"],
		"duplicate direction": ["duplicate_direction", true],
		"anchor outside the frame": ["anchor", [16, 400]],
		"unknown sheet": ["sheet", "nowhere"],
		"no clips at all": ["no_clips", true],
		"fallback to nothing": ["fallback", "run"],
		"unknown clip key": ["clip_key", true],
	}
	for label: String in cases:
		var raw: Dictionary = base.duplicate(true)
		var kind: String = cases[label][0]
		var value: Variant = cases[label][1]
		match kind:
			"version": raw["version"] = value
			"clip_frames": raw["actors"]["a"]["clips"]["idle"]["frames"] = value
			"clip_fps":
				raw["actors"]["a"]["clips"]["idle"]["frames"] = 4
				raw["actors"]["a"]["clips"]["idle"]["fps"] = value
			"clip_row": raw["actors"]["a"]["clips"]["idle"]["row"] = value
			"direction": raw["actors"]["a"]["directions"] = [value]
			"duplicate_direction": raw["actors"]["a"]["directions"] = ["down", "down"]
			"anchor": raw["sheets"]["s"]["anchor"] = value
			"sheet": raw["actors"]["a"]["sheet"] = value
			"no_clips": raw["actors"]["a"]["clips"] = {}
			"fallback": raw["actors"]["a"]["fallbacks"] = {"walk": value}
			"clip_key": raw["actors"]["a"]["clips"]["idle"]["speed"] = 4
		var errors := ActorManifest.from_dict(raw).validate(false)
		ok(errors.size() > 0, "'%s' should be a validation error and was accepted" % label)
	expect_no_errors(ActorManifest.from_dict(base).validate(false),
		"the un-broken base manifest must validate")


## A clip whose rows run past the bottom of its sheet draws nothing and says
## nothing -- the exact failure a manifest is supposed to make impossible.
func test_a_clip_that_overruns_its_sheet_is_reported() -> void:
	var errors := ActorManifest.from_dict({
		"version": 2,
		"sheets": {"s": {"texture": "res://assets/sprites/actors.png",
						 "frame_size": [32, 48], "anchor": [16, 44]}},
		"actors": {"a": {"sheet": "s", "directions": ["down"],
						 "clips": {"idle": {"row": 999, "frames": 1, "fps": 0.0}}}},
	}).validate()
	ok("\n".join(errors).contains("rows up to"),
		"a clip past the end of its sheet must be reported, got %s" % [errors])


# --------------------------------------------------------------------------
# the runtime
# --------------------------------------------------------------------------

func test_the_sprite_plays_clips_and_falls_back() -> void:
	var sprite := ActorSprite.new()
	tree.root.add_child(sprite)
	sprite.actor = "player"
	await frames(1)
	equal(sprite.current_clip(), "idle", "a still actor idles")
	sprite.moving = true
	equal(sprite.current_clip(), "walk", "a moving actor walks")
	sprite.play("run")
	equal(sprite.current_clip(), "walk", "run falls back to walk on a cast that has no run")
	sprite.stop_action()
	equal(sprite.current_clip(), "walk", "clearing the action returns to walk")
	sprite.moving = false
	equal(sprite.current_clip(), "idle", "and stopping returns to idle")
	equal(sprite.available_directions().size(), 4,
		"the legacy cast authors four directions and says so")
	sprite.free()


## The sprite's origin is the actor's feet, computed from the manifest anchor.
## Every claim about sorting rests on this offset being right.
func test_the_sprite_origin_is_the_manifest_anchor() -> void:
	var sprite := ActorSprite.new()
	tree.root.add_child(sprite)
	sprite.actor = "player"
	await frames(1)
	var manifest := ActorSprite.manifest()
	var frame := manifest.frame_size("player")
	var foot := manifest.anchor("player")
	equal(sprite.offset, Vector2(frame.x / 2.0 - foot.x, frame.y / 2.0 - foot.y),
		"the sprite must be offset so its anchor sits on the node's position")
	sprite.free()


func test_the_running_game_still_animates_its_actors() -> void:
	GameState.reset()
	main = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await frames(2)
	world = main.world()
	if not ok(world != null, "the main scene never created a World"):
		return
	var sprite: ActorSprite = world.player.sprite
	ok(sprite.texture != null, "the player sprite has no sheet bound")
	equal(sprite.current_clip(), "idle", "a player standing still idles")

	world.player.face("right")
	equal(sprite.facing, "right", "facing must reach the sprite")
	var facing_region := sprite.region_rect
	world.player.face("up")
	ok(sprite.region_rect != facing_region, "turning must change which row is drawn")
