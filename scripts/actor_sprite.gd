## Draws one actor: the right clip, the right direction, the right frame.
##
## Everything about *what* to draw comes from `scripts/actor_manifest.gd` --
## frame size, anchor, authored directions, clip rows, frame counts, frame
## rates. This node only advances time and slices the sheet, so a character
## with eight directions and a six-frame trot needs no code that these four
## legacy townspeople did not already need.
##
## Two rules it will not bend:
##
## - **The origin is the feet.** The node's own position is the patch of
##   ground the actor stands on, whatever the picture is doing above it. That
##   is what makes y-sorting against the tiles correct, and it is why a
##   300-pixel character sorts exactly like a 48-pixel one.
## - **Elevation is drawn, not simulated.** `ground_lift` moves the picture up
##   the hill; the body underneath never leaves the flat plane. See
##   MapData.flat_world_position.
class_name ActorSprite
extends Sprite2D

## How fast the sprite eases toward its ground_lift, in pixels per second per
## elevation level -- so the climb takes the same time however tall a level
## is. Crossing onto a raised cell moves the feet up a whole level at once;
## easing over a few frames turns that pop into a climb.
const LIFT_LEVELS_PER_SECOND := 3.75

## Emitted when a non-looping clip reaches its last frame. A cutscene can
## await this; ordinary play ignores it.
signal clip_finished(clip: String)

@export var actor: String = "player":
	set(value):
		actor = value
		_resolve()

## One of ActorManifest.DIRECTIONS. Set it to anything; the manifest snaps it
## to the nearest direction the current clip actually has.
var facing: String = "down":
	set(value):
		if value == facing:
			return
		facing = value
		_redraw()

## The convenience the movement code uses: walking or standing. Anything more
## specific goes through play().
var moving: bool = false:
	set(value):
		if value == moving:
			return
		moving = value
		if _action.is_empty():
			_resolve()

## Pixels the drawing is lifted above the actor's own position. The body stays
## on the flat plane -- position, physics and y-sorting never move -- and
## elevation is applied here, on the way to the screen, exactly as the raised
## tile layers are shifted up. Terrain elevation sets this today; a jump arc
## can add to it later without the world model noticing.
var ground_lift := 0.0

var _manifest: ActorManifest = null
## A clip explicitly requested with play(), which overrides walk/idle until
## it is cleared or a non-looping one ends.
var _action := ""
var _resolved: Dictionary = {}
var _time := 0.0
var _frame := 0


# --------------------------------------------------------------------------
# static access, for callers that have no node yet (validators, tests, tools)
# --------------------------------------------------------------------------

static func manifest() -> ActorManifest:
	return ActorManifest.load_default()


static func has_actor(actor_name: String) -> bool:
	return manifest().has_actor(actor_name)


static func actor_names() -> Array:
	return manifest().actor_names()


static func frame_size(actor_name: String) -> Vector2i:
	return manifest().frame_size(actor_name)


## Which direction a grid-space step faces, out of the eight. Callers that
## know an actor pass its authored set so the answer is one it can draw.
static func facing_for(step: Vector2, available: PackedStringArray = ActorManifest.DIRECTIONS) -> String:
	return ActorManifest.facing_for(step, available)


func _ready() -> void:
	region_enabled = true
	centered = true
	_resolve()


func _process(delta: float) -> void:
	var lift_speed := LIFT_LEVELS_PER_SECOND * Iso.elevation_height()
	position.y = move_toward(position.y, -ground_lift, lift_speed * delta)
	_advance(delta)


## The directions this actor's sheet actually has. Movement code asks so it
## never sets a facing the character cannot draw.
func available_directions() -> PackedStringArray:
	return _manifest.directions(actor) if _manifest != null else ActorManifest.DIRECTIONS


## The clip currently on screen -- what got resolved, not what was asked for.
func current_clip() -> String:
	return String(_resolved.get("clip", ""))


## Play a named clip (`run`, `sniff`, `sit`, anything the manifest declares).
## An actor without it falls back rather than freezing; a non-looping clip
## clears itself when it ends.
func play(clip: String) -> void:
	_action = clip
	_time = 0.0
	_frame = 0
	_resolve()


## Back to the ordinary walk/idle pair.
func stop_action() -> void:
	if _action.is_empty():
		return
	_action = ""
	_time = 0.0
	_frame = 0
	_resolve()


## Jump straight to the current lift with no easing -- for spawns and map
## changes, where easing would read as the actor falling into place.
func snap_lift() -> void:
	position.y = -ground_lift


func _wanted_clip() -> String:
	if not _action.is_empty():
		return _action
	return "walk" if moving else "idle"


## Re-read the manifest for the current actor and clip. Called whenever any of
## the three inputs (actor, clip, moving) changes -- never per frame.
func _resolve() -> void:
	if _manifest == null:
		_manifest = ActorManifest.load_default()
	if not _manifest.has_actor(actor):
		push_warning("Unknown actor sprite '%s'; falling back to 'player'" % actor)
		if not _manifest.has_actor("player"):
			_resolved = {}
			return
		actor = "player"
		return
	var next := _manifest.resolve_clip(actor, _wanted_clip())
	if next.get("clip", "") != _resolved.get("clip", "") or next.get("texture", "") != _resolved.get("texture", ""):
		_time = 0.0
		_frame = 0
	_resolved = next
	_apply_sheet()
	_redraw()


## Bind the sheet and put the node's origin on the actor's feet. Both come
## from the manifest, so two characters on one texture may still have
## different frame sizes and different foot points.
func _apply_sheet() -> void:
	if _resolved.is_empty():
		return
	var path := String(_resolved["texture"])
	if not path.is_empty() and ResourceLoader.exists(path):
		var wanted: Texture2D = load(path)
		if texture != wanted:
			texture = wanted
	var size: Vector2i = _resolved["frame_size"]
	var foot: Vector2i = _resolved["anchor"]
	offset = Vector2(size.x / 2.0 - foot.x, size.y / 2.0 - foot.y)


func _advance(delta: float) -> void:
	if _resolved.is_empty():
		return
	var frames := int(_resolved["frames"])
	var fps := float(_resolved["fps"])
	if frames <= 1 or fps <= 0.0:
		if _frame != 0:
			_frame = 0
			_redraw()
		return
	_time += delta
	var step := int(_time * fps)
	if bool(_resolved["loop"]):
		step %= frames
	elif step >= frames:
		# A one-shot holds its last frame, then hands control back.
		if _frame != frames - 1:
			_frame = frames - 1
			_redraw()
		var finished := String(_resolved["clip"])
		if not _action.is_empty():
			stop_action()
		clip_finished.emit(finished)
		return
	if step != _frame:
		_frame = step
		_redraw()


func _redraw() -> void:
	if _resolved.is_empty() or texture == null:
		return
	region_rect = ActorManifest.frame_region(_resolved, facing, _frame)
