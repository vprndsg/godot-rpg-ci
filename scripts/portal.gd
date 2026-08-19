## A doorway, staircase or map edge. Stepping onto it travels to another map.
##
## Portals trigger on body entry rather than on the interact key so that
## doorways feel like doorways; a portal that also wants a prompt sets
## `prompt` and is interacted with instead.
class_name Portal
extends Area2D

var target_map: String = ""
var target_spawn: String = "start"
var prompt: String = ""
var requires_interact := false


## Wired here rather than in configure(): entering the tree happens exactly
## once, where configure() is an ordinary setter a caller may reasonably call
## twice -- and a second connection would travel twice on one footstep.
func _ready() -> void:
	body_entered.connect(_on_body_entered)


func configure(map_id: String, spawn_id: String, portal_prompt: String, interact_only: bool) -> void:
	target_map = map_id
	target_spawn = spawn_id
	prompt = portal_prompt
	requires_interact = interact_only


func _on_body_entered(body: Node2D) -> void:
	if requires_interact or not (body is Player):
		return
	_travel()


func interact(_player: Player) -> void:
	if not prompt.is_empty():
		Dialogue.show_line("", prompt)
	_travel()


func _travel() -> void:
	if Router.is_travelling():
		return
	Router.travel(target_map, target_spawn)
