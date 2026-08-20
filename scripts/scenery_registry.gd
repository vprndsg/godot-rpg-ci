## Scenery: everything visible that is not a gameplay tile.
##
## A tile is a cell of the world the player walks on -- one diamond, one
## collision polygon, one atlas coordinate. Scenery is the opposite kind of
## thing: a redwood trunk four hundred pixels tall, a branch cropped by the
## top of the frame, a ridge in the far distance that nothing will ever touch.
## Forcing those through the tile grid would mean a tree consuming forty cells
## because its canopy is wide, which is exactly the confusion this class
## exists to prevent.
##
## **Scenery never collides.** That is the load-bearing rule. A redwood blocks
## movement because the *map* puts a solid tile on its anchor cell, and a prop
## can declare `"requires_solid"` so the validator proves the map did. The
## simulation stays a grid of cells; the picture is free to be enormous.
##
## Four footprints, deliberately unrelated:
##
## ```
##      visual          logical        collision        occlusion
##   the image        "footprint"      the MAP's        "occluder"
##   any size         usually 1 cell   solid tiles      <= logical
##      |                  |                |               |
##   renderer         validator         physics         2D lights
## ```
##
## `assets/scenery/scenery.json` is the registry; a map places entries from it
## with a `"scenery"` array; `scripts/scene_planes.gd` turns placements into
## nodes. docs/architecture/scenery.md is the design.
class_name SceneryRegistry
extends RefCounted

const PATH := "res://assets/scenery/scenery.json"

const PROP_KEYS: PackedStringArray = [
	"texture", "frame_size", "anchor", "plane", "footprint", "requires_solid",
	"occluder", "normal", "emission", "pack", "frames",
]
const PLACEMENT_KEYS: PackedStringArray = [
	"prop", "at", "screen", "offset", "plane", "space", "parallax", "sort",
	"flip_h", "modulate", "visible",
]

## Where a placement is positioned from. `world` is a cell; `camera` is an
## offset from the middle of the view; `screen` is a fraction of the viewport.
## Only the first is part of the world -- the other two follow the frame.
const SPACES: PackedStringArray = ["world", "camera", "screen"]

## How far a prop moves relative to the world. 1.0 is locked to it (an
## ordinary world-space object); below 1.0 drifts behind, which is what makes
## a distant ridge read as distant; above 1.0 races ahead, for foreground
## foliage brushing past the camera.
const PARALLAX_RANGE := Vector2(0.0, 4.0)

var data: Dictionary = {}

static var _default: SceneryRegistry = null


static func load_default() -> SceneryRegistry:
	if _default == null:
		_default = SceneryRegistry.new()
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f == null:
			push_error("Missing %s" % PATH)
		else:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				_default.data = parsed
			else:
				push_error("%s is not a JSON object" % PATH)
	return _default


## Drop the parsed data so the next call re-reads the file. Named away from
## `reload()` on purpose: `Script` already has one, and it wins -- see
## TileRegistry.clear_cache().
static func clear_cache() -> void:
	_default = null


## Build one from a dictionary. Tests use this to exercise props that should
## never be files -- and so will a future editor tool.
static func from_dict(raw: Dictionary) -> SceneryRegistry:
	var registry := SceneryRegistry.new()
	registry.data = raw
	return registry


func props() -> Dictionary:
	return data.get("props", {})


func has_prop(prop: String) -> bool:
	return props().has(prop)


func names() -> Array:
	var out: Array = props().keys()
	out.sort()
	return out


func prop(prop_name: String) -> Dictionary:
	return props().get(prop_name, {})


## The pixel inside the image that touches the ground. Everything about where
## a prop goes and how it sorts follows from this one number.
func anchor(prop_name: String) -> Vector2:
	var raw: Variant = prop(prop_name).get("anchor", [])
	if not (raw is Array) or (raw as Array).size() != 2:
		return Vector2.ZERO
	return Vector2(float(raw[0]), float(raw[1]))


## Where the prop's pixels live. Any res:// path -- a generated image, a
## sheet inside an art pack, anything the importer produced.
func texture_path_of(prop_name: String) -> String:
	return String(prop(prop_name).get("texture", ""))


## Which imported art pack a prop's pixels came from, or "".
func pack_of(prop_name: String) -> String:
	return String(prop(prop_name).get("pack", ""))


## Optional layout-identical material maps, by the same naming contract packs
## and tile atlases use. Empty when the prop ships none.
func material_map(prop_name: String, kind: String) -> String:
	return String(prop(prop_name).get(kind, ""))


## The visible frame, or Vector2.ZERO to mean "the whole texture". A prop with
## `frames` slices this out of a strip.
func frame_size(prop_name: String) -> Vector2:
	var raw: Variant = prop(prop_name).get("frame_size", [])
	if not (raw is Array) or (raw as Array).size() != 2:
		return Vector2.ZERO
	return Vector2(float(raw[0]), float(raw[1]))


