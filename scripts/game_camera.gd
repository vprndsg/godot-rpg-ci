## The game's one camera, and the four ways it can behave.
##
## The node is a child of the player scene, so FOLLOW costs nothing: the
## transform is already the player's. The other modes detach it (`top_level`)
## and put it where the map asked, which is what lets the player walk through
## a composed frame instead of dragging it around.
##
## | mode | transform | clamped to |
## | --- | --- | --- |
## | `FOLLOW` | rides the player | the whole map |
## | `ROOM_LOCKED` | rides the player inside a room, or holds its centre when the room is smaller than the screen | the room |
## | `FIXED` | an authored point; the player moves through the frame | nothing |
## | `CINEMATIC` | borrowed: whatever the last mode was, plus an `offset` a cutscene drives | unchanged |
##
## A map chooses with a `"camera"` block (`scripts/camera_config.gd`); a map
## that says nothing gets FOLLOW, clamped exactly as before this existed.
##
## CINEMATIC is a *borrow*, not a fifth way to be framed. `focus_on()` takes
## the camera and remembers what it was doing; `release_focus()` gives it back
## to that -- FIXED returns to FIXED, not to FOLLOW. Everything a cutscene
## does happens through `offset`, so the transform underneath is never
## disturbed and there is nothing to restore but the mode.
class_name GameCamera
extends Camera2D

enum Mode { FOLLOW, ROOM_LOCKED, FIXED, CINEMATIC }

## How fast a following camera catches up with the player. Unchanged from the
## value the player scene shipped with.
const FOLLOW_SMOOTHING_SPEED := 8.0

## What the limits become when nothing should clamp -- a FIXED camera's whole
## point is that its framing is exactly what was authored.
const UNCLAMPED := 100000000

signal mode_changed(mode: Mode)

var mode: Mode = Mode.FOLLOW

var _map_bounds := Rect2()
## The map's cells alone, without the headroom the limits add. Whether a map
## is bigger than the screen is a question about the world, not about how far
## past its back row the camera may peek.
var _grid_bounds := Rect2()
var _room_bounds := Rect2()
var _anchor := Vector2.ZERO
var _spec: Dictionary = CameraConfig.defaults()
## What CINEMATIC borrowed from, so release_focus() can hand it back.
var _borrowed_from: Mode = Mode.FOLLOW


## Frame a map: read its camera block, remember its bounds, enter its mode.
## World.enter() calls this on every map change; a map with no camera block
## resolves to FOLLOW over the whole map, which is what every map did before.
func fit_to_map(map: MapData) -> void:
	_spec = map.camera if not map.camera.is_empty() else CameraConfig.defaults()
	# A diamond grid is not the rectangle its cell counts suggest: it leans
	# left as it descends, so the far corner of a tall map sits at negative x.
	_grid_bounds = Iso.grid_bounds(Vector2i(map.width, map.height))
	# Tall tiles draw above the cell they stand on, so give the back row its
	# headroom rather than slicing the tops off the far wall -- and raised
	# terrain lifts everything on it by another level's worth each. Only the
	# top moves: growing position and size together leaves the bottom edge
	# exactly where the ground ends.
	var headroom := TileRegistry.footprint_top() + map.max_elevation() * Iso.elevation_height()
	_map_bounds = _grid_bounds
	_map_bounds.position.y -= headroom
	_map_bounds.size.y += headroom

	var room := CameraConfig.room_of(_spec)
	_room_bounds = Iso.cell_bounds(room) if room != Rect2i() else Rect2()
	_anchor = _resolve_anchor(map)
	zoom = Vector2.ONE * CameraConfig.zoom_of(_spec)
	set_mode(_mode_from_spec())


## Switch modes at runtime -- a cutscene, a room transition, a debug key.
## Re-applies the transform and the limits for the new mode immediately.
func set_mode(next: Mode) -> void:
	if next != Mode.CINEMATIC:
		_borrowed_from = next
	mode = next
	_apply_mode()
	mode_changed.emit(mode)


## The rectangle the camera is currently clamped to, in world pixels. Empty
## when nothing clamps it. Tests and tools ask rather than reading four
## separate limit properties.
func clamp_bounds() -> Rect2:
	match mode:
		Mode.FIXED:
			return Rect2()
		Mode.ROOM_LOCKED:
			return _room_bounds if _room_bounds != Rect2() else _map_bounds
		_:
			return _map_bounds


## Where a FIXED camera has been told to sit, in world pixels.
func anchor() -> Vector2:
	return _anchor


