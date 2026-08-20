## Turns a MapData into live nodes: tile layers, NPCs, signs and portals.
##
## Nothing here is authored in the editor. Rebuilding a map is
## `load_map("port_azure_inn_ground")`, which is also exactly what the runtime
## tests do -- so a map that crashes on load fails CI.
class_name MapLoader
extends Node2D

const TILESET_PATH := "res://assets/tiles/terrain.tres"
const NPC_SCENE := preload("res://scenes/npc.tscn")
## Self-lit pixels for tiles flagged "emission" in tiles.json: an atlas laid
## out exactly like terrain.png (tools/gen_art.py::build_emission) that a
## layer shader mixes back in after ambient darkening. Both are optional --
## with either missing, tiles simply darken like everything else.
const EMISSION_ATLAS := "res://assets/tiles/terrain_emission.png"
const EMISSION_SHADER := "res://assets/shaders/tile_emission.gdshader"

## The generated tile stacked under every raised cell, one per level, so a
## hill has sides instead of floating diamonds. Not a legend tile: maps never
## place it, elevation data does.
const CLIFF_TILE := "cliff"

signal map_loaded(map: MapData)

## Level-0 ground tiles, drawn flat under everything, exactly as before
## elevation existed. A flat map uses only this and `object_layer`.
var ground_layer: TileMapLayer
## Level-0 object tiles (walls, furniture, trees), y-sorted with the actors.
var object_layer: TileMapLayer
## Actors, interactables and every raised tile layer share this node so
## y-sorting orders them all together.
var sorted: Node2D

var current: MapData = null

## One TileMapLayer per elevation level k = 0..max, rebuilt per map:
## the ground tiles of the cells *at* level k (k >= 1), plus the cliff band
## between level k and k+1 of every cell raised *above* k. Each is shifted up
## k levels on screen but keeps its y-sort at the flat plane, so a raised
## tile occludes exactly what a solid block standing on its flat cell would.
var _terrain_layers: Array[TileMapLayer] = []
## Object tiles of cells at level k, for k >= 1 ([0] stays null; that level
## is `object_layer`). Same lift, but sorted at the cell centre like every
## other object.
var _object_layers: Array[TileMapLayer] = []

var _tileset: TileSet = null
var _emission_material: ShaderMaterial = null
var _emission_checked := false


func _ready() -> void:
	sorted = Node2D.new()
	sorted.name = "Sorted"
	sorted.y_sort_enabled = true
	add_child(sorted)

	ground_layer = _make_layer("Ground", false)
	add_child(ground_layer)
	move_child(ground_layer, 0)

	object_layer = _make_layer("Objects", true)
	sorted.add_child(object_layer)


func _make_layer(layer_name: String, y_sorted: bool) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = _get_tileset()
	layer.y_sort_enabled = y_sorted
	layer.collision_enabled = true
	layer.material = _get_emission_material()
	return layer


## One shared material puts the emission atlas on every tile layer; per-cell
## behaviour falls out of the UVs, so no tile is ever special-cased here.
func _get_emission_material() -> ShaderMaterial:
	if _emission_checked:
		return _emission_material
	_emission_checked = true
	if not ResourceLoader.exists(EMISSION_ATLAS) or not ResourceLoader.exists(EMISSION_SHADER):
		return null
	_emission_material = ShaderMaterial.new()
	_emission_material.shader = load(EMISSION_SHADER)
	_emission_material.set_shader_parameter("emission_atlas", load(EMISSION_ATLAS))
	return _emission_material


func _get_tileset() -> TileSet:
	if _tileset == null:
		if not ResourceLoader.exists(TILESET_PATH):
			push_error("Missing %s -- run tools/build_tileset.gd" % TILESET_PATH)
			return null
		_tileset = load(TILESET_PATH)
	return _tileset


## Replaces whatever is loaded. Returns the MapData so callers can position the
## player; check `map.validate()` if you need to know it was sound.
func load_map(map_id: String) -> MapData:
	var map := MapData.load_map(map_id)
	if not map.parse_errors.is_empty():
		push_error("Cannot load map '%s': %s" % [map_id, ", ".join(map.parse_errors)])
		return map

	clear()
	current = map
	_make_elevation_layers(map.max_elevation())
	_paint(map)
	_spawn_entities(map)
	map_loaded.emit(map)
	return map


func clear() -> void:
	current = null
	if ground_layer != null:
		ground_layer.clear()
	if object_layer != null:
		object_layer.clear()
	_terrain_layers.clear()
	_object_layers.clear()
	if sorted != null:
		for child: Node in sorted.get_children():
			if child == object_layer:
				continue
			child.queue_free()
			sorted.remove_child(child)


## Build the per-level layers a map with raised terrain needs. A flat map
## builds none, so it costs exactly what it cost before elevation existed.
##
## Every layer keeps its y-sort key on the *flat* plane (y_sort_origin gives
## back what position takes away), because a raised cell's depth is still the
## depth of the ground it grew from. Terrain sorts half a grid step behind
## the cell centre: in front of any actor standing behind the cell, behind
## any actor standing on it -- the same "sort by ground contact" contract the
## tiles already obey, extended upward.
func _make_elevation_layers(top_level: int) -> void:
	if top_level <= 0:
		return
	var lift := int(Iso.elevation_height())
	var half := int(Iso.elevation_height() / 2.0)
	for level: int in top_level + 1:
		var terrain := _make_layer("Terrain%d" % level, true)
		terrain.collision_enabled = false
		terrain.position = Vector2(0, -level * lift)
		terrain.y_sort_origin = level * lift - half
		sorted.add_child(terrain)
		_terrain_layers.append(terrain)
	_object_layers.append(null)  # level 0 is object_layer
	for level: int in range(1, top_level + 1):
		var objects := _make_layer("Objects%d" % level, true)
		objects.collision_enabled = false
		objects.position = Vector2(0, -level * lift)
		objects.y_sort_origin = level * lift
		sorted.add_child(objects)
		_object_layers.append(objects)


