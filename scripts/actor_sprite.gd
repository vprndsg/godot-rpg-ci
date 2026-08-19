## Sprite2D that reads assets/sprites/actors.png through its manifest.
##
## The sheet is one long column of 16x24 frames: four frames per direction,
## four directions (down, left, right, up) per actor. Slicing it with
## `region_rect` avoids hand-authoring a SpriteFrames resource for every new
## character -- adding an actor means adding it to tools/gen_art.py and naming
## it here.
##
## The four direction names are **grid** axes, so on screen they are the four
## diagonals: "down" is grid +y (down-left), "right" is grid +x (down-right),
## "up" is grid -y (up-right) and "left" is grid -x (up-left). Down and right
## therefore face the camera and show a face; up and left show a back.
class_name ActorSprite
extends Sprite2D

const MANIFEST_PATH := "res://assets/sprites/actors.json"
const WALK_FPS := 7.0
## Row of a frame the character's feet stand on. The node's own origin is put
## there, so an actor's position is the patch of ground they occupy and
## y-sorting compares like with like against the tiles.
const FOOT_ROW := 22
## How fast the sprite eases toward its ground_lift, in pixels per second.
## Crossing onto a raised cell moves the feet up a whole level at once; easing
## over a few frames turns that pop into a climb.
const LIFT_SPEED := 60.0

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

## Pixels the drawing is lifted above the actor's own position. The body
## stays on the flat plane -- position, physics and y-sorting never move --
## and elevation is applied here, on the way to the screen, exactly as the
## raised tile layers are shifted up. Terrain elevation sets this today; a
## jump arc can add to it later without the world model noticing.
var ground_lift := 0.0

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


## Which of the four directions a grid-space step faces.
##
## Takes a step in tiles, not pixels: on screen the axes are diagonals, and
## comparing screen x against screen y would pick the wrong one every time.
static func facing_for(step: Vector2) -> String:
	if absf(step.x) > absf(step.y):
		return "right" if step.x > 0.0 else "left"
	return "down" if step.y > 0.0 else "up"


func _ready() -> void:
	region_enabled = true
	centered = true
	# Origin sits at the actor's feet, so y-sorting against the object layer
	# orders characters by where they stand, not by where their hat is.
	offset = Vector2(0, frame_size().y / 2.0 - FOOT_ROW)
	_refresh()


func _process(delta: float) -> void:
	position.y = move_toward(position.y, -ground_lift, LIFT_SPEED * delta)
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


## Jump straight to the current lift with no easing -- for spawns and map
## changes, where easing would read as the actor falling into place.
func snap_lift() -> void:
	position.y = -ground_lift


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
