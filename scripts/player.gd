## The player character.
##
## Free 8-direction movement against the tileset's baked collision, plus an
## "Interactor" area held one tile ahead so pressing interact talks to whatever
## you are facing.
class_name Player
extends CharacterBody2D

const SPEED := 68.0
const REACH := 11.0

signal interacted(target: Node)

@onready var sprite: ActorSprite = $Sprite
@onready var interactor: Area2D = $Interactor

var input_locked := false


func _physics_process(_delta: float) -> void:
	var dir := Vector2.ZERO
	if not input_locked and not Dialogue.is_active() and not Router.is_travelling():
		dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")

	velocity = dir * SPEED
	move_and_slide()

	sprite.moving = dir != Vector2.ZERO
	if dir != Vector2.ZERO:
		sprite.facing = _facing_for(dir)
	interactor.position = _facing_vector() * REACH


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return
	if Router.is_travelling():
		return
	if Dialogue.is_active():
		Dialogue.advance()
		get_viewport().set_input_as_handled()
		return
	var target := find_interactable()
	if target != null:
		target.interact(self)
		interacted.emit(target)
		get_viewport().set_input_as_handled()


## Nearest thing the player is facing that can be talked to, or null.
func find_interactable() -> Node:
	var best: Node = null
	var best_distance := INF
	for area: Area2D in interactor.get_overlapping_areas():
		# Signs and portals are Area2Ds built in code, so they carry interact()
		# themselves and have no owner. An NPC's area is a child of an
		# instantiated scene, so its owner is the NPC. Check both.
		var node: Node = area
		if not node.has_method("interact"):
			node = area.owner if area.owner != null else area.get_parent()
		if node == null or not node.has_method("interact"):
			continue
		var d: float = global_position.distance_to(area.global_position)
		if d < best_distance:
			best_distance = d
			best = node
	return best


func facing() -> String:
	return sprite.facing


func face(direction: String) -> void:
	sprite.facing = direction
	interactor.position = _facing_vector() * REACH


func _facing_for(dir: Vector2) -> String:
	if absf(dir.x) > absf(dir.y):
		return "right" if dir.x > 0.0 else "left"
	return "down" if dir.y > 0.0 else "up"


func _facing_vector() -> Vector2:
	match sprite.facing:
		"left": return Vector2.LEFT
		"right": return Vector2.RIGHT
		"up": return Vector2.UP
		_: return Vector2.DOWN
