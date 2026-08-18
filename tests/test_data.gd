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
	var ts := TileRegistry.tile_size()
	for tile_name: String in TileRegistry.names():
		var coords := TileRegistry.atlas_coords(tile_name)
		ok((coords.x + 1) * ts <= texture.get_width() and (coords.y + 1) * ts <= texture.get_height(),
			"tile '%s' at %s falls outside the %dx%d atlas -- re-run tools/gen_art.py"
				% [tile_name, coords, texture.get_width(), texture.get_height()])


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
