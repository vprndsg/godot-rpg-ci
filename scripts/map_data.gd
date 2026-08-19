## Parses and validates one file from maps/.
##
## Maps are plain-text ASCII grids on purpose. A `.tscn` TileMapLayer stores its
## cells as a binary PackedByteArray, which an agent editing files headlessly
## cannot read or write and which produces useless diffs. An ASCII grid is
## reviewable in a pull request and checkable by tests.
##
## `validate()` is the contract every map must satisfy; tests/test_maps.gd runs
## it over every file in maps/, so a broken map fails CI instead of shipping.
class_name MapData
extends RefCounted

const MAPS_DIR := "res://maps"
const EMPTY := " "

## Layer names in draw order. `ground` is always below actors, `objects` is
## y-sorted with them so the player can walk behind a tree.
const LAYERS: PackedStringArray = ["ground", "objects"]

const FACINGS: PackedStringArray = ["down", "left", "right", "up"]

var id: String = ""
var display_name: String = ""
var legend: Dictionary = {}
var layers: Dictionary = {}          # layer name -> PackedStringArray of rows
var spawns: Dictionary = {}          # spawn id -> Vector2i
var portals: Array[Dictionary] = []
var npcs: Array[Dictionary] = []
var signs: Array[Dictionary] = []
var width: int = 0
var height: int = 0

var parse_errors: PackedStringArray = []


static func path_for(map_id: String) -> String:
	return "%s/%s.json" % [MAPS_DIR, map_id]


static func exists(map_id: String) -> bool:
	return FileAccess.file_exists(path_for(map_id))


## Every map id in maps/, sorted. Used by the tests and the map-select debug menu.
static func all_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(MAPS_DIR)
	if dir == null:
		push_error("Cannot open %s" % MAPS_DIR)
		return out
	for file: String in dir.get_files():
		# Exported builds append .remap to imported files.
		var name := file.trim_suffix(".remap")
		if name.ends_with(".json"):
			out.append(name.trim_suffix(".json"))
	out.sort()
	return out


## Never returns null: a map that failed to parse comes back with
## `parse_errors` populated so callers and tests can report it uniformly.
static func load_map(map_id: String) -> MapData:
	var m := MapData.new()
	m.id = map_id
	var path := path_for(map_id)
	if not FileAccess.file_exists(path):
		m.parse_errors.append("no such file: %s" % path)
		return m
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()

	var json := JSON.new()
	if json.parse(text) != OK:
		m.parse_errors.append("invalid JSON at line %d: %s" % [json.get_error_line(), json.get_error_message()])
		return m
	var raw: Variant = json.data
	if not (raw is Dictionary):
		m.parse_errors.append("top level must be a JSON object")
		return m

	m._from_dict(raw)
	return m


func _from_dict(raw: Dictionary) -> void:
	display_name = String(raw.get("display_name", id))
	legend = raw.get("legend", {})

	for layer_name: String in LAYERS:
		var rows: PackedStringArray = []
		for row: Variant in raw.get(layer_name, []):
			rows.append(String(row))
		layers[layer_name] = rows

	var ground: PackedStringArray = layers.get("ground", PackedStringArray())
	height = ground.size()
	for row: String in ground:
		width = maxi(width, row.length())

	for spawn_id: String in raw.get("spawns", {}):
		spawns[spawn_id] = _to_vec(raw["spawns"][spawn_id])

	for p: Variant in raw.get("portals", []):
		if p is Dictionary:
			var portal: Dictionary = (p as Dictionary).duplicate()
			portal["at"] = _to_vec(portal.get("at"))
			portals.append(portal)

	for n: Variant in raw.get("npcs", []):
		if n is Dictionary:
			var npc: Dictionary = (n as Dictionary).duplicate()
			npc["at"] = _to_vec(npc.get("at"))
			npcs.append(npc)

	for s: Variant in raw.get("signs", []):
		if s is Dictionary:
			var sign_data: Dictionary = (s as Dictionary).duplicate()
			sign_data["at"] = _to_vec(sign_data.get("at"))
			signs.append(sign_data)


static func _to_vec(v: Variant) -> Vector2i:
	if v is Array and (v as Array).size() == 2:
		return Vector2i(int(v[0]), int(v[1]))
	return Vector2i(-1, -1)


# --------------------------------------------------------------------------
# grid queries
# --------------------------------------------------------------------------

