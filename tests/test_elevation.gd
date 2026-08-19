## Terrain elevation: the z the world grew when it stopped being flat.
##
## The data half exercises MapData -- parsing, world positions, and
## can_move(), the single rule that decides what is a staircase and what is a
## cliff. The runtime half walks the real player up the hill in Port Azure
## and back down, because "the JSON says the plateau is reachable" and "the
## player can actually climb it" are different claims.
##
## The town's demo hill, for reference (x 4-8, y 13-17):
##
##       z1  z1  z1  z1  z1        y13   ring, tree at (8,14)
##       z1  z2  z2  z2  z1        y14   sign at (5,14)
##       z1  z2  z2  z2  z1        y15   bush at (7,15)
##       z1  z1  st1 z1  z1        y16   st1 = stairs at level 1
##               st0               y17   st0 = stairs at level 0
extends TestCase

const MAIN_SCENE := "res://scenes/main.tscn"

const STAIR_BASE := Vector2i(6, 17)     # stairs at level 0
const STAIR_TOP := Vector2i(6, 16)      # stairs at level 1
const PLATEAU_EDGE := Vector2i(6, 15)   # level 2
const PLATEAU := Vector2i(6, 14)        # level 2
const CLIFF_FOOT := Vector2i(4, 17)     # level 0, below a plain level-1 cell
const CLIFF_TOP := Vector2i(4, 16)      # level 1, no stairs

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
	GameState.current_map = "port_azure_town"
	main = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await frames(2)
	world = main.world()
	return world


# --------------------------------------------------------------------------
# data: parsing and positions
# --------------------------------------------------------------------------

func test_flat_maps_still_read_as_level_zero() -> void:
	var map := MapData.load_map("port_azure_inn_ground")
	expect_no_errors(map.validate(), "the inn should validate without an elevation layer")
	equal(map.max_elevation(), 0, "a map without an elevation layer is flat")
	for cell: Vector2i in [Vector2i(0, 0), Vector2i(8, 11), Vector2i(16, 10)]:
		equal(map.elevation_at(cell), 0, "flat map cell %s should be level 0" % cell)
		equal(map.world_position(cell), map.flat_world_position(cell),
			"on a flat map the surface is the flat plane at %s" % cell)


func test_the_town_hill_parses() -> void:
	var map := MapData.load_map("port_azure_town")
	equal(map.max_elevation(), 2, "the town's hill tops out at level 2")
	equal(map.elevation_at(PLATEAU), 2, "plateau cell")
	equal(map.elevation_at(CLIFF_TOP), 1, "ring cell")
	equal(map.elevation_at(STAIR_TOP), 1, "upper stair cell")
	equal(map.elevation_at(STAIR_BASE), 0, "lower stair cell sits at the level it climbs from")
	equal(map.elevation_at(Vector2i(16, 14)), 0, "the spawn is still at sea level")


func test_world_position_rises_one_level_per_z() -> void:
	var map := MapData.load_map("port_azure_town")
	for cell: Vector2i in [PLATEAU, CLIFF_TOP, STAIR_BASE]:
		var expected := Iso.cell_centre(Vector2(cell)) \
			+ Vector2(0, -map.elevation_at(cell) * Iso.ELEVATION_HEIGHT)
		equal(map.world_position(cell), expected,
			"world_position%s should be the flat centre lifted by its elevation" % cell)
		equal(map.flat_world_position(cell), Iso.cell_centre(Vector2(cell)),
			"flat_world_position%s must ignore elevation" % cell)


func test_elevation_layer_must_be_rectangular_digits() -> void:
	var bad_char := MapData.from_dict({
		"legend": {".": "grass"},
		"ground": ["..", ".."],
		"elevation": ["00", "0x"],
		"spawns": {"start": [0, 0]},
	})
	ok(String("\n".join(bad_char.validate())).contains("digit"),
		"a non-digit elevation cell should be rejected")

	var short_row := MapData.from_dict({
		"legend": {".": "grass"},
		"ground": ["..", ".."],
		"elevation": ["00", "0"],
		"spawns": {"start": [0, 0]},
	})
	ok(String("\n".join(short_row.validate())).contains("'elevation' row"),
		"a short elevation row should be rejected")

	var missing_rows := MapData.from_dict({
		"legend": {".": "grass"},
		"ground": ["..", ".."],
		"elevation": ["00"],
		"spawns": {"start": [0, 0]},
	})
	ok(String("\n".join(missing_rows.validate())).contains("'elevation' has 1 rows"),
		"an elevation layer must cover every ground row")


