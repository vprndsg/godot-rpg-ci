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


## True for tiles that carry the player between elevation levels -- stairs,
## ramps, ladder feet. A step of exactly one level is legal only across such
## a tile; without one the same edge is a cliff. Explicit metadata, not a
## guess from the elevation difference, so a map can put a sheer drop and a
## staircase on the same hillside.
static func is_elevation_transition(tile_name: String) -> bool:
	return bool(tiles().get(tile_name, {}).get("elevation_transition", false))


## Which imported art pack a tile's pixels come from, or "" when a painter in
## tools/gen_art.py drew them. Third-party art carries licence terms, so the
## game has to be able to say where each tile came from.
static func pack_of(tile_name: String) -> String:
	return String(tiles().get(tile_name, {}).get("pack", ""))


## Tiles whose art was imported rather than drawn, sorted.
static func imported_names() -> Array:
	var out: Array = []
	for tile_name: String in tiles():
		if not pack_of(tile_name).is_empty():
			out.append(tile_name)
	out.sort()
	return out


# --------------------------------------------------------------------------
# lighting metadata
#
# A tile's "lighting" block describes intent -- emits light, blocks light,
# stays lit in the dark -- and the runtime decides what nodes that becomes.
# Nothing anywhere may special-case a tile *name* to get lighting behaviour;
# this metadata is the only channel. docs/architecture/lighting.md documents
# the schema; validate_lighting() below enforces it, and both the tileset
# baker and the test suite call it.
# --------------------------------------------------------------------------

const LIGHTING_KEYS: PackedStringArray = ["emit", "occluder", "emission"]
const EMIT_KEYS: PackedStringArray = ["color", "energy", "radius", "offset", "height", "shadows"]
const OCCLUDER_KEYS: PackedStringArray = ["shape", "scale", "points"]

## Defaults for a light emitter. Radius is in screen pixels; offset is screen
## pixels relative to the centre of the tile's ground diamond (negative y is
## up, toward a lamp head). Height feeds normal-mapped lighting and must stay
## above zero or normal-mapped art would receive no light at all.
const EMIT_DEFAULTS := {
	"color": "ffffff", "energy": 1.0, "radius": 32.0,
	"offset": [0.0, 0.0], "height": 12.0, "shadows": false,
}


## The raw "lighting" block of a tile, or {} when it has none.
static func lighting_of(tile_name: String) -> Dictionary:
	var block: Variant = tiles().get(tile_name, {}).get("lighting", {})
	return block if block is Dictionary else {}


## Normalised emitter description, or {} when the tile emits nothing.
## Keys: color (Color), energy/radius/height (float), offset (Vector2),
## shadows (bool). The world's Lighting node turns one of these plus a cell
## into a PointLight2D.
static func light_emitter(tile_name: String) -> Dictionary:
	var emit: Variant = lighting_of(tile_name).get("emit")
	if not (emit is Dictionary):
		return {}
	var spec: Dictionary = emit
	var raw_offset: Array = spec.get("offset", EMIT_DEFAULTS["offset"])
	if raw_offset.size() != 2:
		raw_offset = EMIT_DEFAULTS["offset"]
	var colour := String(spec.get("color", EMIT_DEFAULTS["color"]))
	return {
		"color": Color.html(colour) if Color.html_is_valid(colour) else Color.WHITE,
		"energy": float(spec.get("energy", EMIT_DEFAULTS["energy"])),
		"radius": float(spec.get("radius", EMIT_DEFAULTS["radius"])),
		"offset": Vector2(float(raw_offset[0]), float(raw_offset[1])),
		"height": float(spec.get("height", EMIT_DEFAULTS["height"])),
		"shadows": bool(spec.get("shadows", EMIT_DEFAULTS["shadows"])),
	}


## The polygon this tile blocks light with, relative to the centre of its
## ground diamond -- the same space as its collision polygon. Empty when the
## tile does not occlude. `"occluder": true` means the full footprint diamond;
## a dict can shrink it ("scale") or replace it ("points") so a tree's trunk
## can block light while its canopy does not.
static func occluder_polygon(tile_name: String) -> PackedVector2Array:
	var occ: Variant = lighting_of(tile_name).get("occluder")
	if occ is bool:
		return Iso.diamond() if occ else PackedVector2Array()
	if not (occ is Dictionary):
		return PackedVector2Array()
	var spec: Dictionary = occ
	if spec.has("points"):
		var out := PackedVector2Array()
		for point: Variant in spec["points"]:
			if point is Array and (point as Array).size() == 2:
				out.append(Vector2(float(point[0]), float(point[1])))
		return out
	return Iso.diamond(clampf(float(spec.get("scale", 1.0)), 0.05, 1.0))


## True when the tile's art stays lit in the dark. The pixels that glow live
## in the emission atlas (assets/tiles/terrain_emission.png), drawn by the
## tile's e_<name> painter in tools/gen_art.py; this flag is the contract that
## such pixels exist, and the generator fails when flag and painter disagree.
static func is_emissive(tile_name: String) -> bool:
	return bool(lighting_of(tile_name).get("emission", false))


