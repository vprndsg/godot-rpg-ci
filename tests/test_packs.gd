## Imported art: the contracts a bought, downloaded or PixelOver-rendered
## asset has to satisfy before it can ship.
##
## The generators enforce most of this in Python (`tools/packs.py`,
## `tools/check_art.py`), which is right -- it means an art pack can be
## checked without an engine. What this suite adds is the half that only
## exists once Godot is loading things: that the naming conventions the
## importer promises are the ones the runtime looks for, that imported art
## still lands on the grid at the production scale, and that every imported
## pixel can say where it came from.
extends TestCase

const PACKS_DIR := "res://assets/packs"

## The sibling material maps a source may ship beside its diffuse image. The
## name IS the contract, in every direction: pack sheets, the tile atlas,
## actor sheets and scenery props all use it, so one convention covers a
## Blender -> PixelOver export whatever kind of thing it turns into.
const MATERIAL_SUFFIXES: PackedStringArray = ["_normal", "_emission"]


func _packs() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(PACKS_DIR)
	if dir == null:
		return out
	for name: String in dir.get_directories():
		if FileAccess.file_exists("%s/%s/pack.json" % [PACKS_DIR, name]):
			out.append(name)
	out.sort()
	return out


func _manifest(pack_name: String) -> Dictionary:
	var f := FileAccess.open("%s/%s/pack.json" % [PACKS_DIR, pack_name], FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


# --------------------------------------------------------------------------
# the naming contract
# --------------------------------------------------------------------------

## The atlas convention: terrain.png, terrain_normal.png, terrain_emission.png.
## The runtime looks for exactly these names, so they are worth pinning --
## a normal atlas nobody loads is worse than no normal atlas at all.
func test_the_material_map_naming_contract_holds_for_the_atlas() -> void:
	var diffuse := TileRegistry.atlas_path()
	equal(diffuse, "res://assets/tiles/terrain.png", "the diffuse atlas moved")
	for suffix: String in MATERIAL_SUFFIXES:
		var sibling := diffuse.replace(".png", "%s.png" % suffix)
		if not ResourceLoader.exists(sibling):
			continue
		var a: Texture2D = load(diffuse)
		var b: Texture2D = load(sibling)
		equal(b.get_size(), a.get_size(),
			"%s must be layout-identical to the diffuse atlas" % sibling)


## Emission ships and is wired; normals are wired and dormant. Both states are
## legal and the test asserts whichever one is true, because the contract is
## "if the file exists it is bound", not "the file exists".
func test_the_atlas_material_maps_are_wired_where_they_exist() -> void:
	ok(ResourceLoader.exists("res://assets/tiles/terrain_emission.png"),
		"the emission atlas is generated on every build and must be there")
	var tile_set: TileSet = load("res://assets/tiles/terrain.tres")
	var source: TileSetAtlasSource = tile_set.get_source(0)
	if not ok(source != null, "the baked tileset has no atlas source"):
		return
	if ResourceLoader.exists("res://assets/tiles/terrain_normal.png"):
		ok(source.texture is CanvasTexture,
			"a normal atlas exists but the bake did not wire it into a CanvasTexture")
	else:
		ok(not (source.texture is CanvasTexture),
			"the bake built a CanvasTexture with no normal atlas to put in it")


## Actor sheets use the same convention. Nothing ships one yet; the manifest
## is where a sheet declares it, and the schema accepts it today.
func test_actor_sheets_may_declare_material_maps() -> void:
	var manifest := ActorSprite.manifest()
	for actor_name: String in manifest.actor_names():
		for kind: String in ["normal", "emission"]:
			var path := manifest.material_map(actor_name, kind)
			if path.is_empty():
				continue
			ok(ResourceLoader.exists(path),
				"actor '%s' declares a %s map at '%s', which is not there" % [actor_name, kind, path])
	# And the schema accepts one, so a PixelOver character can bring its own.
	var with_maps := ActorManifest.from_dict({
		"version": 2,
		"sheets": {"s": {
			"texture": "res://assets/sprites/actors.png",
			"normal": "res://assets/sprites/actors.png",
			"frame_size": [32, 48], "anchor": [16, 44]}},
		"actors": {"a": {"sheet": "s", "directions": ["down"],
						 "clips": {"idle": {"row": 0, "frames": 1, "fps": 0.0}}}},
	})
	expect_no_errors(with_maps.validate(),
		"an actor sheet with a normal map must be a legal manifest")


## Scenery props too. One convention, four kinds of asset.
func test_scenery_props_may_declare_material_maps() -> void:
	var registry := SceneryRegistry.from_dict({"props": {"lit": {
		"texture": "res://assets/tiles/terrain.png",
		"emission": "res://assets/tiles/terrain_emission.png",
		"anchor": [32, 100],
	}}})
	expect_no_errors(registry.validate(), "a prop with an emission map must be legal")
	equal(registry.material_map("lit", "emission"), "res://assets/tiles/terrain_emission.png",
		"the registry must hand the path back")
	var broken := SceneryRegistry.from_dict({"props": {"lit": {
		"texture": "res://assets/tiles/terrain.png",
		"normal": "res://assets/scenery/not_there_normal.png",
		"anchor": [32, 100],
	}}})
	ok(broken.validate().size() > 0, "a material map that is not there must be reported")


# --------------------------------------------------------------------------
# licensing and provenance
# --------------------------------------------------------------------------

## This repo publishes to the web on every merge. Every imported pixel has to
## be able to say who made it and under what terms -- tiles already, and now
## scenery props too, by the same rule and the same manifests.
func test_every_imported_asset_can_say_where_it_came_from() -> void:
	var known: Dictionary = {}
	for pack_name: String in _packs():
		known[pack_name] = true
	for tile_name: String in TileRegistry.imported_names():
		ok(known.has(TileRegistry.pack_of(tile_name)),
			"tile '%s' names pack '%s', which is not installed" % [tile_name, TileRegistry.pack_of(tile_name)])
	var registry := SceneryRegistry.load_default()
	for prop_name: String in registry.imported_names():
		ok(known.has(registry.pack_of(prop_name)),
			"scenery prop '%s' names pack '%s', which is not installed"
				% [prop_name, registry.pack_of(prop_name)])


func test_pack_manifests_declare_their_scale() -> void:
	for pack_name: String in _packs():
		var manifest := _manifest(pack_name)
		if not manifest.has("scale"):
			continue
		var factor: Variant = manifest["scale"]
		ok(factor is float or factor is int, "pack '%s' scale must be a number" % pack_name)
		ok(int(factor) >= 1,
			"pack '%s' scale is %s; art is magnified by whole numbers or not at all -- "
				% [pack_name, factor] + "downscaling pixel art destroys it")


# --------------------------------------------------------------------------
# imported art at the production scale
# --------------------------------------------------------------------------

## An imported tile is a tile: same registry, same solidity, same baked
## collision, same sort origin. The importer's whole job is that the runtime
## cannot tell where a tile's pixels came from -- and after the geometry
## migration, that has to still be true at 64x32.
func test_imported_tiles_are_indistinguishable_from_drawn_ones() -> void:
	var imported := TileRegistry.imported_names()
	if not ok(imported.size() > 0, "no pack tile is installed; the import path is untested"):
		return
	var tile_set: TileSet = load("res://assets/tiles/terrain.tres")
	var source: TileSetAtlasSource = tile_set.get_source(0)
	for tile_name: String in imported:
		var data: TileData = source.get_tile_data(TileRegistry.atlas_coords(tile_name), 0)
		if not ok(data != null, "imported tile '%s' is not in the baked tileset" % tile_name):
			continue
		equal(data.y_sort_origin, 0,
			"imported tile '%s' must sort by the ground it stands on, like every other tile" % tile_name)
		equal(data.get_collision_polygons_count(0) > 0, TileRegistry.is_solid(tile_name),
			"imported tile '%s' baked a different solidity than tiles.json declares" % tile_name)
		if TileRegistry.is_solid(tile_name):
			equal(data.get_collision_polygon_points(0, 0), Iso.diamond(),
				"imported tile '%s' must collide on the production footprint, not a legacy one" % tile_name)


## The oversized-sprite property, for imported art specifically: a pack cell
## may be far bigger than the ground diamond, and it is the anchor -- not the
## image size -- that decides where the sprite lands.
func test_an_imported_cell_may_be_larger_than_the_tile_it_stands_on() -> void:
	var oversized := 0
	for pack_name: String in _packs():
		var manifest := _manifest(pack_name)
		var raw: Variant = manifest.get("cell_size", [])
		if not (raw is Array) or (raw as Array).size() != 2:
			continue
		var factor := maxi(1, int(manifest.get("scale", 1)))
		var cell := Vector2i(int(raw[0]) * factor, int(raw[1]) * factor)
		if cell.x > Iso.tile().x or cell.y > Iso.tile().y:
			oversized += 1
	ok(oversized > 0,
		"no installed pack draws bigger than one ground diamond, so the oversized-sprite path is untested")