# --------------------------------------------------------------------------
# data: the movement rule
# --------------------------------------------------------------------------

func test_same_level_neighbours_are_traversable() -> void:
	var map := MapData.load_map("port_azure_town")
	ok(map.can_move(Vector2i(16, 14), Vector2i(17, 14)), "flat ground at level 0")
	ok(map.can_move(Vector2i(4, 13), Vector2i(5, 13)), "flat ground along the level-1 ring")
	ok(map.can_move(PLATEAU, PLATEAU_EDGE), "flat ground on the level-2 plateau")


func test_stairs_carry_one_level_up_and_back_down() -> void:
	var map := MapData.load_map("port_azure_town")
	ok(map.can_move(Vector2i(6, 18), STAIR_BASE), "walking onto the stair foot is a flat step")
	ok(map.can_move(STAIR_BASE, STAIR_TOP), "stairs climb from level 0 to 1")
	ok(map.can_move(STAIR_TOP, PLATEAU_EDGE), "stairs climb from level 1 to 2")
	ok(map.can_move(PLATEAU_EDGE, STAIR_TOP), "and back down onto the stairs")
	ok(map.can_move(STAIR_TOP, STAIR_BASE), "and down again")


func test_a_cliff_blocks_one_level_without_stairs() -> void:
	var map := MapData.load_map("port_azure_town")
	ok(not map.can_move(CLIFF_FOOT, CLIFF_TOP), "one level up a raw cliff must be blocked")
	ok(not map.can_move(CLIFF_TOP, CLIFF_FOOT), "one level down a raw cliff is blocked too, for now")
	ok(not map.can_move(Vector2i(5, 16), Vector2i(5, 15)),
		"ring to plateau without stairs must be blocked")


func test_more_than_one_level_is_always_blocked() -> void:
	var map := MapData.from_dict({
		"legend": {".": "grass", ">": "stairs_up"},
		"ground": [">."],
		"elevation": ["02"],
		"spawns": {"start": [0, 0]},
	})
	ok(not map.can_move(Vector2i(0, 0), Vector2i(1, 0)),
		"a two-level rise is blocked even from a transition tile")
	ok(not map.can_move(Vector2i(1, 0), Vector2i(0, 0)),
		"a two-level drop is blocked; falling is a later mechanic")


func test_reachability_walks_by_the_same_rule() -> void:
	var walled := {
		"legend": {".": "grass"},
		"ground": ["....", "....", "...."],
		"elevation": ["0110", "0110", "0000"],
		"spawns": {"start": [0, 0]},
	}
	var map := MapData.from_dict(walled)
	var reached := map.reachable_from(Vector2i(0, 0))
	ok(not reached.has(Vector2i(1, 1)),
		"a plateau with no stairs must not count as reachable")
	equal(reached.size(), 8, "only the eight level-0 cells are reachable")

	var with_stairs: Dictionary = walled.duplicate()
	with_stairs["legend"] = {".": "grass", ">": "stairs_up"}
	with_stairs["ground"] = ["....", "....", ".>.."]
	reached = MapData.from_dict(with_stairs).reachable_from(Vector2i(0, 0))
	ok(reached.has(Vector2i(1, 1)),
		"the same plateau with stairs below it is reachable")
	equal(reached.size(), 12, "every cell is reachable once the stairs exist")


# --------------------------------------------------------------------------
# runtime: layers, lift, and actually walking the hill
# --------------------------------------------------------------------------

