## The generated files still agree with the data they were generated from.
##
## tiles.json is edited by hand; terrain.tres is baked from it. When someone
## adds a tile and forgets to re-run tools/build_tileset.gd the game silently
## draws nothing at that coordinate -- so the drift is what gets asserted here.
extends TestCase

const TILESET_PATH := "res://assets/tiles/terrain.tres"


func test_tileset_is_in_sync_with_tiles_json() -> void:
	var tile_set: TileSet = load(TILESET_PATH)
	if not ok(tile_set != null, "could not load %s" % TILESET_PATH):
		return
	var source: TileSetAtlasSource = tile_set.get_source(0)
	if not ok(source != null, "%s has no atlas source 0" % TILESET_PATH):
		return

	for tile_name: String in TileRegistry.names():
		var coords := TileRegistry.atlas_coords(tile_name)
		if not ok(source.has_tile(coords),
				"tile '%s' is in tiles.json but not in the baked tileset -- re-run tools/build_tileset.gd" % tile_name):
			continue
		var data: TileData = source.get_tile_data(coords, 0)
		var baked_solid := data.get_collision_polygons_count(0) > 0
		equal(baked_solid, TileRegistry.is_solid(tile_name),
			"tile '%s' solidity differs between tiles.json and the baked tileset" % tile_name)

	equal(source.get_tiles_count(), TileRegistry.names().size(),
		"baked tileset has a different tile count than tiles.json")


func test_no_two_tiles_share_an_atlas_cell() -> void:
	var seen: Dictionary = {}
	for tile_name: String in TileRegistry.names():
		var coords := TileRegistry.atlas_coords(tile_name)
		ok(coords != Vector2i(-1, -1), "tile '%s' has no atlas coordinate" % tile_name)
		if seen.has(coords):
			fail("tiles '%s' and '%s' both claim atlas cell %s" % [seen[coords], tile_name, coords])
		seen[coords] = tile_name


func test_atlas_image_is_big_enough_for_every_tile() -> void:
	var texture: Texture2D = load(TileRegistry.atlas_path())
	if not ok(texture != null, "could not load %s" % TileRegistry.atlas_path()):
		return
	var cell := TileRegistry.cell_size()
	for tile_name: String in TileRegistry.names():
		var coords := TileRegistry.atlas_coords(tile_name)
		ok((coords.x + 1) * cell.x <= texture.get_width()
				and (coords.y + 1) * cell.y <= texture.get_height(),
			"tile '%s' at %s falls outside the %dx%d atlas -- re-run tools/gen_art.py"
				% [tile_name, coords, texture.get_width(), texture.get_height()])


## The world's shape lives in three places -- tiles.json, the baked tileset and
## scripts/iso.gd -- and only the first is edited by hand. This is the check
## that the other two followed. A tileset that quietly reverted to square tiles
## still loads, still draws, and puts every wall in the wrong place.
func test_tileset_is_an_isometric_diamond_grid() -> void:
	var tile_set: TileSet = load(TILESET_PATH)
	if not ok(tile_set != null, "could not load %s" % TILESET_PATH):
		return
	equal(tile_set.tile_shape, TileSet.TILE_SHAPE_ISOMETRIC,
		"the baked tileset is not isometric -- re-run tools/build_tileset.gd")
	equal(tile_set.tile_layout, TileSet.TILE_LAYOUT_DIAMOND_DOWN,
		"the baked tileset uses a layout scripts/iso.gd does not reproduce")
	equal(tile_set.tile_offset_axis, TileSet.TILE_OFFSET_AXIS_HORIZONTAL,
		"the baked tileset offsets on the wrong axis")
	equal(tile_set.tile_size, TileRegistry.tile_size(),
		"baked tile size differs from tiles.json")

	var source: TileSetAtlasSource = tile_set.get_source(0)
	if not ok(source != null, "%s has no atlas source 0" % TILESET_PATH):
		return
	equal(source.texture_region_size, TileRegistry.cell_size(),
		"baked atlas cell differs from tiles.json")

	# tiles.json pads each cell so the ground diamond ends up centred in it.
	# That is the whole reason no offset is needed, so a non-zero one here
	# means someone changed the cell layout without changing the padding.
	for tile_name: String in TileRegistry.names():
		var data: TileData = source.get_tile_data(TileRegistry.atlas_coords(tile_name), 0)
		if data == null:
			continue
		equal(data.texture_origin, Vector2i.ZERO,
			"tile '%s' needs a texture offset; the footprint is no longer centred in its cell"
				% tile_name)


func test_actor_sheet_covers_every_actor() -> void:
	var texture: Texture2D = load("res://assets/sprites/actors.png")
	if not ok(texture != null, "could not load the actor sheet"):
		return
	var frame := ActorSprite.frame_size()
	var manifest := ActorSprite.manifest()
	var directions: int = manifest.get("directions", []).size()
	equal(directions, 4, "actor manifest should list four directions")
	for actor_name: String in ActorSprite.actor_names():
		var block := int(manifest["actors"][actor_name].get("row_block", -1))
		ok(block >= 0, "actor '%s' has no row_block" % actor_name)
		var bottom := (block * directions + directions) * frame.y
		ok(bottom <= texture.get_height(),
			"actor '%s' needs rows up to y=%d but the sheet is %dpx tall -- re-run tools/gen_art.py"
				% [actor_name, bottom, texture.get_height()])


