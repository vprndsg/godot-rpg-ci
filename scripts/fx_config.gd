## What a map says about its atmosphere, resolved and validated.
##
## The effect *vocabulary* lives in `data/fx/effects.json` -- every effect
## the game can run, its shader, where it composites and every parameter it
## takes. Named stacks live in `data/fx/<preset>.json`. A map opts in with an
## `"fx"` block:
##
## ```json
## "fx": {
##   "preset": "pixel_quantize",
##   "effects": [
##     {"type": "fog", "density": 0.4, "color": "9fb3bd"},
##     {"type": "quantize", "enabled": false}
##   ]
## }
## ```
##
## Resolution is preset first, then the map's own entries, **keyed on type**:
## a map may retune one parameter of an inherited effect, or switch it off
## with `"enabled": false`, without restating the stack. The result comes back
## in `effects.json`'s own `order`, never in authoring order, so two maps that
## list the same effects differently render identically.
##
## A map with no `"fx"` block gets an empty stack -- pixel-identical to the
## world before this system existed. That is the compatibility contract, and
## it is the same one the lighting default makes.
class_name FxConfig
extends RefCounted

const CATALOG_PATH := "res://data/fx/effects.json"
const PRESETS_DIR := "res://data/fx"

const SPEC_KEYS: PackedStringArray = ["preset", "effects"]
## Keys every effect entry may carry whatever its type; the rest are its own
## parameters, checked against the catalog.
const ENTRY_KEYS: PackedStringArray = ["type", "enabled"]

const PARAM_TYPES: PackedStringArray = ["float", "color", "vec2", "bool"]

static var _catalog: Dictionary = {}


## The effect vocabulary, parsed once.
static func catalog() -> Dictionary:
	if _catalog.is_empty():
		var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
		if f == null:
			push_error("Missing %s" % CATALOG_PATH)
			return {}
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Dictionary:
			_catalog = parsed
		else:
			push_error("%s is not a JSON object" % CATALOG_PATH)
	return _catalog


## Drop the parsed data so the next call re-reads the file. Named away from
## `reload()` on purpose: `Script` already has one, and it wins -- see
## TileRegistry.clear_cache().
static func clear_cache() -> void:
	_catalog = {}


static func effects() -> Dictionary:
	return catalog().get("effects", {})


static func has_effect(type: String) -> bool:
	return effects().has(type)


static func effect_names() -> Array:
	var out: Array = effects().keys()
	out.sort()
	return out


static func definition(type: String) -> Dictionary:
	return effects().get(type, {})


## "screen" (over the finished frame, under the UI) or "world" (inside the
## world, at a z_index between the depth planes).
static func space_of(type: String) -> String:
	return String(definition(type).get("space", "screen"))


static func order_of(type: String) -> int:
	return int(definition(type).get("order", 0))


static func reads_screen(type: String) -> bool:
	return bool(definition(type).get("reads_screen", false))


static func shader_of(type: String) -> String:
	return String(definition(type).get("shader", ""))


static func params_of(type: String) -> Dictionary:
	return definition(type).get("params", {})


static func preset_path(preset_id: String) -> String:
	return "%s/%s.json" % [PRESETS_DIR, preset_id]


static func preset_exists(preset_id: String) -> bool:
	# effects.json shares the directory but is the vocabulary, not a stack.
	return preset_id != "effects" and FileAccess.file_exists(preset_path(preset_id))


## Every preset id in data/fx/, sorted.
static func all_presets() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(PRESETS_DIR)
	if dir == null:
		return out
	for file: String in dir.get_files():
		var file_name := file.trim_suffix(".remap")
		if file_name.ends_with(".json") and file_name != "effects.json":
			out.append(file_name.trim_suffix(".json"))
	out.sort()
	return out


# --------------------------------------------------------------------------
# resolution
# --------------------------------------------------------------------------

