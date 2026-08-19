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

## What shows beyond the edge of the world.
##
## A map is a diamond on screen and the camera is a rectangle, so the corners
## of the view see past the map however tight the limits are -- that is a
## property of the projection, not a bug to clamp away. Maps therefore choose
## what is out there: open water off a coast, unlit night around a room.
const DEFAULT_BACKGROUND := "0d151c"

## The four grid neighbours. Walkability is 4-connected however the world is
## projected, so the flood fill and the validator both step by these.
const NEIGHBOURS: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var id: String = ""
var display_name: String = ""
var background: Color = Color.html(DEFAULT_BACKGROUND)
## The raw "lighting" block: a profile name plus overrides, or {} for the
## full-bright default. scripts/lighting_profile.gd resolves it; the world's
## Lighting node applies it. Kept raw here so MapData stays a pure parser.
var lighting: Dictionary = {}
var legend: Dictionary = {}
var layers: Dictionary = {}          # layer name -> PackedStringArray of rows
## Terrain height per cell, one digit 0-9 per character. Not a tile layer:
## its characters are levels, not legend entries. Empty means a flat map --
## every cell at level 0 -- which is what keeps old maps valid unchanged.
var elevation_rows: PackedStringArray = []
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


## Build a map straight from a dictionary -- what load_map() does after the
## JSON parse. Tests use this to try grids that should never be files.
static func from_dict(raw: Dictionary, map_id: String = "in_memory") -> MapData:
	var m := MapData.new()
	m.id = map_id
	m._from_dict(raw)
	return m


func _from_dict(raw: Dictionary) -> void:
	display_name = String(raw.get("display_name", id))
	legend = raw.get("legend", {})

	var colour := String(raw.get("background", DEFAULT_BACKGROUND))
	if Color.html_is_valid(colour):
		background = Color.html(colour)
	else:
		parse_errors.append("background '%s' is not an html colour like '0d151c'" % colour)

	var raw_lighting: Variant = raw.get("lighting", {})
	if raw_lighting is Dictionary:
		lighting = raw_lighting
	else:
		parse_errors.append("'lighting' must be an object like {\"profile\": \"outdoor_day\"}")

	for layer_name: String in LAYERS:
		var rows: PackedStringArray = []
		for row: Variant in raw.get(layer_name, []):
			rows.append(String(row))
		layers[layer_name] = rows

	for row: Variant in raw.get("elevation", []):
		elevation_rows.append(String(row))

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


## Terrain height of a cell, in whole levels. 0 off-map, 0 everywhere on a
## map without an elevation layer. Solidity says whether you may stand on a
## cell; elevation says how high your feet are when you do.
func elevation_at(cell: Vector2i) -> int:
	if not in_bounds(cell) or cell.y >= elevation_rows.size():
		return 0
	var row := elevation_rows[cell.y]
	if cell.x >= row.length():
		return 0
	var level := row.unicode_at(cell.x) - 48  # the digit '0'
	return clampi(level, 0, 9)


## The tallest level any cell reaches; how many raised layers a renderer needs.
func max_elevation() -> int:
	var top := 0
	for y: int in mini(height, elevation_rows.size()):
		for x: int in width:
			top = maxi(top, elevation_at(Vector2i(x, y)))
	return top


## True when the cell carries a tile that may bridge one elevation level --
## see TileRegistry.is_elevation_transition. The tile spans from the cell's
## own level up toward the next: stairs at level 0 climb to a level-1
## neighbour, and their art rises to meet it.
func is_elevation_transition(cell: Vector2i) -> bool:
	for layer_name: String in LAYERS:
		var tile_name := tile_at(layer_name, cell)
		if tile_name != "" and TileRegistry.is_elevation_transition(tile_name):
			return true
	return false


## THE world rule for moving between two adjacent cells. Gameplay, the
## reachability flood fill and any future pathfinding all ask this one
## question, so they cannot disagree about what a cliff is:
##   - same level: walk freely.
##   - one level apart: only across a transition tile standing on the lower
##     cell (that is the cell a staircase occupies). Anything else is a cliff.
##   - further apart: blocked, up and (for now -- falling comes later) down.
func can_move(from: Vector2i, to: Vector2i) -> bool:
	if not in_bounds(from) or not in_bounds(to):
		return false
	if is_solid(to):
		return false
	var rise := elevation_at(to) - elevation_at(from)
	if rise == 0:
		return true
	if absi(rise) != 1:
		return false
	return is_elevation_transition(from if rise > 0 else to)


## can_move() for the steps continuous movement actually takes: staying in
## place is fine, and a diagonal is legal when one of its two dog-leg paths
## is. Actors move a fraction of a tile per frame, so these are the only
## cell changes a frame can produce.
func can_step(from: Vector2i, to: Vector2i) -> bool:
	if from == to:
		return true
	var d := to - from
	if absi(d.x) + absi(d.y) == 1:
		return can_move(from, to)
	if absi(d.x) == 1 and absi(d.y) == 1:
		return (can_move(from, Vector2i(to.x, from.y)) and can_move(Vector2i(to.x, from.y), to)) \
			or (can_move(from, Vector2i(from.x, to.y)) and can_move(Vector2i(from.x, to.y), to))
	return false


