## A character defined by data/npcs/<id>.json and placed by a map.
##
## Behaviour is data-driven so adding a villager is a JSON file plus one line
## in a map, with no scene authoring. `script` in the definition can point at a
## GDScript that extends this one when an NPC needs real logic.
class_name Npc
extends CharacterBody2D

const DEFS_DIR := "res://data/npcs"
const WANDER_SPEED := 22.0

@onready var sprite: ActorSprite = $Sprite

var npc_id: String = ""
var display_name: String = ""
var dialogue_id: String = ""
var behavior: String = "idle"
var home_cell: Vector2i = Vector2i.ZERO
var wander_radius: int = 0

var _rng := RandomNumberGenerator.new()
var _target: Vector2 = Vector2.ZERO
var _wait := 0.0


static func def_path(id: String) -> String:
	return "%s/%s.json" % [DEFS_DIR, id]


static func def_exists(id: String) -> bool:
	return FileAccess.file_exists(def_path(id))


static func all_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(DEFS_DIR)
	if dir == null:
		return out
	for file: String in dir.get_files():
		var name := file.trim_suffix(".remap")
		if name.ends_with(".json"):
			out.append(name.trim_suffix(".json"))
	out.sort()
	return out


static func load_def(id: String) -> Dictionary:
	var path := def_path(id)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func configure(id: String, def: Dictionary, cell: Vector2i, facing: String) -> void:
	npc_id = id
	name = id.to_pascal_case()
	display_name = String(def.get("display_name", id.capitalize()))
	dialogue_id = String(def.get("dialogue", id))
	behavior = String(def.get("behavior", "idle"))
	wander_radius = int(def.get("wander_radius", 1))
	home_cell = cell
	_rng.seed = hash(id)
	# Set before _ready so the first frame already draws the right sprite.
	set_meta("actor", String(def.get("sprite", "villager")))
	set_meta("facing", facing)


func _ready() -> void:
	sprite.actor = String(get_meta("actor", "villager"))
	sprite.facing = String(get_meta("facing", "down"))
	_target = global_position
	add_to_group("npcs")


func _physics_process(delta: float) -> void:
	if behavior != "wander" or Dialogue.is_active():
		velocity = Vector2.ZERO
		sprite.moving = false
		return

	if _wait > 0.0:
		_wait -= delta
		velocity = Vector2.ZERO
		sprite.moving = false
		return

	if global_position.distance_to(_target) < 2.0:
		_pick_target()
		_wait = _rng.randf_range(0.8, 2.6)
		return

	var dir := global_position.direction_to(_target)
	velocity = dir * WANDER_SPEED
	move_and_slide()
	sprite.moving = true
	sprite.facing = "right" if absf(dir.x) > absf(dir.y) and dir.x > 0.0 \
		else ("left" if absf(dir.x) > absf(dir.y) else ("down" if dir.y > 0.0 else "up"))


func _pick_target() -> void:
	var ts := TileRegistry.tile_size()
	var offset := Vector2(
		_rng.randi_range(-wander_radius, wander_radius),
		_rng.randi_range(-wander_radius, wander_radius)
	) * float(ts)
	_target = Vector2(home_cell.x * ts + ts / 2.0, home_cell.y * ts + ts / 2.0) + offset


## Called by Player when the player presses interact while facing this NPC.
func interact(player: Player) -> void:
	_face_toward(player.global_position)
	if not Dialogue.start(dialogue_id):
		push_warning("NPC '%s' has no usable dialogue '%s'" % [npc_id, dialogue_id])


func _face_toward(point: Vector2) -> void:
	var d := global_position.direction_to(point)
	if absf(d.x) > absf(d.y):
		sprite.facing = "right" if d.x > 0.0 else "left"
	else:
		sprite.facing = "down" if d.y > 0.0 else "up"