## Resolve a map's "fx" block into the stack the runtime should build:
##
##     [{type, space, order, reads_screen, shader, params: {name: value}}, ...]
##
## in compositing order, with every parameter filled in from the catalog's
## defaults and clamped to its declared range. Never returns null; a broken
## spec resolves to whatever was valid around it, and validate_spec() is where
## the breakage gets reported.
static func resolve(spec: Dictionary) -> Array[Dictionary]:
	var merged: Dictionary = {}
	var preset_id := String(spec.get("preset", ""))
	if not preset_id.is_empty():
		_merge(merged, _load_raw(preset_path(preset_id)).get("effects", []))
	_merge(merged, spec.get("effects", []))

	var out: Array[Dictionary] = []
	for type: String in merged:
		if not has_effect(type):
			continue
		var entry: Dictionary = merged[type]
		if not bool(entry.get("enabled", true)):
			continue
		out.append({
			"type": type,
			"space": space_of(type),
			"order": order_of(type),
			"reads_screen": reads_screen(type),
			"shader": shader_of(type),
			"params": _resolve_params(type, entry),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		# Order first, then name, so the stack is a pure function of what is
		# in it and never of the order somebody typed it.
		if a["order"] != b["order"]:
			return a["order"] < b["order"]
		return String(a["type"]) < String(b["type"]))
	return out


static func _merge(into: Dictionary, entries: Variant) -> void:
	if not (entries is Array):
		return
	for entry: Variant in entries:
		if not (entry is Dictionary):
			continue
		var type := String((entry as Dictionary).get("type", ""))
		if type.is_empty():
			continue
		var existing: Dictionary = into.get(type, {})
		for key: String in entry:
			existing[key] = entry[key]
		into[type] = existing


## Catalog defaults, overlaid with whatever the entry states, converted to the
## Variant type the shader uniform wants.
static func _resolve_params(type: String, entry: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var declared := params_of(type)
	for name: String in declared:
		var schema: Dictionary = declared[name]
		var raw: Variant = entry.get(name, schema.get("default"))
		out[name] = _coerce(schema, raw)
	return out


static func _coerce(schema: Dictionary, raw: Variant) -> Variant:
	match String(schema.get("type", "float")):
		"color":
			var html := String(raw)
			return Color.html(html) if Color.html_is_valid(html) else Color.WHITE
		"vec2":
			if raw is Array and (raw as Array).size() == 2:
				return Vector2(float(raw[0]), float(raw[1]))
			return Vector2.ZERO
		"bool":
			return bool(raw)
		_:
			var value := float(raw)
			if schema.has("min"):
				value = maxf(value, float(schema["min"]))
			if schema.has("max"):
				value = minf(value, float(schema["max"]))
			return value


static func _load_raw(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

## Problems with one "fx" block, from a map or a preset file. `subject` names
## the owner in the messages. Empty means the block is sound.
static func validate_spec(spec: Dictionary, subject: String, allow_preset := true) -> PackedStringArray:
	var errors: PackedStringArray = []
	for key: String in spec:
		if key.begins_with("_"):
			continue
		if not SPEC_KEYS.has(key) or (key == "preset" and not allow_preset):
			errors.append("%s: unknown fx key '%s' (expected one of %s)" % [subject, key, SPEC_KEYS])

	if spec.has("preset"):
		var preset_id := String(spec["preset"])
		if not preset_exists(preset_id):
			errors.append("%s: no fx preset '%s' (known: %s)" % [subject, preset_id, all_presets()])

	if not spec.has("effects"):
		return errors
	if not (spec["effects"] is Array):
		errors.append("%s: 'effects' must be a list of {\"type\": ...} objects" % subject)
		return errors

	var seen: Dictionary = {}
	for entry: Variant in spec["effects"]:
		if not (entry is Dictionary):
			errors.append("%s: every fx entry must be an object" % subject)
			continue
		var effect: Dictionary = entry
		var type := String(effect.get("type", ""))
		if type.is_empty():
			errors.append("%s: an fx entry has no 'type'" % subject)
			continue
		if not has_effect(type):
			errors.append("%s: unknown effect '%s' (known: %s)" % [subject, type, effect_names()])
			continue
		if seen.has(type):
			errors.append("%s: effect '%s' is listed twice; one entry per type, "
				% [subject, type] + "since a later one would only override the first")
		seen[type] = true
		if effect.has("enabled") and not (effect["enabled"] is bool):
			errors.append("%s: effect '%s' enabled must be true or false" % [subject, type])
		errors.append_array(_validate_params("%s effect '%s'" % [subject, type], type, effect))
	return errors


static func _validate_params(subject: String, type: String, entry: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = []
	var declared := params_of(type)
	for key: String in entry:
		if key.begins_with("_") or ENTRY_KEYS.has(key):
			continue
		if not declared.has(key):
			var known: Array = declared.keys()
			known.sort()
			errors.append("%s: unknown parameter '%s' (expected one of %s)" % [subject, key, known])
			continue
		var schema: Dictionary = declared[key]
		var kind := String(schema.get("type", "float"))
		var value: Variant = entry[key]
		match kind:
			"color":
				if not Color.html_is_valid(String(value)):
					errors.append("%s: %s must be an html colour like 'b8c7d1'" % [subject, key])
			"vec2":
				if not (value is Array) or (value as Array).size() != 2:
					errors.append("%s: %s must be [x, y]" % [subject, key])
			"bool":
				if not (value is bool):
					errors.append("%s: %s must be true or false" % [subject, key])
			_:
				if not (value is float or value is int):
					errors.append("%s: %s must be a number" % [subject, key])
				elif schema.has("min") and float(value) < float(schema["min"]):
					errors.append("%s: %s is %s, below the minimum %s" % [subject, key, value, schema["min"]])
				elif schema.has("max") and float(value) > float(schema["max"]):
					errors.append("%s: %s is %s, above the maximum %s" % [subject, key, value, schema["max"]])
	return errors


## Problems with the catalog itself -- the vocabulary every map is checked
## against, so a typo here would let a broken effect through everywhere.
static func validate_catalog() -> PackedStringArray:
	var errors: PackedStringArray = []
	if effects().is_empty():
		errors.append("%s declares no effects" % CATALOG_PATH)
	var orders: Dictionary = {}
	for type: String in effects():
		var subject := "fx effect '%s'" % type
		var spec: Dictionary = effects()[type]
		var shader := shader_of(type)
		if shader.is_empty():
			errors.append("%s has no shader" % subject)
		elif not ResourceLoader.exists(shader):
			errors.append("%s names shader '%s', which does not exist" % [subject, shader])
		if not ["screen", "world"].has(space_of(type)):
			errors.append("%s: space must be 'screen' or 'world', got '%s'" % [subject, space_of(type)])
		if orders.has(order_of(type)):
			errors.append("%s shares compositing order %d with '%s'; ordering must be total "
				% [subject, order_of(type), orders[order_of(type)]] + "or the frame is not reproducible")
		orders[order_of(type)] = type
		for name: String in params_of(type):
			var schema: Variant = params_of(type)[name]
			if not (schema is Dictionary):
				errors.append("%s parameter '%s' must be an object" % [subject, name])
				continue
			var kind := String((schema as Dictionary).get("type", ""))
			if not PARAM_TYPES.has(kind):
				errors.append("%s parameter '%s' has type '%s' (expected one of %s)"
					% [subject, name, kind, PARAM_TYPES])
			if not (schema as Dictionary).has("default"):
				errors.append("%s parameter '%s' has no default" % [subject, name])
	return errors


## Problems with one preset file. Presets use the same schema as a map's
## block, minus "preset" -- a preset naming another would be a resolution loop
## waiting to happen, exactly as it is for lighting profiles.
static func validate_preset(preset_id: String) -> PackedStringArray:
	var raw := _load_raw(preset_path(preset_id))
	if raw.is_empty():
		return PackedStringArray(["data/fx/%s.json is missing or not a JSON object" % preset_id])
	return validate_spec(raw, "data/fx/%s.json" % preset_id, false)
