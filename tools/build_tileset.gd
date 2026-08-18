## Bakes assets/tiles/terrain.tres from assets/tiles/tiles.json.
##
##     godot --headless --path . --script res://tools/build_tileset.gd
##
## A TileSet is a binary-ish resource full of generated ids; hand-editing one is
## a bad time and produces unreadable diffs. Instead the tile list lives in JSON
## and this script is the only thing that writes the .tres. Re-run it whenever
## tiles.json changes -- test_data_integrity.gd fails CI if you forget.
extends SceneTree

const OUT_PATH := "res://assets/tiles/terrain.tres"


func _initialize() -> void:
	var exit_code := build()
	quit(exit_code)


func build() -> int:
	var atlas_path := TileRegistry.atlas_path()
	if not ResourceLoader.exists(atlas_path):
		printerr("Missing atlas %s -- run `python3 tools/gen_art.py` first." % atlas_path)
		return 1

	var texture: Texture2D = load(atlas_path)
	var ts := TileRegistry.tile_size()

	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(ts, ts)
	tile_set.add_physics_layer(0)
	# Layer 1 == "world" in project.godot; the player and NPCs mask against it.
	tile_set.set_physics_layer_collision_layer(0, 1)
	tile_set.set_physics_layer_collision_mask(0, 0)

	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(ts, ts)
	# Register the source before creating tiles: TileData only grows physics
	# layers once its source belongs to a TileSet that has them.
	tile_set.add_source(source, 0)

	var half := ts / 2.0
	var box := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half),
	])

	var solid_count := 0
	for tile_name: String in TileRegistry.names():
		var coords := TileRegistry.atlas_coords(tile_name)
		if coords == Vector2i(-1, -1):
			printerr("Tile '%s' has no atlas coordinate." % tile_name)
			return 1
		if source.has_tile(coords):
			printerr("Two tiles claim atlas cell %s (second was '%s')." % [coords, tile_name])
			return 1
		source.create_tile(coords)
		var data: TileData = source.get_tile_data(coords, 0)
		# Sort tall props by the ground they stand on, so a player north of a
		# tree draws behind it and a player south of it draws in front.
		data.y_sort_origin = int(half)
		if TileRegistry.is_solid(tile_name):
			data.add_collision_polygon(0)
			data.set_collision_polygon_points(0, 0, box)
			solid_count += 1

	for tile_name: String in TileRegistry.names():
		if not TileRegistry.is_solid(tile_name):
			continue
		var data: TileData = source.get_tile_data(TileRegistry.atlas_coords(tile_name), 0)
		if data.get_collision_polygons_count(0) != 1:
			printerr("Solid tile '%s' came out with no collision polygon." % tile_name)
			return 1

	var err := ResourceSaver.save(tile_set, OUT_PATH)
	if err != OK:
		printerr("Could not write %s (error %d)" % [OUT_PATH, err])
		return 1
	print("Wrote %s: %d tiles, %d solid." % [OUT_PATH, TileRegistry.names().size(), solid_count])
	return 0
