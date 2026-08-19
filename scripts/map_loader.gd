## Turns a MapData into live nodes: tile layers, NPCs, signs and portals.
##
## Nothing here is authored in the editor. Rebuilding a map is
## `load_map("port_azure_inn_ground")`, which is also exactly what the runtime
## tests do -- so a map that crashes on load fails CI.
class_name MapLoader
extends Node2D

const TILESET_PATH := "res://assets/tiles/terrain.tres"
const NPC_SCENE := preload("res://scenes/npc.tscn")

signal map_loaded(map: MapData)

## Ground tiles, drawn under everything.
var ground_layer: TileMapLayer
## Object tiles (walls, furniture, trees), y-sorted with the actors.
var object_layer: TileMapLayer
## Actors and interactables share this node so y-sorting orders them together.
var sorted: Node2D

var current: MapData = null

var _tileset: TileSet = null


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
	return layer


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
	_paint(ground_layer, map, "ground")
	_paint(object_layer, map, "objects")
	_spawn_entities(map)
	map_loaded.emit(map)
	return map


func clear() -> void:
	current = null
	if ground_layer != null:
		ground_layer.clear()
	if object_layer != null:
		object_layer.clear()
	if sorted != null:
		for child: Node in sorted.get_children():
			if child == object_layer:
				continue
			child.queue_free()
			sorted.remove_child(child)


func _paint(layer: TileMapLayer, map: MapData, layer_name: String) -> void:
	for y: int in map.height:
		for x: int in map.width:
			var cell := Vector2i(x, y)
			var tile_name := map.tile_at(layer_name, cell)
			if tile_name.is_empty():
				continue
			var coords := TileRegistry.atlas_coords(tile_name)
			if coords == Vector2i(-1, -1):
				push_warning("Map '%s' uses unknown tile '%s' at %s" % [map.id, tile_name, cell])
				continue
			layer.set_cell(cell, 0, coords)


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
		npc.position = map.world_position(entry.get("at", Vector2i.ZERO))
		sorted.add_child(npc)

	for entry: Dictionary in map.signs:
		var sign_node := MapSign.new()
		sign_node.name = "Sign%s" % entry.get("at", Vector2i.ZERO)
		sign_node.collision_layer = 8   # interactable
		sign_node.collision_mask = 0
		sign_node.position = map.world_position(entry.get("at", Vector2i.ZERO))
		var shape := CollisionShape2D.new()
		shape.shape = _footprint_shape()
		sign_node.add_child(shape)
		sign_node.configure(String(entry.get("text", "")))
		sorted.add_child(sign_node)

	for entry: Dictionary in map.portals:
		var portal := Portal.new()
		portal.name = "Portal_%s" % entry.get("to", "?")
		portal.collision_layer = 8      # interactable
		portal.collision_mask = 2       # detects the player body
		portal.monitoring = true
		portal.position = map.world_position(entry.get("at", Vector2i.ZERO))
		var shape := CollisionShape2D.new()
		# Slightly inset so you have to actually step onto the tile.
		shape.shape = _footprint_shape(0.78)
		portal.add_child(shape)
		portal.configure(
			String(entry.get("to", "")),
			String(entry.get("spawn", "start")),
			String(entry.get("prompt", "")),
			bool(entry.get("interact", false))
		)
		sorted.add_child(portal)


## One cell's worth of ground, as a shape. Signs and portals occupy a tile, and
## a tile is a diamond -- a square here would poke into the four neighbours.
func _footprint_shape(shrink: float = 1.0) -> ConvexPolygonShape2D:
	var shape := ConvexPolygonShape2D.new()
	shape.points = Iso.diamond(shrink)
	return shape


## Where the player should stand when arriving at this map.
func spawn_position(spawn_id: String) -> Vector2:
	if current == null:
		return Vector2.ZERO
	var cell: Vector2i = current.spawns.get(spawn_id, current.primary_spawn())
	return current.world_position(cell)
