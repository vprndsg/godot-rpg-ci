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
	# What the camera sees past the corners of a diamond-shaped map.
	RenderingServer.set_default_clear_color(map.background)
	return map


func _on_map_requested(map_id: String, spawn_id: String) -> void:
	enter(map_id, spawn_id)


## Keep the camera inside the map so small interiors do not show the void.
func _fit_camera(map: MapData) -> void:
	# A diamond grid is not the rectangle its cell counts suggest: it leans
	# left as it descends, so the far corner of a tall map sits at negative x.
	var bounds := Iso.grid_bounds(Vector2i(map.width, map.height))
	camera.limit_left = int(bounds.position.x)
	# Tall tiles draw above the cell they stand on, so give the back row its
	# headroom rather than slicing the tops off the far wall.
	camera.limit_top = int(bounds.position.y) - TileRegistry.footprint_top()
	camera.limit_right = int(bounds.end.x)
	camera.limit_bottom = int(bounds.end.y)

	var view := get_viewport_rect().size
	# A map narrower than the screen would jitter against its own limits;
	# centre it instead of clamping.
	camera.position_smoothing_enabled = bounds.size.x > view.x and bounds.size.y > view.y
