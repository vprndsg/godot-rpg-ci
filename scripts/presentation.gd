## The presentation contract: the screen half of the world's geometry.
##
## `assets/tiles/tiles.json` says how big a tile is; `data/rendering.json` says
## how big the screen it lands on is, and which CanvasLayer everything stacks
## on. Both are read, never hardcoded -- a `640` typed into a script is a
## number that will be wrong the day the contract moves, in exactly one file
## and nowhere else.
##
## The engine cannot boot from this file (project.godot has to carry the
## display settings itself), so the file is the *source* and project.godot is
## the copy. tests/test_rendering.gd asserts they agree, which is what makes
## one of them authoritative instead of both of them guesses.
class_name Presentation
extends RefCounted

const PATH := "res://data/rendering.json"

static var _cache: Dictionary = {}


static func data() -> Dictionary:
	if _cache.is_empty():
		var f := FileAccess.open(PATH, FileAccess.READ)
		assert(f != null, "Missing %s" % PATH)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		assert(parsed is Dictionary, "%s is not a JSON object" % PATH)
		_cache = parsed
	return _cache


## Drop the parsed data so the next call re-reads the file. Named away from
## `reload()` on purpose: `Script` already has one, and it wins -- see
## TileRegistry.clear_cache().
static func clear_cache() -> void:
	_cache = {}


## The internal resolution the world is drawn at, in pixels. Camera framing,
## screen-space scenery and every fx overlay are measured in these.
static func viewport() -> Vector2i:
	return _vec("viewport", Vector2i(640, 360))


## The desktop window the project opens at -- an integer multiple of the
## viewport, so a developer sees whole pixels without touching a setting.
static func window() -> Vector2i:
	return _vec("window", Vector2i(1280, 720))


static func stretch_mode() -> String:
	return String(data().get("stretch_mode", "canvas_items"))


static func stretch_aspect() -> String:
	return String(data().get("stretch_aspect", "keep"))


static func scale_mode() -> String:
	return String(data().get("scale_mode", "integer"))


static func texture_filter() -> int:
	return int(data().get("texture_filter", 0))


## The CanvasLayer a named band of the presentation stack sits on. Anything
## that creates a CanvasLayer asks here rather than inventing a number, so the
## ordering of world planes, screen effects and UI is decided in one place.
static func layer(band: String) -> int:
	var layers: Dictionary = data().get("layers", {})
	assert(layers.has(band), "no layer named '%s' in %s" % [band, PATH])
	return int(layers.get(band, 0))


static func layer_names() -> Array:
	var out: Array = data().get("layers", {}).keys()
	out.sort()
	return out


## Problems with the contract itself, and with project.godot's copy of it.
## Called by tests/test_rendering.gd; kept here so the rule and the numbers
## live together.
static func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	var view := viewport()
	if view.x <= 0 or view.y <= 0:
		errors.append("data/rendering.json: viewport must be positive, got %s" % view)
	var win := window()
	if win.x % view.x != 0 or win.y % view.y != 0:
		errors.append("data/rendering.json: window %s is not a whole multiple of the viewport %s -- "
			% [win, view] + "a fractional window scale shows half pixels")

	var settings := {
		"display/window/size/viewport_width": view.x,
		"display/window/size/viewport_height": view.y,
		"display/window/size/window_width_override": win.x,
		"display/window/size/window_height_override": win.y,
		"display/window/stretch/mode": stretch_mode(),
		"display/window/stretch/aspect": stretch_aspect(),
		"display/window/stretch/scale_mode": scale_mode(),
		"rendering/textures/canvas_textures/default_texture_filter": texture_filter(),
	}
	for key: String in settings:
		var actual: Variant = ProjectSettings.get_setting(key, null)
		if actual == null:
			errors.append("project.godot does not set '%s' (data/rendering.json says %s)" % [key, settings[key]])
		elif str(actual) != str(settings[key]):
			errors.append("project.godot has %s = %s but data/rendering.json says %s"
				% [key, actual, settings[key]])
	return errors


static func _vec(key: String, fallback: Vector2i) -> Vector2i:
	var v: Array = data().get(key, [])
	if v.size() != 2:
		return fallback
	return Vector2i(int(v[0]), int(v[1]))
