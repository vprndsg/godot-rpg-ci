## One resolved lighting environment: ambient tone plus an optional sun.
##
## Profiles are data, not scenes. Named baselines live in data/lighting/*.json
## and a map opts in with a "lighting" key -- usually just a profile name,
## optionally with overrides on top:
##
##     "lighting": { "profile": "warm_interior", "ambient_energy": 0.6 }
##
## A map with no "lighting" key resolves to data/lighting/default.json, which
## is full-bright white with no sun -- pixel-identical to a world with no
## lighting system at all. That default is what makes the whole feature
## backward compatible, so never make it moodier.
##
## This class only *describes* an environment. Turning it into live nodes is
## scripts/world_lighting.gd's job; validating a map's spec against it is
## MapData.validate()'s, via validate_spec().
class_name LightingProfile
extends RefCounted

const PROFILES_DIR := "res://data/lighting"
const DEFAULT_PROFILE := "default"

## Keys a profile file or a map's "lighting" block may use. Anything else is a
## validation error, because a typo here ("ambient_colour") would otherwise be
## silently ignored -- the worst failure mode for headless authoring.
const SPEC_KEYS: PackedStringArray = ["profile", "ambient_color", "ambient_energy", "directional"]
const DIRECTIONAL_KEYS: PackedStringArray = ["enabled", "color", "energy", "angle_degrees", "height", "shadows"]

var ambient_color: Color = Color.WHITE
var ambient_energy: float = 1.0

var directional_enabled: bool = false
var directional_color: Color = Color.WHITE
var directional_energy: float = 0.0
## Rotation of the DirectionalLight2D in degrees. 0 points the light straight
## down the screen; negative leans it toward screen-left. Only visible once
## shadows or normal maps are in play, but authored now so scenes read right later.
var directional_angle_degrees: float = -35.0
## How far "off the canvas" the light sits, 0..1. Purely a normal-map term:
## higher grazes less. Irrelevant until an atlas ships normals, harmless before.
var directional_height: float = 0.5
var directional_shadows: bool = false


static func path_for(profile_id: String) -> String:
	return "%s/%s.json" % [PROFILES_DIR, profile_id]


static func exists(profile_id: String) -> bool:
	return FileAccess.file_exists(path_for(profile_id))


## Every profile id in data/lighting/, sorted. Used by tests and validators.
static func all_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(PROFILES_DIR)
	if dir == null:
		return out
	for file: String in dir.get_files():
		# Exported builds append .remap to imported files.
		var file_name := file.trim_suffix(".remap")
		if file_name.ends_with(".json"):
			out.append(file_name.trim_suffix(".json"))
	out.sort()
	return out


## Resolve a map's "lighting" block (possibly empty) into a usable profile:
## identity defaults, then the named profile file, then the map's overrides.
## Never returns null -- a broken spec resolves to whatever was valid around
## it, and validate_spec() is where the breakage gets reported.
static func resolve(spec: Dictionary) -> LightingProfile:
	var profile := LightingProfile.new()
	var profile_id := String(spec.get("profile", DEFAULT_PROFILE))
	profile._apply(_load_raw(profile_id))
	profile._apply(spec)
	return profile


## The environment every map gets when it says nothing: data/lighting/default.json.
static func defaults() -> LightingProfile:
	return resolve({})


## The CanvasModulate colour this environment asks for.
func ambient() -> Color:
	return Color(
		ambient_color.r * ambient_energy,
		ambient_color.g * ambient_energy,
		ambient_color.b * ambient_energy,
		1.0
	)


static func _load_raw(profile_id: String) -> Dictionary:
	var path := path_for(profile_id)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


## Lay `spec` over the current values. Only keys present in the spec change
## anything, which is what lets a map override one number from a profile.
func _apply(spec: Dictionary) -> void:
	if spec.has("ambient_color") and Color.html_is_valid(String(spec["ambient_color"])):
		ambient_color = Color.html(String(spec["ambient_color"]))
	if spec.has("ambient_energy"):
		ambient_energy = clampf(float(spec["ambient_energy"]), 0.0, 2.0)
	var dir_spec: Variant = spec.get("directional")
	if dir_spec is Dictionary:
		var d: Dictionary = dir_spec
		if d.has("enabled"):
			directional_enabled = bool(d["enabled"])
		if d.has("color") and Color.html_is_valid(String(d["color"])):
			directional_color = Color.html(String(d["color"]))
		if d.has("energy"):
			directional_energy = clampf(float(d["energy"]), 0.0, 2.0)
		if d.has("angle_degrees"):
			directional_angle_degrees = float(d["angle_degrees"])
		if d.has("height"):
			directional_height = clampf(float(d["height"]), 0.0, 1.0)
		if d.has("shadows"):
			directional_shadows = bool(d["shadows"])


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

## Problems with one "lighting" block, from a map or a profile file. `subject`
## names the owner in the messages. Underscore keys are comments, by the same
## convention as tiles.json.
static func validate_spec(spec: Dictionary, subject: String, allow_profile_key := true) -> PackedStringArray:
	var errors: PackedStringArray = []
	for key: String in spec:
		if key.begins_with("_"):
			continue
		if not SPEC_KEYS.has(key) or (key == "profile" and not allow_profile_key):
			errors.append("%s: unknown lighting key '%s' (expected one of %s)" % [subject, key, SPEC_KEYS])

	if spec.has("profile"):
		var profile_id := String(spec["profile"])
		if not exists(profile_id):
			errors.append("%s: no lighting profile '%s' (known: %s)" % [subject, profile_id, all_ids()])

	if spec.has("ambient_color") and not Color.html_is_valid(String(spec["ambient_color"])):
		errors.append("%s: ambient_color '%s' is not an html colour like 'e6c69e'" % [subject, spec["ambient_color"]])
	if spec.has("ambient_energy") and not _is_number(spec["ambient_energy"]):
		errors.append("%s: ambient_energy must be a number, got '%s'" % [subject, spec["ambient_energy"]])

	if spec.has("directional"):
		if not (spec["directional"] is Dictionary):
			errors.append("%s: 'directional' must be an object" % subject)
			return errors
		var d: Dictionary = spec["directional"]
		for key: String in d:
			if not key.begins_with("_") and not DIRECTIONAL_KEYS.has(key):
				errors.append("%s: unknown directional key '%s' (expected one of %s)" % [subject, key, DIRECTIONAL_KEYS])
		if d.has("color") and not Color.html_is_valid(String(d["color"])):
			errors.append("%s: directional color '%s' is not an html colour" % [subject, d["color"]])
		for numeric: String in ["energy", "angle_degrees", "height"]:
			if d.has(numeric) and not _is_number(d[numeric]):
				errors.append("%s: directional %s must be a number, got '%s'" % [subject, numeric, d[numeric]])
		for flag: String in ["enabled", "shadows"]:
			if d.has(flag) and not (d[flag] is bool):
				errors.append("%s: directional %s must be true or false" % [subject, flag])
	return errors


## Problems with one profile file. Profile files use the same schema as a
## map's block, minus "profile" -- a profile naming another profile would be
## a resolution loop waiting to happen.
static func validate_profile(profile_id: String) -> PackedStringArray:
	var raw := _load_raw(profile_id)
	if raw.is_empty():
		return PackedStringArray(["data/lighting/%s.json is missing or not a JSON object" % profile_id])
	return validate_spec(raw, "data/lighting/%s.json" % profile_id, false)


static func _is_number(v: Variant) -> bool:
	return v is float or v is int