func test_raised_cells_are_painted_at_height() -> void:
	await _boot()
	if world == null:
		return
	var loader := world.loader
	var lift := int(Iso.ELEVATION_HEIGHT)

	for level: int in [0, 1, 2]:
		if not ok(loader.terrain_layer(level) != null, "the town needs terrain layer %d" % level):
			return
	equal(loader.terrain_layer(3), null, "no layer above the hill's top")

	# The plateau's ground is two levels up; its cliff bands fill both bands
	# below it. The flat town stays in the base layer, exactly as before.
	ok(loader.terrain_layer(2).get_used_cells().has(PLATEAU), "plateau ground at level 2")
	ok(loader.terrain_layer(1).get_used_cells().has(CLIFF_TOP), "ring ground at level 1")
	ok(loader.terrain_layer(0).get_used_cells().has(PLATEAU), "cliff band 0 under the plateau")
	ok(loader.terrain_layer(1).get_used_cells().has(PLATEAU), "cliff band 1 under the plateau")
	ok(loader.terrain_layer(0).get_used_cells().has(CLIFF_TOP), "cliff band 0 under the ring")
	ok(loader.ground_layer.get_used_cells().has(Vector2i(16, 14)), "flat ground stays in the base layer")
	ok(not loader.ground_layer.get_used_cells().has(PLATEAU), "raised ground must leave the base layer")

	equal(loader.terrain_layer(2).position.y, -2.0 * lift, "level 2 draws two levels up")
	equal(loader.terrain_layer(2).y_sort_origin, 2 * lift - lift / 2.0,
		"raised terrain must keep sorting from its flat cell")

	# Objects standing on the hill ride their level's layer.
	var upper_objects: TileMapLayer = loader.object_layer_at(2)
	if ok(upper_objects != null, "the town needs a level-2 object layer"):
		ok(upper_objects.get_used_cells().has(Vector2i(7, 15)), "the bush stands on the plateau")
		ok(upper_objects.get_used_cells().has(Vector2i(5, 14)), "the sign stands on the plateau")
		equal(upper_objects.position.y, -2.0 * lift, "plateau objects draw two levels up")
		equal(upper_objects.y_sort_origin, 2 * lift, "plateau objects sort from their cell centre")
	var ring_objects: TileMapLayer = loader.object_layer_at(1)
	if ok(ring_objects != null, "the town needs a level-1 object layer"):
		ok(ring_objects.get_used_cells().has(Vector2i(8, 14)), "the tree stands on the ring")

	# A flat map builds none of this.
	world.enter("port_azure_inn_ground")
	await frames(2)
	equal(loader.terrain_layer(1), null, "a flat map needs no raised layers")
	ok(loader.ground_layer.get_used_cells().size() > 0, "the inn still paints its floor")


func test_player_feet_ride_the_terrain() -> void:
	await _boot()
	if world == null:
		return
	var map := world.loader.current
	world.player.global_position = map.flat_world_position(PLATEAU)
	await physics_frames(40)  # let the sprite's lift easing finish
	var sprite: ActorSprite = world.player.sprite
	equal(sprite.ground_lift, 2.0 * Iso.ELEVATION_HEIGHT, "two levels of lift on the plateau")
	ok(absf(sprite.position.y + 2.0 * Iso.ELEVATION_HEIGHT) < 0.5,
		"the sprite should be drawn two levels above the body (at %.1f)" % sprite.position.y)
	# Feet drawn at exactly the elevated surface the map reports.
	ok(absf((world.player.global_position.y + sprite.position.y) - map.world_position(PLATEAU).y) < 0.5,
		"the drawn feet must land on world_position() of the plateau")

	world.player.global_position = map.flat_world_position(Vector2i(16, 14))
	await physics_frames(40)
	equal(sprite.ground_lift, 0.0, "no lift back on flat ground")


func test_player_walks_up_the_hill_and_back_down() -> void:
	await _boot()
	if world == null:
		return
	var map := world.loader.current
	world.player.global_position = map.flat_world_position(Vector2i(6, 18))
	await physics_frames(2)

	# Climb: grid -y runs straight up the staircase. 70 frames is nearly five
	# tiles of walking, so the player crosses both stairs, the plateau edge,
	# and is finally pinned by the plateau's far cliff at (6, 14).
	Input.action_press("move_up")
	await physics_frames(70)
	Input.action_release("move_up")
	await physics_frames(2)

	var cell := Iso.cell_at(world.player.global_position)
	equal(cell, PLATEAU, "the climb should end pinned at the plateau's back edge, not %s" % cell)
	equal(map.elevation_at(cell), 2, "the player stands two levels up")

	# And back down the same stairs.
	Input.action_press("move_down")
	await physics_frames(70)
	Input.action_release("move_down")
	await physics_frames(2)

	cell = Iso.cell_at(world.player.global_position)
	equal(map.elevation_at(cell), 0, "walking back down lands at sea level")
	ok(cell.y >= 17, "the descent should carry past the stair foot (ended at %s)" % cell)


func test_a_cliff_stops_the_player_bodily() -> void:
	await _boot()
	if world == null:
		return
	var map := world.loader.current
	world.player.global_position = map.flat_world_position(CLIFF_FOOT)
	await physics_frames(2)

	Input.action_press("move_up")
	await physics_frames(30)
	Input.action_release("move_up")
	await physics_frames(2)

	var grid_y := Iso.screen_to_grid(world.player.global_position).y
	ok(grid_y > 16.4,
		"the player walked through a cliff face: grid y %.2f should still be in row 17" % grid_y)
	equal(map.elevation_at(Iso.cell_at(world.player.global_position)), 0,
		"still at the cliff's foot")
