## Hosts the live game: one map at a time, the player, the camera, and the
## planes everything is composed on.
##
## World is the only place the five subsystems meet, and it meets them in one
## direction: it hands each of them the freshly loaded MapData and none of
## them knows about the others.
##
## ```
##   enter(map_id)
##     |
##     +-> MapLoader     tiles, NPCs, signs, portals   (the gameplay plane)
##     +-> ScenePlanes   scenery in the four other planes
##     +-> GameCamera    framing: FOLLOW / ROOM_LOCKED / FIXED
##     +-> WorldLighting ambient, sun, tile-driven point lights
##     +-> WorldFx       fog, grading, quantization
## ```
class_name World
extends Node2D

const DEFAULT_MAP := "port_azure_town"

@onready var planes: ScenePlanes = $Planes
@onready var loader: MapLoader = $Planes/Playable/MapLoader
@onready var lighting: WorldLighting = $Lighting
@onready var fx: WorldFx = $Fx
@onready var player: Player = $Planes/Playable/Player
@onready var camera: GameCamera = $Planes/Playable/Player/Camera

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
	planes.apply_map(map)
	camera.fit_to_map(map)
	lighting.apply_map(map)
	fx.apply_map(map)
	# What the camera sees past the corners of a diamond-shaped map.
	RenderingServer.set_default_clear_color(map.background)
	return map


func _on_map_requested(map_id: String, spawn_id: String) -> void:
	enter(map_id, spawn_id)
