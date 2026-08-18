## Entry scene: a title card, then the world.
##
## The title also gives web builds the user gesture browsers require before
## audio can start, so do not remove it without a replacement.
extends Node

const WORLD_SCENE := preload("res://scenes/world.tscn")

@onready var title: CanvasLayer = $Title
@onready var continue_label: Label = $Title/Center/Box/ContinueHint

var _world: World = null
var _started := false


func _ready() -> void:
	continue_label.visible = GameState.has_save()
	if DisplayServer.get_name() == "headless":
		# CI boots straight into the world; nobody is there to press a key.
		# (OS.has_feature("headless") is not set by --headless, so check the
		# display server instead.)
		start_game()


func _unhandled_input(event: InputEvent) -> void:
	if _started:
		if event.is_action_pressed("quick_save"):
			GameState.save_game()
			Dialogue.show_line("", "Saved.")
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		start_game()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("continue_game") and GameState.has_save():
		GameState.load_game()
		start_game()
		get_viewport().set_input_as_handled()


func start_game() -> World:
	if _started:
		return _world
	_started = true
	title.visible = false
	_world = WORLD_SCENE.instantiate()
	add_child(_world)
	return _world


func world() -> World:
	return _world