func _mode_from_spec() -> Mode:
	match CameraConfig.mode_of(_spec):
		"room_locked": return Mode.ROOM_LOCKED
		"fixed": return Mode.FIXED
		_: return Mode.FOLLOW


func _resolve_anchor(map: MapData) -> Vector2:
	var position_override := CameraConfig.anchor_position(_spec)
	if position_override != Vector2.INF:
		return position_override + CameraConfig.offset_of(_spec)
	var cell := CameraConfig.anchor_cell(_spec)
	if cell != Vector2i(-1, -1):
		return map.world_position(cell) + CameraConfig.offset_of(_spec)
	if _room_bounds != Rect2():
		return _room_bounds.get_center() + CameraConfig.offset_of(_spec)
	return _map_bounds.get_center() + CameraConfig.offset_of(_spec)


## Put the camera where the current mode says, and clamp it where the current
## mode says. Nothing here runs per frame: a following camera is moved by its
## parent and a detached one does not move at all, so the cost of a mode is
## paid once when it is entered.
func _apply_mode() -> void:
	match mode:
		Mode.CINEMATIC:
			# Borrowed. Whatever transform was in force stays in force; the
			# cutscene drives `offset` on top of it.
			return
		Mode.FIXED:
			_detach(_anchor)
			_clamp_to(Rect2())
		Mode.ROOM_LOCKED:
			var room := clamp_bounds()
			var view := _view_size()
			if room.size.x <= view.x or room.size.y <= view.y:
				# A room narrower than the screen cannot be scrolled without
				# showing what is outside it, so hold its centre instead --
				# the composition is the room, not the player's position in it.
				_detach(room.get_center())
				_clamp_to(Rect2())
			else:
				_attach()
				_clamp_to(room)
		_:
			_attach()
			_clamp_to(_map_bounds)
	_apply_smoothing()


## Ride the player again: the camera is their child, so following is free.
func _attach() -> void:
	if top_level:
		top_level = false
		position = Vector2.ZERO


## Leave the player's transform and hold a world position of our own.
func _detach(world_position: Vector2) -> void:
	top_level = true
	global_position = world_position
	if is_inside_tree():
		reset_smoothing()


func _clamp_to(bounds: Rect2) -> void:
	if bounds == Rect2():
		limit_left = -UNCLAMPED
		limit_top = -UNCLAMPED
		limit_right = UNCLAMPED
		limit_bottom = UNCLAMPED
		return
	limit_left = int(bounds.position.x)
	limit_top = int(bounds.position.y)
	limit_right = int(bounds.end.x)
	limit_bottom = int(bounds.end.y)


func _apply_smoothing() -> void:
	if not CameraConfig.smoothing_of(_spec):
		position_smoothing_enabled = false
		return
	if mode != Mode.FOLLOW:
		# A detached camera has nothing to chase; smoothing would only delay
		# the cut when the mode or the map changes.
		position_smoothing_enabled = false
		return
	# A map narrower than the screen would jitter against its own limits;
	# centre it instead of clamping.
	var view := _view_size()
	position_smoothing_speed = FOLLOW_SMOOTHING_SPEED
	position_smoothing_enabled = _grid_bounds.size.x > view.x and _grid_bounds.size.y > view.y


func _view_size() -> Vector2:
	if is_inside_tree():
		return get_viewport_rect().size
	return Vector2(Presentation.viewport())


# --------------------------------------------------------------------------
# cinematic borrowing
# --------------------------------------------------------------------------

## Take the camera for a scripted moment. Remembers the mode in force so
## release() puts it back; borrowing twice is harmless.
func borrow() -> void:
	if mode == Mode.CINEMATIC:
		return
	set_mode(Mode.CINEMATIC)


## Hand it back to whatever it was doing before the borrow.
func release() -> void:
	if mode != Mode.CINEMATIC:
		return
	set_mode(_borrowed_from)


## The mode a release() would return to.
func borrowed_from() -> Mode:
	return _borrowed_from


## Glide the view to a world position without disturbing the transform
## underneath. Returns the tween so a cutscene can await it. Pair with
## release_focus().
func focus_on(world_position: Vector2, duration := 0.6) -> Tween:
	borrow()
	var tween := create_tween()
	tween.tween_property(self, "offset", world_position - global_position, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return tween


## Return the view and the camera together: the offset eases back to nothing
## and the mode goes back to whatever borrowed it -- FIXED to FIXED, not to
## FOLLOW.
func release_focus(duration := 0.6) -> Tween:
	var tween := create_tween()
	tween.tween_property(self, "offset", Vector2.ZERO, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.finished.connect(release)
	return tween
