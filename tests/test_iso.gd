## The projection agrees with the engine.
##
## scripts/iso.gd computes cell positions itself rather than asking a
## TileMapLayer, because the things that need them -- NPCs, signs, portals, the
## camera, the Python map renderer -- are not tile layers. That duplication is
## the risk this suite exists to remove: if `Iso` and Godot ever disagree, the
## tiles are drawn in one place and everything standing on them in another,
## and nothing else in the project would notice.
##
## So these tests build a real isometric TileMapLayer from the baked tileset
## and check our arithmetic against its answers.
extends TestCase

const TILESET_PATH := "res://assets/tiles/terrain.tres"

## Corners, both axes, the diagonal, and negatives -- enough to catch a sign
## error, a swapped axis or a missing half-tile offset.
const PROBES: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1),
	Vector2i(2, 0), Vector2i(0, 2), Vector2i(3, 5), Vector2i(9, 4),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-3, -7), Vector2i(31, 19),
]

var _layer: TileMapLayer = null


func before_all() -> void:
	_layer = TileMapLayer.new()
	_layer.tile_set = load(TILESET_PATH)


func after_all() -> void:
	if _layer != null:
		_layer.free()
		_layer = null


func test_cell_centres_match_a_real_tilemap_layer() -> void:
	if not ok(_layer.tile_set != null, "could not load %s" % TILESET_PATH):
		return
	for cell: Vector2i in PROBES:
		equal(Iso.cell_centre(Vector2(cell)), _layer.map_to_local(cell),
			"Iso.cell_centre%s disagrees with the engine's own layout" % cell)


func test_cell_at_matches_a_real_tilemap_layer() -> void:
	if not ok(_layer.tile_set != null, "could not load %s" % TILESET_PATH):
		return
	for cell: Vector2i in PROBES:
		var centre := _layer.map_to_local(cell)
		# The centre plus a nudge that stays well inside the diamond.
		for nudge: Vector2 in [Vector2.ZERO, Vector2(5, 0), Vector2(-5, 0),
				Vector2(0, 3), Vector2(0, -3), Vector2(4, 2)]:
			equal(Iso.cell_at(centre + nudge), _layer.local_to_map(centre + nudge),
				"Iso.cell_at disagrees with the engine %s from the centre of %s" % [nudge, cell])


func test_projecting_a_cell_and_back_returns_it() -> void:
	for cell: Vector2i in PROBES:
		equal(Iso.cell_at(Iso.cell_centre(Vector2(cell))), cell,
			"a cell did not survive the round trip through screen space")


func test_grid_neighbours_are_the_four_screen_diagonals() -> void:
	var tile := Iso.tile()
	var expected := {
		Vector2.RIGHT: Vector2(tile.x, tile.y) * 0.5,    # grid +x: down-right
		Vector2.DOWN: Vector2(-tile.x, tile.y) * 0.5,    # grid +y: down-left
		Vector2.LEFT: Vector2(-tile.x, -tile.y) * 0.5,   # grid -x: up-left
		Vector2.UP: Vector2(tile.x, -tile.y) * 0.5,      # grid -y: up-right
	}
	for step: Vector2 in expected:
		equal(Iso.grid_vector(step), expected[step],
			"grid step %s does not project to the diagonal the sprites are drawn for" % step)


## One key press has to cover the same ground whichever key it is, or walking
## north across a room takes twice as long as walking east across the same
## number of tiles.
func test_every_grid_direction_costs_the_same_distance() -> void:
	var reference := Iso.grid_vector(Vector2.RIGHT).length()
	for step: Vector2 in [Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		ok(absf(Iso.grid_vector(step).length() - reference) < 0.001,
			"a step %s covers %.2fpx but a step right covers %.2fpx"
				% [step, Iso.grid_vector(step).length(), reference])


func test_the_projection_is_linear_so_it_can_carry_velocities() -> void:
	# Player and NPC movement project a direction rather than a position, which
	# is only sound if the linear part really is linear.
	var a := Vector2(1.5, -0.25)
	var b := Vector2(-0.75, 2.0)
	var sum := Iso.grid_vector(a + b)
	var parts := Iso.grid_vector(a) + Iso.grid_vector(b)
	ok(sum.distance_to(parts) < 0.001,
		"grid_vector is not linear (%s vs %s); velocities cannot be projected with it" % [sum, parts])


func test_grid_bounds_contain_every_cell_of_a_map() -> void:
	for map_id: String in MapData.all_ids():
		var map := MapData.load_map(map_id)
		var bounds := Iso.grid_bounds(Vector2i(map.width, map.height))
		var tile := Iso.tile()
		for cell: Vector2i in [Vector2i(0, 0), Vector2i(map.width - 1, 0),
				Vector2i(0, map.height - 1), Vector2i(map.width - 1, map.height - 1)]:
			var centre := Iso.cell_centre(Vector2(cell))
			# Every corner of the corner tiles, not just their centres.
			for corner: Vector2 in [Vector2(tile.x, 0) * 0.5, Vector2(-tile.x, 0) * 0.5,
					Vector2(0, tile.y) * 0.5, Vector2(0, -tile.y) * 0.5]:
				var point := centre + corner
				ok(bounds.has_point(point) or bounds.abs().grow(0.5).has_point(point),
					"map '%s': cell %s reaches %s, outside the bounds %s the camera clamps to"
						% [map_id, cell, point, bounds])


## One elevation level is half a diamond on purpose: raising a cell one level
## lifts it exactly as far as stepping one cell toward the back of the map
## does. tools/pixel.py's level_px() derives the same value from the registry,
## so this pin is what keeps the game and the Python renderers agreeing about
## how tall a hill is.
func test_elevation_height_is_half_a_diamond() -> void:
	equal(Iso.ELEVATION_HEIGHT, Iso.tile().y * 0.5,
		"Iso.ELEVATION_HEIGHT no longer matches the registry's tile height -- update tools/pixel.py level_px() and the art to match, deliberately")


## Actors are placed at their cell's centre and drawn with their feet there, so
## the sprite's own foot row has to agree with the offset the node applies.
func test_actor_sprites_stand_on_their_own_position() -> void:
	var manifest := ActorSprite.manifest()
	equal(int(manifest.get("foot_row", -1)), ActorSprite.FOOT_ROW,
		"assets/sprites/actors.json was drawn with a different foot row than scripts/actor_sprite.gd expects -- re-run tools/gen_art.py")