func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height


## Legend character at a cell, or " " when the row is short or the layer absent.
func char_at(layer_name: String, cell: Vector2i) -> String:
	var rows: PackedStringArray = layers.get(layer_name, PackedStringArray())
	if cell.y < 0 or cell.y >= rows.size():
		return EMPTY
	var row: String = rows[cell.y]
	if cell.x < 0 or cell.x >= row.length():
		return EMPTY
	return row[cell.x]


## Tile name at a cell on one layer, or "" for empty.
func tile_at(layer_name: String, cell: Vector2i) -> String:
	var ch := char_at(layer_name, cell)
	if ch == EMPTY:
		return ""
	return String(legend.get(ch, ""))


## True when anything on any layer blocks movement, or the cell is off-map.
func is_solid(cell: Vector2i) -> bool:
	if not in_bounds(cell):
		return true
	for layer_name: String in LAYERS:
		var tile_name := tile_at(layer_name, cell)
		if tile_name != "" and TileRegistry.is_solid(tile_name):
			return true
	return false


func is_walkable(cell: Vector2i) -> bool:
	return not is_solid(cell)


## Cells reachable on foot from `origin`, 4-connected.
##
## This is what catches the class of bug you cannot see in a text diff: a door
## walled off by a fireplace, an NPC sealed in a closet, a staircase behind a
## table. tests/test_maps.gd asserts every portal, NPC and sign is in this set.
func reachable_from(origin: Vector2i) -> Dictionary:
	var seen: Dictionary = {}
	if not in_bounds(origin) or is_solid(origin):
		return seen
	var queue: Array[Vector2i] = [origin]
	seen[origin] = true
	const STEPS: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for step: Vector2i in STEPS:
			var next := cell + step
			if seen.has(next) or not in_bounds(next) or is_solid(next):
				continue
			seen[next] = true
			queue.append(next)
	return seen


## The spawn a validator should walk from: "start" if present, else any.
func primary_spawn() -> Vector2i:
	if spawns.has("start"):
		return spawns["start"]
	for spawn_id: String in spawns:
		return spawns[spawn_id]
	return Vector2i(-1, -1)


## Where a cell sits on screen. Grid coordinates are square; the diamond only
## happens here, on the way out. See scripts/iso.gd.
func world_position(cell: Vector2i) -> Vector2:
	return Iso.cell_centre(Vector2(cell))


## The cell a screen position stands in -- the inverse of world_position().
## Static because it needs nothing from the map, but named as a pair with it.
static func cell_at(pos: Vector2) -> Vector2i:
	return Iso.cell_at(pos)


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

