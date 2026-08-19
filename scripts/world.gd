## Hosts the live game: one map at a time, the player, and the camera.
class_name World
extends Node2D

const DEFAULT_MAP := "port_azure_town"

@onready var loader: MapLoader = $MapLoader
@onready var lighting: WorldLighting = $Lighting
@onready var player: Player = $Player
@onready var camera: GameCamera = $Player/Camera

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
	player.map = map
	player.global_position = loader.spawn_position(spawn_id)
	camera.fit_to_map(map)
	lighting.apply_map(map)
	# What the camera sees past the corners of a diamond-shaped map.
	RenderingServer.set_default_clear_color(map.background)
	return map


func _on_map_requested(map_id: String, spawn_id: String) -> void:
	enter(map_id, spawn_id)
