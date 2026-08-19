## The player character.
##
## Free 8-direction movement against the tileset's baked collision, plus an
## "Interactor" area held one tile ahead so pressing interact talks to whatever
## you are facing.
##
## The movement keys are **grid** axes, not screen axes: `move_right` is grid
## +x, which runs down-right across the diamonds. That is what keeps one key
## equal to one direction the map understands -- walkability, reachability and
## NPC facings are all 4-connected on the grid -- and pressing two keys still
## gives you the screen-aligned diagonals in between.
class_name Player
extends CharacterBody2D

## Tiles per second. Screen speed follows from the projection, so walking the
## flat axis of a diamond covers pixels faster without covering more ground.
const SPEED := 4.25
## How far ahead of the player the interactor sits, in tiles.
const REACH := 0.72

signal interacted(target: Node)

@onready var sprite: ActorSprite = $Sprite
@onready var interactor: Area2D = $Interactor

var input_locked := false

## The map being walked on, set by World on every map change. The body moves
## on the flat plane; the map says which cell edges are cliffs and how high
## the ground under the feet is.
var map: MapData = null:
	set(value):
		map = value
		_snap_lift = true

var _snap_lift := true


func _physics_process(delta: float) -> void:
	var step := Vector2.ZERO
	if not input_locked and not Dialogue.is_active() and not Router.is_travelling():
		step = Input.get_vector("move_left", "move_right", "move_up", "move_down")

	# `step` is in tiles; the projection turns it into pixels. Doing it in this
	# order is what makes every direction cost the same amount of ground.
	velocity = Iso.grid_vector(step) * SPEED

	# Solid tiles at level 0 push back through physics; cliffs and everything
	# on raised ground have no collision shapes and are enforced by the world
	# rule instead. One rule, MapData.can_move, decides both this and what the
	# reachability validator accepts.
	var before := global_position
	if map != null and delta > 0.0:
		velocity = map.allowed_motion(global_position, velocity * delta) / delta
	move_and_slide()
	if map != null and not map.can_step(Iso.cell_at(before), Iso.cell_at(global_position)):
		# Physics sliding nudged the feet across an edge the rule forbids.
		global_position = before

	_update_lift()
	sprite.moving = step != Vector2.ZERO
	if step != Vector2.ZERO:
		sprite.facing = ActorSprite.facing_for(step)
	interactor.position = Iso.grid_vector(_facing_step()) * REACH


## Put the player on a cell, feet and drawing together.
##
## A teleport is not a walk: spawning, changing map, a cutscene or a
## screenshot must land at the new terrain height immediately, where walking
## onto a hill eases the sprite up over a few frames.
func place_on(cell: Vector2i) -> void:
	if map != null:
		global_position = map.flat_world_position(cell)
	_snap_lift = true
	_update_lift()


## Keep the drawing on top of the terrain the feet are standing on.
func _update_lift() -> void:
	if map == null:
		return
	sprite.ground_lift = map.elevation_at(Iso.cell_at(global_position)) * Iso.ELEVATION_HEIGHT
	if _snap_lift:
		sprite.snap_lift()
		_snap_lift = false


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
	interactor.position = Iso.grid_vector(_facing_step()) * REACH


## The grid step the player is facing -- one cell north, south, east or west.
## Project it to get anywhere on screen.
func _facing_step() -> Vector2:
	match sprite.facing:
		"left": return Vector2.LEFT
		"right": return Vector2.RIGHT
		"up": return Vector2.UP
		_: return Vector2.DOWN