## Returns a list of human-readable problems. Empty means the map is sound.
## Called by tests/test_maps.gd for every map; also worth calling from a
## skill after generating a map, before opening a pull request.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	errors.append_array(parse_errors)
	if not errors.is_empty():
		return errors

	if height == 0 or width == 0:
		errors.append("map is empty -- `ground` needs at least one row")
		return errors

	# 1. every layer is a full rectangle
	for layer_name: String in LAYERS:
		var rows: PackedStringArray = layers.get(layer_name, PackedStringArray())
		if rows.is_empty():
			continue
		if rows.size() != height:
			errors.append("layer '%s' has %d rows but 'ground' has %d" % [layer_name, rows.size(), height])
		for y: int in rows.size():
			if rows[y].length() != width:
				errors.append("layer '%s' row %d is %d chars, expected %d" % [layer_name, y, rows[y].length(), width])

	# 2. legend is complete and points at real tiles
	for ch: String in legend:
		if ch.length() != 1:
			errors.append("legend key '%s' must be exactly one character" % ch)
		var tile_name := String(legend[ch])
		if not TileRegistry.has_tile(tile_name):
			errors.append("legend '%s' -> unknown tile '%s' (not in assets/tiles/tiles.json)" % [ch, tile_name])

	var used: Dictionary = {}
	for layer_name: String in LAYERS:
		for row: String in layers.get(layer_name, PackedStringArray()):
			for i: int in row.length():
				var ch := row[i]
				if ch != EMPTY:
					used[ch] = true
	for ch: String in used:
		if not legend.has(ch):
			errors.append("character '%s' is used in a layer but missing from the legend" % ch)
	for ch: String in legend:
		if not used.has(ch):
			errors.append("legend defines '%s' (%s) but no layer uses it" % [ch, legend[ch]])

	# 3. spawn points must exist and be standable
	if spawns.is_empty():
		errors.append("map has no spawns -- add at least a 'start'")
	for spawn_id: String in spawns:
		var cell: Vector2i = spawns[spawn_id]
		if not in_bounds(cell):
			errors.append("spawn '%s' at %s is outside the %dx%d map" % [spawn_id, cell, width, height])
		elif is_solid(cell):
			errors.append("spawn '%s' at %s is inside a solid tile ('%s')" % [spawn_id, cell, _blocking_tile(cell)])

	var origin := primary_spawn()
	var reachable := reachable_from(origin) if in_bounds(origin) and not is_solid(origin) else {}

	# 4. portals lead somewhere real, and the player can actually get to them
	var occupied: Dictionary = {}
	for portal: Dictionary in portals:
		var cell: Vector2i = portal.get("at", Vector2i(-1, -1))
		var target := String(portal.get("to", ""))
		var target_spawn := String(portal.get("spawn", "start"))
		var label := "portal at %s -> %s" % [cell, target]
		if not in_bounds(cell):
			errors.append("%s is outside the map" % label)
			continue
		if is_solid(cell):
			errors.append("%s stands on a solid tile ('%s'); the player can never step on it" % [label, _blocking_tile(cell)])
		elif not reachable.has(cell):
			errors.append("%s is walled off from spawn %s -- no walkable path reaches it" % [label, origin])
		if target.is_empty():
			errors.append("%s has no 'to' map" % label)
		elif not MapData.exists(target):
			errors.append("%s points at a map that does not exist (maps/%s.json)" % [label, target])
		else:
			var other := MapData.load_map(target)
			if not other.spawns.has(target_spawn):
				errors.append("%s asks for spawn '%s', which %s does not define" % [label, target_spawn, target])
		if occupied.has(cell):
			errors.append("two portals share cell %s" % cell)
		occupied[cell] = true

	# 5. NPCs stand on floor, are reachable, and are not inside each other
	var actors: Dictionary = {}
	for npc: Dictionary in npcs:
		var cell: Vector2i = npc.get("at", Vector2i(-1, -1))
		var npc_id := String(npc.get("npc", ""))
		var label := "npc '%s' at %s" % [npc_id, cell]
		if npc_id.is_empty():
			errors.append("an npc entry is missing its 'npc' id")
		elif not FileAccess.file_exists("res://data/npcs/%s.json" % npc_id):
			errors.append("%s has no definition at data/npcs/%s.json" % [label, npc_id])
		if not in_bounds(cell):
			errors.append("%s is outside the map" % label)
			continue
		if is_solid(cell):
			errors.append("%s is standing inside '%s'" % [label, _blocking_tile(cell)])
		elif not reachable.has(cell):
			errors.append("%s is unreachable from spawn %s -- the player can never talk to them" % [label, origin])
		if actors.has(cell):
			errors.append("%s shares a cell with '%s'" % [label, actors[cell]])
		actors[cell] = npc_id
		var facing := String(npc.get("facing", "down"))
		if not FACINGS.has(facing):
			errors.append("%s has facing '%s'; expected one of %s" % [label, facing, FACINGS])

	# 6. signs need text, a solid tile to be mounted on, and an adjacent
	#    walkable cell -- a sign you cannot stand next to is unreadable
	for sign_data: Dictionary in signs:
		var cell: Vector2i = sign_data.get("at", Vector2i(-1, -1))
		var label := "sign at %s" % cell
		if String(sign_data.get("text", "")).is_empty():
			errors.append("%s has no text" % label)
		if not in_bounds(cell):
			errors.append("%s is outside the map" % label)
			continue
		if actors.has(cell):
			errors.append("%s shares a cell with npc '%s'" % [label, actors[cell]])
		var adjacent_ok := false
		for step: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			if reachable.has(cell + step):
				adjacent_ok = true
				break
		if not adjacent_ok:
			errors.append("%s cannot be read -- no reachable walkable cell is next to it" % label)

	return errors


func _blocking_tile(cell: Vector2i) -> String:
	for layer_name: String in LAYERS:
		var tile_name := tile_at(layer_name, cell)
		if tile_name != "" and TileRegistry.is_solid(tile_name):
			return tile_name
	return "out of bounds"
