## Sprite2D that reads assets/sprites/actors.png through its manifest.
##
## The sheet is one long column of 16x24 frames: four frames per direction,
## four directions (down, left, right, up) per actor. Slicing it with
## `region_rect` avoids hand-authoring a SpriteFrames resource for every new
## character -- adding an actor means adding it to tools/gen_art.py and naming
## it here.
class_name ActorSprite
extends Sprite2D

const MANIFEST_PATH := "res://assets/sprites/actors.json"
const WALK_FPS := 7.0

static var _manifest: Dictionary = {}

@export var actor: String = "player":
	set(value):
		actor = value
		_refresh()

var facing: String = "down":
	set(value):
		if value == facing:
			return
		facing = value
		_refresh()

var moving: bool = false

var _time := 0.0
var _frame := 0


static func manifest() -> Dictionary:
	if _manifest.is_empty():
		var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
		if f == null:
			push_error("Missing %s -- run tools/gen_art.py" % MANIFEST_PATH)
			return {}
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Dictionary:
			_manifest = parsed
	return _manifest


static func has_actor(actor_name: String) -> bool:
	return manifest().get("actors", {}).has(actor_name)


static func actor_names() -> Array:
	var out: Array = manifest().get("actors", {}).keys()
	out.sort()
	return out


static func frame_size() -> Vector2i:
	var fs: Array = manifest().get("frame_size", [16, 24])
	return Vector2i(int(fs[0]), int(fs[1]))


func _ready() -> void:
	region_enabled = true
	centered = true
	# Origin sits at the actor's feet-ish, so y-sorting against the object
	# layer orders characters by where they stand, not where their hat is.
	offset = Vector2(0, -frame_size().y / 2.0 + 6)
	_refresh()


func _process(delta: float) -> void:
	if not moving:
		if _frame != 0:
			_frame = 0
			_time = 0.0
			_refresh()
		return
	_time += delta
	var next := int(_time * WALK_FPS) % 4
	if next != _frame:
		_frame = next
		_refresh()


func _refresh() -> void:
	if not is_inside_tree():
		return
	var m := manifest()
	var actors: Dictionary = m.get("actors", {})
	if not actors.has(actor):
		push_warning("Unknown actor sprite '%s'; falling back to 'player'" % actor)
		actor = "player" if actors.has("player") else actor
		if not actors.has(actor):
			return
	var block := int(actors[actor].get("row_block", 0))
	var dirs: Array = m.get("directions", ["down", "left", "right", "up"])
	var dir_index := maxi(0, dirs.find(facing))
	var fs := frame_size()
	region_rect = Rect2(_frame * fs.x, (block * dirs.size() + dir_index) * fs.y, fs.x, fs.y)