## The cells this prop occupies in the world model, relative to its anchor
## cell. Empty means it occupies nothing -- a backdrop, a branch overhead --
## which is the common case and is why it is not a size.
func footprint(prop_name: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell: Variant in prop(prop_name).get("footprint", []):
		if cell is Array and (cell as Array).size() == 2:
			out.append(Vector2i(int(cell[0]), int(cell[1])))
	return out


## True when the map is required to make this prop's footprint solid. The
## contract for anything that visibly blocks the way: the picture is scenery,
## the obstacle is a tile, and the validator checks they agree.
func requires_solid(prop_name: String) -> bool:
	return bool(prop(prop_name).get("requires_solid", false))


## The polygon this prop blocks light with, in the same space as a tile's --
## screen pixels around the anchor. Empty when it does not occlude.
func occluder_polygon(prop_name: String) -> PackedVector2Array:
	var occ: Variant = prop(prop_name).get("occluder")
	if occ is bool:
		return Iso.diamond() if occ else PackedVector2Array()
	if not (occ is Dictionary):
		return PackedVector2Array()
	var spec: Dictionary = occ
	if spec.has("points"):
		var out := PackedVector2Array()
		for point: Variant in spec["points"]:
			if point is Array and (point as Array).size() == 2:
				out.append(Vector2(float(point[0]), float(point[1])))
		return out
	return Iso.diamond(clampf(float(spec.get("scale", 1.0)), 0.05, 1.0))


## Which plane this prop belongs in when a placement does not say.
func default_plane(prop_name: String) -> String:
	return String(prop(prop_name).get("plane", ScenePlanes.PLAYABLE))


## Animation, as `{frames, fps, loop}`, or {} for a still image.
func animation(prop_name: String) -> Dictionary:
	var raw: Variant = prop(prop_name).get("frames")
	if not (raw is Dictionary):
		return {}
	var spec: Dictionary = raw
	return {
		"frames": maxi(1, int(spec.get("count", 1))),
		"fps": maxf(0.0, float(spec.get("fps", 0.0))),
		"loop": bool(spec.get("loop", true)),
	}


## Props whose art was imported rather than drawn, sorted. Third-party art
## carries licence terms, exactly as it does for tiles.
func imported_names() -> Array:
	var out: Array = []
	for prop_name: String in props():
		if not String(prop(prop_name).get("pack", "")).is_empty():
			out.append(prop_name)
	out.sort()
	return out


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

## Problems with the registry itself. Empty means every prop is well-formed.
func validate(check_textures: bool = true) -> PackedStringArray:
	var errors: PackedStringArray = []
	for prop_name: String in props():
		var subject := "scenery prop '%s'" % prop_name
		var entry: Variant = props()[prop_name]
		if not (entry is Dictionary):
			errors.append("%s must be an object" % subject)
			continue
		var spec: Dictionary = entry
		for key: String in spec:
			if not key.begins_with("_") and not PROP_KEYS.has(key):
				errors.append("%s: unknown key '%s' (expected one of %s)" % [subject, key, PROP_KEYS])

		var texture := String(spec.get("texture", ""))
		if texture.is_empty():
			errors.append("%s has no 'texture'" % subject)
		elif check_textures and not ResourceLoader.exists(texture):
			errors.append("%s names texture '%s', which does not exist" % [subject, texture])
		for kind: String in ["normal", "emission"]:
			var extra := String(spec.get(kind, ""))
			if not extra.is_empty() and check_textures and not ResourceLoader.exists(extra):
				errors.append("%s names a %s map '%s', which does not exist" % [subject, kind, extra])

		if not spec.has("anchor"):
			errors.append("%s has no 'anchor' -- the pixel that touches the ground is what a "
				% subject + "prop is placed and sorted by, so it is never optional")
		elif not _is_point(spec["anchor"]):
			errors.append("%s: anchor must be [x, y] in pixels" % subject)

		if spec.has("frame_size") and not _is_point(spec["frame_size"]):
			errors.append("%s: frame_size must be [width, height]" % subject)

		var plane := default_plane(prop_name)
		if not ScenePlanes.PLANES.has(plane):
			errors.append("%s: unknown plane '%s' (expected one of %s)"
				% [subject, plane, ScenePlanes.PLANES])

		if spec.has("footprint"):
			if not (spec["footprint"] is Array):
				errors.append("%s: footprint must be a list of [x, y] cell offsets" % subject)
			else:
				for cell: Variant in spec["footprint"]:
					if not _is_point(cell):
						errors.append("%s: footprint entry %s is not an [x, y] cell offset" % [subject, cell])
		if requires_solid(prop_name) and footprint(prop_name).is_empty():
			errors.append("%s: 'requires_solid' with no footprint says nothing -- name the cells "
				% subject + "the map has to make solid")
		if spec.has("requires_solid") and not (spec["requires_solid"] is bool):
			errors.append("%s: requires_solid must be true or false" % subject)

		if spec.has("occluder") and occluder_polygon(prop_name).size() < 3 \
				and not (spec["occluder"] is bool and not spec["occluder"]):
			errors.append("%s: occluder resolved to a degenerate polygon" % subject)

		if spec.has("frames"):
			if not (spec["frames"] is Dictionary):
				errors.append("%s: frames must be an object like {\"count\": 4, \"fps\": 6}" % subject)
			else:
				var anim := animation(prop_name)
				if anim["frames"] > 1 and anim["fps"] <= 0.0:
					errors.append("%s: %d frames but no fps, so it would never advance"
						% [subject, anim["frames"]])
				if frame_size(prop_name) == Vector2.ZERO:
					errors.append("%s: an animated prop needs a 'frame_size' to slice its strip" % subject)
	return errors


## Problems with a map's `"scenery"` array. `map` is used to check that cells
## exist and that anything claiming to block the way actually does -- which is
## where the separation between picture and simulation is enforced.
func validate_placements(placements: Array, subject: String, map: MapData) -> PackedStringArray:
	var errors: PackedStringArray = []
	for i: int in placements.size():
		var entry: Variant = placements[i]
		var label := "%s scenery[%d]" % [subject, i]
		if not (entry is Dictionary):
			errors.append("%s must be an object" % label)
			continue
		var spec: Dictionary = entry
		for key: String in spec:
			if not key.begins_with("_") and not PLACEMENT_KEYS.has(key):
				errors.append("%s: unknown key '%s' (expected one of %s)" % [label, key, PLACEMENT_KEYS])

		var prop_name := String(spec.get("prop", ""))
		if prop_name.is_empty():
			errors.append("%s has no 'prop'" % label)
			continue
		if not has_prop(prop_name):
			errors.append("%s places '%s', which is not in %s" % [label, prop_name, PATH])
			continue
		label = "%s scenery '%s'" % [subject, prop_name]

		var space := String(spec.get("space", "world"))
		if not SPACES.has(space):
			errors.append("%s: unknown space '%s' (expected one of %s)" % [label, space, SPACES])
			continue

		var plane := String(spec.get("plane", default_plane(prop_name)))
		if not ScenePlanes.PLANES.has(plane):
			errors.append("%s: unknown plane '%s' (expected one of %s)" % [label, plane, ScenePlanes.PLANES])
		elif ScenePlanes.is_screen_plane(plane) != (space == "screen"):
			errors.append("%s: space '%s' does not belong in plane '%s' -- screen-space scenery "
				% [label, space, plane] + "goes in a screen plane and world-space scenery does not")

		if space == "world":
			if not spec.has("at"):
				errors.append("%s: world-space scenery needs an 'at' cell" % label)
			elif not _is_point(spec["at"]):
				errors.append("%s: 'at' must be [x, y] in cells" % label)
			else:
				var cell := Vector2i(int(spec["at"][0]), int(spec["at"][1]))
				if not map.in_bounds(cell):
					errors.append("%s at %s is outside the %dx%d map" % [label, cell, map.width, map.height])
				elif requires_solid(prop_name):
					for offset: Vector2i in footprint(prop_name):
						if not map.is_solid(cell + offset):
							errors.append("%s claims cell %s but the map leaves it walkable -- "
								% [label, cell + offset] + "a prop the player can see but walk "
								+ "through is a picture, not an obstacle; put a solid tile there")
		elif space == "screen":
			if spec.has("screen") and not _is_point(spec["screen"]):
				errors.append("%s: 'screen' must be [x, y] as fractions of the viewport" % label)
			if spec.has("at"):
				errors.append("%s: screen-space scenery has no cell; use 'screen' fractions" % label)

		if spec.has("parallax"):
			if not (spec["parallax"] is float or spec["parallax"] is int):
				errors.append("%s: parallax must be a number" % label)
			elif float(spec["parallax"]) < PARALLAX_RANGE.x or float(spec["parallax"]) > PARALLAX_RANGE.y:
				errors.append("%s: parallax %s is outside %s" % [label, spec["parallax"], PARALLAX_RANGE])
			elif space == "screen":
				errors.append("%s: screen-space scenery cannot parallax; it is already fixed "
					% label + "to the frame")
		if spec.has("offset") and not _is_point(spec["offset"]):
			errors.append("%s: 'offset' must be [x, y] in screen pixels" % label)
		if spec.has("modulate") and not Color.html_is_valid(String(spec["modulate"])):
			errors.append("%s: modulate '%s' is not an html colour" % [label, spec["modulate"]])
		for flag: String in ["flip_h", "visible"]:
			if spec.has(flag) and not (spec[flag] is bool):
				errors.append("%s: %s must be true or false" % [label, flag])
		if spec.has("sort") and not (spec["sort"] is float or spec["sort"] is int):
			errors.append("%s: sort must be a number" % label)
	return errors


static func _is_point(v: Variant) -> bool:
	if not (v is Array) or (v as Array).size() != 2:
		return false
	return (v[0] is float or v[0] is int) and (v[1] is float or v[1] is int)
