## What a map says about how it should be framed.
##
## A map's optional `"camera"` block, parsed and validated here and applied by
## `scripts/game_camera.gd`. A map that says nothing gets FOLLOW -- the camera
## rides the player and clamps to the map -- which is exactly what every map
## did before this existed, so the whole feature is opt-in.
##
## ```json
## "camera": {
##   "mode": "room_locked",
##   "room": [4, 2, 12, 9],
##   "zoom": 1.0,
##   "smoothing": true
## }
## ```
##
## | mode | what it does | needs |
## | --- | --- | --- |
## | `follow` | rides the player, clamped to the map | nothing |
## | `room_locked` | composition stays inside a room; follows within it, centres when the room is smaller than the screen | `room` |
## | `fixed` | authored position, player moves through the frame | `at` or `position` |
##
## `cinematic` is deliberately **not** authorable: it is a runtime state a
## cutscene borrows and gives back, not a way for a map to be framed.
class_name CameraConfig
extends RefCounted

## The modes a map may ask for, lower-case as they appear in JSON.
const MODES: PackedStringArray = ["follow", "room_locked", "fixed"]
const KEYS: PackedStringArray = ["mode", "room", "at", "position", "offset", "zoom", "smoothing"]

const DEFAULT_MODE := "follow"


## What a map with no "camera" block means: the pre-existing behaviour.
static func defaults() -> Dictionary:
	return {"mode": DEFAULT_MODE}


static func mode_of(spec: Dictionary) -> String:
	return String(spec.get("mode", DEFAULT_MODE))


## The room rectangle in cells, or an empty Rect2i when none is authored.
static func room_of(spec: Dictionary) -> Rect2i:
	var raw: Variant = spec.get("room")
	if not (raw is Array) or (raw as Array).size() != 4:
		return Rect2i()
	return Rect2i(int(raw[0]), int(raw[1]), int(raw[2]), int(raw[3]))


## The cell a fixed camera centres on, or (-1, -1) when it names a pixel
## position instead.
static func anchor_cell(spec: Dictionary) -> Vector2i:
	var raw: Variant = spec.get("at")
	if not (raw is Array) or (raw as Array).size() != 2:
		return Vector2i(-1, -1)
	return Vector2i(int(raw[0]), int(raw[1]))


## A raw screen position for a fixed camera, for framing that does not land on
## a cell. Cells are the readable way; this is the escape hatch.
static func anchor_position(spec: Dictionary) -> Vector2:
	return _point(spec.get("position"), Vector2.INF)


## Screen pixels added to whatever anchor was resolved -- how a composition is
## nudged without moving the cell it is described by.
static func offset_of(spec: Dictionary) -> Vector2:
	return _point(spec.get("offset"), Vector2.ZERO)


static func zoom_of(spec: Dictionary) -> float:
	return float(spec.get("zoom", 1.0))


## Whether the camera eases toward its target. Defaults differ by mode: a
## following camera glides, an authored composition snaps.
static func smoothing_of(spec: Dictionary) -> bool:
	return bool(spec.get("smoothing", mode_of(spec) != "fixed"))


static func _point(raw: Variant, fallback: Vector2) -> Vector2:
	if not (raw is Array) or (raw as Array).size() != 2:
		return fallback
	return Vector2(float(raw[0]), float(raw[1]))


## Problems with one "camera" block. `size` is the map's cell dimensions so a
## room or an anchor outside the world is caught here rather than by a black
## screen. Empty means the block is sound.
static func validate_spec(spec: Dictionary, subject: String, size: Vector2i) -> PackedStringArray:
	var errors: PackedStringArray = []
	for key: String in spec:
		if not key.begins_with("_") and not KEYS.has(key):
			errors.append("%s: unknown camera key '%s' (expected one of %s)" % [subject, key, KEYS])

	var mode := mode_of(spec)
	if not MODES.has(mode):
		if mode == "cinematic":
			errors.append("%s: 'cinematic' is a runtime state a cutscene borrows, not a "
				% subject + "camera a map may ask for; use one of %s" % [MODES])
		else:
			errors.append("%s: unknown camera mode '%s' (expected one of %s)" % [subject, mode, MODES])
		return errors

	if spec.has("room"):
		var room := room_of(spec)
		if room == Rect2i():
			errors.append("%s: room must be [x, y, width, height] in cells" % subject)
		elif room.size.x <= 0 or room.size.y <= 0:
			errors.append("%s: room %s has no area" % [subject, room])
		elif room.position.x < 0 or room.position.y < 0 \
				or room.position.x + room.size.x > size.x or room.position.y + room.size.y > size.y:
			errors.append("%s: room %s reaches outside the %dx%d map" % [subject, room, size.x, size.y])
	if mode == "room_locked" and not spec.has("room"):
		errors.append("%s: mode 'room_locked' needs a 'room' rectangle to lock to" % subject)

	if spec.has("at"):
		var cell := anchor_cell(spec)
		if cell == Vector2i(-1, -1):
			errors.append("%s: 'at' must be [x, y] in cells" % subject)
		elif cell.x < 0 or cell.y < 0 or cell.x >= size.x or cell.y >= size.y:
			errors.append("%s: camera 'at' %s is outside the %dx%d map" % [subject, cell, size.x, size.y])
	if spec.has("position") and anchor_position(spec) == Vector2.INF:
		errors.append("%s: 'position' must be [x, y] in screen pixels" % subject)
	if spec.has("at") and spec.has("position"):
		errors.append("%s: camera has both 'at' (a cell) and 'position' (pixels); pick one" % subject)
	if mode == "fixed" and not (spec.has("at") or spec.has("position")):
		errors.append("%s: mode 'fixed' needs an 'at' cell or a 'position' to sit at" % subject)

	if spec.has("offset") and offset_of(spec) == Vector2.ZERO and not _is_zero_pair(spec["offset"]):
		errors.append("%s: 'offset' must be [x, y] in screen pixels" % subject)
	if spec.has("zoom"):
		if not (spec["zoom"] is float or spec["zoom"] is int):
			errors.append("%s: zoom must be a number" % subject)
		elif zoom_of(spec) <= 0.0:
			errors.append("%s: zoom must be positive" % subject)
	if spec.has("smoothing") and not (spec["smoothing"] is bool):
		errors.append("%s: smoothing must be true or false" % subject)
	return errors


static func _is_zero_pair(raw: Variant) -> bool:
	return raw is Array and (raw as Array).size() == 2 \
		and float(raw[0]) == 0.0 and float(raw[1]) == 0.0
