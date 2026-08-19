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
## Optional normal-map atlas, laid out cell-for-cell like terrain.png. When it
## exists the tileset draws through a CanvasTexture, and 2D lights start
## shading tiles by their normals; when it does not, nothing changes. That
## conditional is the whole normal-map contract -- see docs/architecture/lighting.md.
const NORMAL_ATLAS := "res://assets/tiles/terrain_normal.png"


func _initialize() -> void:
	var exit_code := build()
	quit(exit_code)


func build() -> int:
	var atlas_path := TileRegistry.atlas_path()
	if not ResourceLoader.exists(atlas_path):
		printerr("Missing atlas %s -- run `python3 tools/gen_art.py` first." % atlas_path)
		return 1

	# A malformed lighting block would otherwise bake into nonsense silently.
	var lighting_errors := TileRegistry.validate_lighting()
	if not lighting_errors.is_empty():
		for error: String in lighting_errors:
			printerr(error)
		return 1

	var texture: Texture2D = load(atlas_path)
	if ResourceLoader.exists(NORMAL_ATLAS):
		var canvas_texture := CanvasTexture.new()
		canvas_texture.diffuse_texture = texture
		canvas_texture.normal_texture = load(NORMAL_ATLAS)
		texture = canvas_texture
	var tile := TileRegistry.tile_size()
	var cell := TileRegistry.cell_size()

	var tile_set := TileSet.new()
	# The diamond grid itself. Godot lays cells out from tile_size alone, so
	# this is the one place the world's shape is decided; scripts/iso.gd
	# reproduces the same layout for everything outside the TileMapLayers.
	tile_set.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	tile_set.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	tile_set.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL
	tile_set.tile_size = tile
	tile_set.add_physics_layer(0)
	# Layer 1 == "world" in project.godot; the player and NPCs mask against it.
	tile_set.set_physics_layer_collision_layer(0, 1)
	tile_set.set_physics_layer_collision_mask(0, 0)
	# One occlusion layer for the whole world. Tiles whose metadata says
	# "occluder" get a polygon on it below; any shadow-casting Light2D on
	# light mask 1 (the default) then collides with them for free.
	tile_set.add_occlusion_layer(0)
	tile_set.set_occlusion_layer_light_mask(0, 1)

	var source := TileSetAtlasSource.new()
	source.texture = texture
	# A cell is taller than the diamond so tall art has headroom. Godot draws
	# the region centred on the cell and tiles.json pads the bottom to match,
	# so the footprint lands on the diamond with texture_origin left at zero.
	source.texture_region_size = cell
	# Register the source before creating tiles: TileData only grows physics
	# layers once its source belongs to a TileSet that has them.
	tile_set.add_source(source, 0)

	var footprint := Iso.diamond()

	var solid_count := 0
	var occluder_count := 0
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
		# Zero, not half a cell: a tile's position is already the centre of the
		# ground it stands on, and screen depth in an isometric grid is exactly
		# that centre. So a player one cell in front of a tree sorts in front of
		# it, and the tree's 24px of canopy never votes on the ordering.
		data.y_sort_origin = 0
		if TileRegistry.is_solid(tile_name):
			data.add_collision_polygon(0)
			data.set_collision_polygon_points(0, 0, footprint)
			solid_count += 1
		# Light occlusion is its own footprint: a tree collides on its whole
		# diamond but only its trunk blocks light. The registry resolves the
		# metadata into a polygon; TileMapLayers pick these up automatically.
		var occluder := TileRegistry.occluder_polygon(tile_name)
		if not occluder.is_empty():
			var polygon := OccluderPolygon2D.new()
			polygon.polygon = occluder
			data.add_occluder_polygon(0)
			data.set_occluder_polygon(0, 0, polygon)
			occluder_count += 1

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
	print("Wrote %s: %d tiles, %d solid, %d occluders." % [OUT_PATH, TileRegistry.names().size(), solid_count, occluder_count])
	return 0
