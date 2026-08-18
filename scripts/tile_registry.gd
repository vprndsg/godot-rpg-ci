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


static func tile_size() -> int:
	return int(data().get("tile_size", 16))


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