func test_every_npc_definition_is_usable() -> void:
	var ids := Npc.all_ids()
	ok(ids.size() > 0, "there are no NPC definitions in data/npcs/")
	for npc_id: String in ids:
		var def := Npc.load_def(npc_id)
		if not ok(not def.is_empty(), "data/npcs/%s.json is empty or invalid JSON" % npc_id):
			continue
		not_empty(def.get("display_name", ""), "npc '%s' has no display_name" % npc_id)

		var sprite := String(def.get("sprite", "villager"))
		ok(ActorSprite.has_actor(sprite),
			"npc '%s' uses sprite '%s', which is not in assets/sprites/actors.json" % [npc_id, sprite])

		var dialogue_id := String(def.get("dialogue", npc_id))
		ok(Dialogue.exists(dialogue_id),
			"npc '%s' points at dialogue '%s', but dialogue/%s.json does not exist"
				% [npc_id, dialogue_id, dialogue_id])

		var behavior := String(def.get("behavior", "idle"))
		ok(["idle", "wander"].has(behavior),
			"npc '%s' has behavior '%s'; expected 'idle' or 'wander'" % [npc_id, behavior])

		var custom := String(def.get("script", ""))
		if not custom.is_empty():
			ok(ResourceLoader.exists(custom),
				"npc '%s' names script '%s', which does not exist" % [npc_id, custom])


func test_every_npc_definition_is_placed_on_a_map() -> void:
	var placed: Dictionary = {}
	for map_id: String in MapData.all_ids():
		for entry: Dictionary in MapData.load_map(map_id).npcs:
			placed[String(entry.get("npc", ""))] = map_id
	for npc_id: String in Npc.all_ids():
		ok(placed.has(npc_id),
			"npc '%s' is defined but no map places them; they can never be met" % npc_id)


## Sorting is by ground contact, which only works if a tile's sort origin is
## the tile's own position. A pack that shipped tall art with a baked-in
## offset, or a baker that reverted to sorting by half a cell, would put a
## player standing south of a wall behind it.
func test_tiles_sort_by_the_ground_they_stand_on() -> void:
	var tile_set: TileSet = load(TILESET_PATH)
	if not ok(tile_set != null, "could not load %s" % TILESET_PATH):
		return
	var source: TileSetAtlasSource = tile_set.get_source(0)
	if not ok(source != null, "%s has no atlas source 0" % TILESET_PATH):
		return
	for tile_name: String in TileRegistry.names():
		var data: TileData = source.get_tile_data(TileRegistry.atlas_coords(tile_name), 0)
		if data == null:
			continue
		equal(data.y_sort_origin, 0,
			"tile '%s' sorts from somewhere other than the ground it stands on" % tile_name)


## Imported art is somebody else's work and this repo publishes to the web on
## every merge, so a tile may only name a pack that says who made it and under
## what terms. CREDITS.md is generated from these same manifests.
func test_imported_tiles_carry_their_licence() -> void:
	var imported := TileRegistry.imported_names()
	for tile_name: String in imported:
		var pack_name := TileRegistry.pack_of(tile_name)
		var path := "res://assets/packs/%s/pack.json" % pack_name
		if not ok(FileAccess.file_exists(path),
				"tile '%s' names pack '%s', but %s is not there" % [tile_name, pack_name, path]):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not ok(parsed is Dictionary, "%s is not a JSON object" % path):
			continue
		var manifest: Dictionary = parsed
		for field: String in ["name", "source", "author", "license", "sheet", "tiles"]:
			not_empty(manifest.get(field, ""),
				"pack '%s' has no '%s'; imported art cannot ship without it" % [pack_name, field])
		var provided: Dictionary = manifest.get("tiles", {})
		var source_name := String(TileRegistry.tiles()[tile_name].get("pack_tile", tile_name))
		ok(provided.has(source_name),
			"pack '%s' does not provide '%s' (set \"pack_tile\" if it is named differently there)"
				% [pack_name, source_name])


func test_credits_lists_every_installed_pack() -> void:
	var imported := TileRegistry.imported_names()
	if imported.is_empty():
		return
	var f := FileAccess.open("res://CREDITS.md", FileAccess.READ)
	if not ok(f != null, "CREDITS.md is missing -- run tools/ci.sh generate"):
		return
	var text := f.get_as_text()
	f.close()
	var seen: Dictionary = {}
	for tile_name: String in imported:
		seen[TileRegistry.pack_of(tile_name)] = true
	for pack_name: String in seen:
		ok(text.contains(pack_name),
			"CREDITS.md does not mention pack '%s' -- run tools/ci.sh generate" % pack_name)
