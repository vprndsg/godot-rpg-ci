## Hosts the live game: one map at a time, the player, and the camera.
class_name World
extends Node2D

const DEFAULT_MAP := "port_azure_town"

@onready var loader: MapLoader = $MapLoader
@onready var player: Player = $Player
@onready var camera: Camera2D = $Player/Camera

signal ready_for_play


func _ready() -> void:
	Router.map_requested.connect(_on_map_requested)
	var start_map := GameState.current_map if not GameState.current_map.is_empty() else DEFAULT_MAP
	enter(start_map, GameState.current_spawn)
	ready_for_play.emit()


## Load a map and drop the player on one of its spawn points.
func enter(map_id: String, spawn_id: String = "start") -> MapData:
	var map := loader.load_map(map_id)
	if not map.parse_errors.is_empty():
		return map
	GameState.current_map = map_id
	GameState.current_spawn = spawn_id
	player.global_position = loader.spawn_position(spawn_id)
	_fit_camera(map)
	return map


func _on_map_requested(map_id: String, spawn_id: String) -> void:
	enter(map_id, spawn_id)


## Keep the camera inside the map so small interiors do not show the void.
func _fit_camera(map: MapData) -> void:
	var ts := TileRegistry.tile_size()
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = map.width * ts
	camera.limit_bottom = map.height * ts

	var view := get_viewport_rect().size
	# A map narrower than the screen would jitter against its own limits;
	# centre it instead of clamping.
	camera.position_smoothing_enabled = map.width * ts > view.x and map.height * ts > view.y