## Clamp a screen-space motion so it never crosses an edge can_step() forbids.
## Falls back to the motion's two grid-axis components, which is what lets an
## actor slide along a cliff edge instead of sticking to it. Solid tiles at
## level 0 still have baked physics; this is how cliffs and everything on
## raised ground block movement without collision shapes of their own.
func allowed_motion(pos: Vector2, motion: Vector2) -> Vector2:
	var from := Iso.cell_at(pos)
	if can_step(from, Iso.cell_at(pos + motion)):
		return motion
	var g := Iso.screen_to_grid(pos + motion) - Iso.screen_to_grid(pos)
	var along_x := Iso.grid_vector(Vector2(g.x, 0.0))
	if can_step(from, Iso.cell_at(pos + along_x)):
		return along_x
	var along_y := Iso.grid_vector(Vector2(0.0, g.y))
	if can_step(from, Iso.cell_at(pos + along_y)):
		return along_y
	return Vector2.ZERO


## Cells reachable on foot from `origin`, 4-connected, walking by the same
## can_move() rule the player walks by -- so a plateau with no stairs is
## unreachable even though nothing on it is solid.
##
## This is what catches the class of bug you cannot see in a text diff: a door
## walled off by a fireplace, an NPC sealed in a closet, a sign on a ledge no
## staircase reaches. tests/test_maps.gd asserts every portal, NPC and sign is
## in this set.
func reachable_from(origin: Vector2i) -> Dictionary:
	var seen: Dictionary = {}
	if not in_bounds(origin) or is_solid(origin):
		return seen
	# The queue is walked with a cursor rather than pop_front(): taking the
	# head off an Array shifts everything behind it, so every cell would cost
	# a copy of the whole frontier. Advancing an index visits the cells in
	# the same breadth-first order and never moves one.
	var queue: Array[Vector2i] = [origin]
	seen[origin] = true
	var head := 0
	while head < queue.size():
		var cell := queue[head]
		head += 1
		for step: Vector2i in NEIGHBOURS:
			var next := cell + step
			if seen.has(next) or not can_move(cell, next):
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


## Where a cell's ground *surface* sits on screen: the flat projection lifted
## by the cell's elevation. This is where the top of a hill visibly is.
func world_position(cell: Vector2i) -> Vector2:
	return flat_world_position(cell) + Iso.elevation_offset(elevation_at(cell))


## Where a cell sits on the flat (level-0) plane, elevation ignored. This is
## the plane the simulation lives on: actor bodies, physics, y-sorting and
## cell arithmetic all stay flat, and elevation is applied on the way to the
## screen -- tile layers are shifted up per level, actor sprites are lifted
## off their own body. That keeps Iso.cell_at(position) exact at any height,
## and leaves room for a jump offset later without touching the world model.
func flat_world_position(cell: Vector2i) -> Vector2:
	return Iso.cell_centre(Vector2(cell))


## The cell a screen position stands in -- the inverse of flat_world_position()
## (bodies live on the flat plane, so this is exact at any elevation).
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

	# 1b. elevation, when present, is a full rectangle of digits. It is not a
	#     tile layer -- its characters are levels 0-9, not legend entries --
	#     and a short row would silently flatten cells, so it gets the same
	#     rectangularity treatment.
	if not elevation_rows.is_empty():
		if elevation_rows.size() != height:
			errors.append("'elevation' has %d rows but 'ground' has %d" % [elevation_rows.size(), height])
		for y: int in elevation_rows.size():
			var row := elevation_rows[y]
			if row.length() != width:
				errors.append("'elevation' row %d is %d chars, expected %d" % [y, row.length(), width])
			for x: int in row.length():
				var code := row.unicode_at(x)
				if code < 48 or code > 57:  # '0'..'9'
					errors.append("'elevation' row %d has '%s' at column %d; every cell must be a digit 0-9" % [y, row[x], x])

	# 2. the lighting block resolves: profile exists, values are well-formed
	errors.append_array(LightingProfile.validate_spec(lighting, "lighting"))

	# 3. legend is complete and points at real tiles
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

	# 4. spawn points must exist and be standable
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

	# 5. portals lead somewhere real, and the player can actually get to them
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

	# 6. NPCs stand on floor, are reachable, and are not inside each other
	var actors: Dictionary = {}
	for npc: Dictionary in npcs:
		var cell: Vector2i = npc.get("at", Vector2i(-1, -1))
		var npc_id := String(npc.get("npc", ""))
		var label := "npc '%s' at %s" % [npc_id, cell]
		if npc_id.is_empty():
			errors.append("an npc entry is missing its 'npc' id")
		elif not Npc.def_exists(npc_id):
			errors.append("%s has no definition at %s" % [label, Npc.def_path(npc_id).trim_prefix("res://")])
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

	# 7. signs need text, a solid tile to be mounted on, and an adjacent
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
		for step: Vector2i in NEIGHBOURS:
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