## Tiles declaring each lighting behaviour, sorted -- for tests and tools.
static func emitter_names() -> Array:
	return _names_where(func(t: String) -> bool: return not light_emitter(t).is_empty())


static func occluder_names() -> Array:
	return _names_where(func(t: String) -> bool: return not occluder_polygon(t).is_empty())


static func emissive_names() -> Array:
	return _names_where(func(t: String) -> bool: return is_emissive(t))


static func _names_where(predicate: Callable) -> Array:
	var out: Array = []
	for tile_name: String in tiles():
		if predicate.call(tile_name):
			out.append(tile_name)
	out.sort()
	return out


## Problems with every tile's lighting metadata. Empty means tiles.json is
## sound. Run by tests/test_lighting.gd and by tools/build_tileset.gd, so a
## malformed block fails both the suite and the bake.
static func validate_lighting() -> PackedStringArray:
	var errors: PackedStringArray = []
	for tile_name: String in names():
		var subject := "tile '%s'" % tile_name
		var block: Variant = tiles()[tile_name].get("lighting", {})
		if not (block is Dictionary):
			errors.append("%s: 'lighting' must be an object" % subject)
			continue
		var spec: Dictionary = block
		for key: String in spec:
			if not key.begins_with("_") and not LIGHTING_KEYS.has(key):
				errors.append("%s: unknown lighting key '%s' (expected one of %s)" % [subject, key, LIGHTING_KEYS])
		if spec.has("emit"):
			errors.append_array(_validate_emit(subject, spec["emit"]))
		if spec.has("occluder"):
			errors.append_array(_validate_occluder(subject, spec["occluder"]))
		if spec.has("emission") and not (spec["emission"] is bool):
			errors.append("%s: 'emission' must be true or false" % subject)
	return errors


static func _validate_emit(subject: String, emit: Variant) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not (emit is Dictionary):
		errors.append("%s: 'emit' must be an object like {\"color\": \"ffd27a\", \"radius\": 40}" % subject)
		return errors
	var spec: Dictionary = emit
	for key: String in spec:
		if not key.begins_with("_") and not EMIT_KEYS.has(key):
			errors.append("%s: unknown emit key '%s' (expected one of %s)" % [subject, key, EMIT_KEYS])
	if spec.has("color") and not Color.html_is_valid(String(spec["color"])):
		errors.append("%s: emit color '%s' is not an html colour like 'ffd27a'" % [subject, spec["color"]])
	for numeric: String in ["energy", "radius", "height"]:
		if spec.has(numeric) and not (spec[numeric] is float or spec[numeric] is int):
			errors.append("%s: emit %s must be a number" % [subject, numeric])
	if spec.has("radius") and float(spec.get("radius", 1.0)) <= 0.0:
		errors.append("%s: emit radius must be positive" % subject)
	if spec.has("offset") and not _is_point(spec["offset"]):
		errors.append("%s: emit offset must be [x, y] in pixels" % subject)
	if spec.has("shadows") and not (spec["shadows"] is bool):
		errors.append("%s: emit shadows must be true or false" % subject)
	return errors


static func _validate_occluder(subject: String, occ: Variant) -> PackedStringArray:
	var errors: PackedStringArray = []
	if occ is bool:
		return errors
	if not (occ is Dictionary):
		errors.append("%s: 'occluder' must be true, false or an object" % subject)
		return errors
	var spec: Dictionary = occ
	for key: String in spec:
		if not key.begins_with("_") and not OCCLUDER_KEYS.has(key):
			errors.append("%s: unknown occluder key '%s' (expected one of %s)" % [subject, key, OCCLUDER_KEYS])
	if spec.has("points") and spec.has("shape"):
		errors.append("%s: occluder cannot have both 'shape' and 'points'" % subject)
	if spec.has("shape") and String(spec["shape"]) != "diamond":
		errors.append("%s: unknown occluder shape '%s' (only 'diamond'; use 'points' for anything else)" % [subject, spec["shape"]])
	if spec.has("scale"):
		if not (spec["scale"] is float or spec["scale"] is int):
			errors.append("%s: occluder scale must be a number" % subject)
		elif float(spec["scale"]) <= 0.0 or float(spec["scale"]) > 1.0:
			errors.append("%s: occluder scale must be in (0, 1] -- light blocking may not spill past the footprint" % subject)
	if spec.has("points"):
		if not (spec["points"] is Array) or (spec["points"] as Array).size() < 3:
			errors.append("%s: occluder points must be an array of at least 3 [x, y] pairs" % subject)
		else:
			for point: Variant in spec["points"]:
				if not _is_point(point):
					errors.append("%s: occluder point %s is not an [x, y] pair" % [subject, point])
	return errors


static func _is_point(v: Variant) -> bool:
	if not (v is Array) or (v as Array).size() != 2:
		return false
	return (v[0] is float or v[0] is int) and (v[1] is float or v[1] is int)
