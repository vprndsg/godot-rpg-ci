## Autoload: owns map changes and the fade between them.
##
## Everything that wants to move the player to another map calls
## Router.travel(map_id, spawn_id). The World scene listens for `map_requested`
## so no caller needs a reference to it.
extends Node

signal map_requested(map_id: String, spawn_id: String)
signal map_changed(map_id: String)

const FADE_TIME := 0.18

var _fade: ColorRect
var _busy := false


func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	layer.name = "FadeLayer"
	add_child(layer)

	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)


func travel(map_id: String, spawn_id: String = "start") -> void:
	if _busy:
		return
	_busy = true
	await _fade_to(1.0)
	GameState.current_map = map_id
	GameState.current_spawn = spawn_id
	map_requested.emit(map_id, spawn_id)
	# One frame so the World has actually swapped the map in before we reveal it.
	await get_tree().process_frame
	map_changed.emit(map_id)
	await _fade_to(0.0)
	_busy = false


func is_travelling() -> bool:
	return _busy


func _fade_to(alpha: float) -> void:
	if _fade == null:
		return
	var tween := create_tween()
	tween.tween_property(_fade, "color:a", alpha, FADE_TIME)
	await tween.finished
