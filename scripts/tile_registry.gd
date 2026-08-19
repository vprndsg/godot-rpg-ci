## Reads assets/tiles/tiles.json, the single source of truth for tiles.
##
## Everything that needs to know "what does the character '#' mean" goes
## through here: the runtime map loader, the tileset baker (tools/build_tileset.gd)
## and the map tests. Adding a tile means editing tiles.json -- never hardcoding
## an atlas coordinate somewhere else.
class_name TileRegistry
extends RefCounted

const TILES_PATH := "res://assets/tiles/tiles.json"

static var _cache: Dictionary = {}


static func data() -> Dictionary:
	if _cache.is_empty():
		var f := FileAccess.open(TILES_PATH, FileAccess.READ)
		assert(f != null, "Missing %s" % TILES_PATH)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		assert(parsed is Dictionary, "%s is not a JSON object" % TILES_PATH)
		_cache = parsed
	return _cache


## Only useful in tests, which mutate nothing but may run before/after edits.
static func reload() -> void:
	_cache = {}


static func tiles() -> Dictionary:
	return data().get("tiles", {})


static func has_tile(tile_name: String) -> bool:
	return tiles().has(tile_name)


static func names() -> Array:
	var out: Array = tiles().keys()
	out.sort()
	return out


## The 2:1 diamond one cell covers on the ground -- Godot's TileSet.tile_size.
static func tile_size() -> Vector2i:
	return _vec("tile_size", Vector2i(32, 16))


## One cell of terrain.png. Taller than the diamond so walls, trees and roofs
## have somewhere to go; see the _geometry note in tiles.json.
static func cell_size() -> Vector2i:
	return _vec("cell_size", Vector2i(32, 64))


## First row of the diamond footprint inside a cell. The footprint is centred
## vertically, which is what keeps the baked tileset's texture_origin at zero.
static func footprint_top() -> int:
	return (cell_size().y - tile_size().y) / 2


static func _vec(key: String, fallback: Vector2i) -> Vector2i:
	var v: Array = data().get(key, [])
	if v.size() != 2:
		return fallback
	return Vector2i(int(v[0]), int(v[1]))


static func atlas_path() -> String:
	return String(data().get("atlas", ""))


static func atlas_columns() -> int:
	return int(data().get("atlas_columns", 8))


static func atlas_coords(tile_name: String) -> Vector2i:
	var t: Dictionary = tiles().get(tile_name, {})
	var a: Array = t.get("atlas", [])
	if a.size() != 2:
		return Vector2i(-1, -1)
	return Vector2i(int(a[0]), int(a[1]))


static func is_solid(tile_name: String) -> bool:
	return bool(tiles().get(tile_name, {}).get("solid", false))


## Atlas rows actually referenced, used to size the generated tileset.
static func atlas_rows() -> int:
	var maxy := 0
	for tile_name: String in tiles():
		maxy = maxi(maxy, atlas_coords(tile_name).y)
	return maxy + 1