func _paint(map: MapData) -> void:
	var cliff := TileRegistry.atlas_coords(CLIFF_TILE)
	for y: int in map.height:
		for x: int in map.width:
			var cell := Vector2i(x, y)
			var level := map.elevation_at(cell)
			_set_cell(_ground_target(level), cell, map.tile_at("ground", cell), map)
			_set_cell(_object_target(level), cell, map.tile_at("objects", cell), map)
			# The exposed hillside: one cliff band per level below the cell,
			# all the way down. Bands a neighbour's ground overlaps are simply
			# painted over by it -- the y-sort keys already order that.
			for band: int in level:
				_terrain_layers[band].set_cell(cell, 0, cliff)


func _ground_target(level: int) -> TileMapLayer:
	return ground_layer if level == 0 else _terrain_layers[level]


func _object_target(level: int) -> TileMapLayer:
	return object_layer if level == 0 else _object_layers[level]


func _set_cell(layer: TileMapLayer, cell: Vector2i, tile_name: String, map: MapData) -> void:
	if tile_name.is_empty():
		return
	var coords := TileRegistry.atlas_coords(tile_name)
	if coords == Vector2i(-1, -1):
		push_warning("Map '%s' uses unknown tile '%s' at %s" % [map.id, tile_name, cell])
		return
	layer.set_cell(cell, 0, coords)


## The sorted terrain layer for one elevation level, or null on a flat map.
## Level k holds the ground of cells at level k plus the cliff band k of
## every cell raised above it -- so on a hilly map, terrain_layer(0) is the
## lowest ring of cliff faces (flat ground stays in `ground_layer`). Tests
## use this to assert a hill really was painted at height.
func terrain_layer(level: int) -> TileMapLayer:
	if level >= 0 and level < _terrain_layers.size():
		return _terrain_layers[level]
	return null


## The object layer for one elevation level, or null.
func object_layer_at(level: int) -> TileMapLayer:
	if level == 0:
		return object_layer
	if level < _object_layers.size():
		return _object_layers[level]
	return null


func _spawn_entities(map: MapData) -> void:
	for entry: Dictionary in map.npcs:
		var npc_id := String(entry.get("npc", ""))
		var def := Npc.load_def(npc_id)
		if def.is_empty():
			push_error("Map '%s' places unknown npc '%s'" % [map.id, npc_id])
			continue
		var scene: PackedScene = NPC_SCENE
		var custom := String(def.get("script", ""))
		var npc: Npc = scene.instantiate()
		if not custom.is_empty() and ResourceLoader.exists(custom):
			npc.set_script(load(custom))
		npc.configure(npc_id, def, entry.get("at", Vector2i.ZERO), String(entry.get("facing", "down")))
		# Bodies live on the flat plane whatever their elevation; the NPC
		# reads the map to lift its sprite and to respect cliffs while
		# wandering. See MapData.flat_world_position for why.
		npc.map = map
		npc.position = map.flat_world_position(entry.get("at", Vector2i.ZERO))
		sorted.add_child(npc)

	for entry: Dictionary in map.signs:
		var sign_node := MapSign.new()
		sign_node.name = "Sign%s" % entry.get("at", Vector2i.ZERO)
		sign_node.collision_layer = 8   # interactable
		sign_node.collision_mask = 0
		sign_node.position = map.flat_world_position(entry.get("at", Vector2i.ZERO))
		var shape := CollisionShape2D.new()
		shape.shape = Iso.diamond_shape()
		sign_node.add_child(shape)
		sign_node.configure(String(entry.get("text", "")))
		sorted.add_child(sign_node)

	for entry: Dictionary in map.portals:
		var portal := Portal.new()
		portal.name = "Portal_%s" % entry.get("to", "?")
		portal.collision_layer = 8      # interactable
		portal.collision_mask = 2       # detects the player body
		portal.monitoring = true
		portal.position = map.flat_world_position(entry.get("at", Vector2i.ZERO))
		var shape := CollisionShape2D.new()
		# Slightly inset so you have to actually step onto the tile.
		shape.shape = Iso.diamond_shape(0.78)
		portal.add_child(shape)
		portal.configure(
			String(entry.get("to", "")),
			String(entry.get("spawn", "start")),
			String(entry.get("prompt", "")),
			bool(entry.get("interact", false))
		)
		sorted.add_child(portal)


## Where the player's body should stand when arriving at this map -- on the
## flat plane, like every actor; the sprite lift handles the height.
func spawn_position(spawn_id: String) -> Vector2:
	if current == null:
		return Vector2.ZERO
	var cell: Vector2i = current.spawns.get(spawn_id, current.primary_spawn())
	return current.flat_world_position(cell)
