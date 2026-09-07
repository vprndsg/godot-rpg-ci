## The catalogue of timed states an item can put the player in.
##
## An effect is data: a duration and a bag of modifiers. Gameplay never asks
## "is the player tipsy" -- it asks GameState.modifier("speed_scale"), so a new
## drink is a JSON entry and no code at all.
class_name StatusEffects
extends RefCounted

const PATH := "res://data/items/status_effects.json"

## The vocabulary a modifier may use, and the range it may take. Anything else
## in an effect's `modifiers` is a typo that would silently do nothing, so the
## validator rejects it.
const MODIFIERS := {
	"speed_scale": [0.25, 3.0],
}

static var _cache: Dictionary = {}


static func data() -> Dictionary:
	if _cache.is_empty():
		_cache = _load(PATH)
	return _cache


static func _load(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("No file at %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


static func all() -> Dictionary:
	var effects: Variant = data().get("effects", {})
	return effects if effects is Dictionary else {}


static func names() -> PackedStringArray:
	var out: PackedStringArray = []
	for id: String in all():
		out.append(id)
	out.sort()
	return out


static func exists(effect_id: String) -> bool:
	return all().has(effect_id)


static func definition(effect_id: String) -> Dictionary:
	var def: Variant = all().get(effect_id, {})
	return def if def is Dictionary else {}


static func display_name(effect_id: String) -> String:
	return String(definition(effect_id).get("display_name", effect_id.capitalize()))


## Seconds the effect lasts. 0.0 would be an effect nobody could notice, so
## the validator requires more.
static func duration(effect_id: String) -> float:
	return float(definition(effect_id).get("duration", 0.0))


static func modifiers(effect_id: String) -> Dictionary:
	var mods: Variant = definition(effect_id).get("modifiers", {})
	return mods if mods is Dictionary else {}


static func start_text(effect_id: String) -> String:
	return String(definition(effect_id).get("start_text", ""))


static func end_text(effect_id: String) -> String:
	return String(definition(effect_id).get("end_text", ""))


## Structural problems in the catalogue. Empty means it is sound.
static func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if data().is_empty():
		errors.append("%s is missing or is not a JSON object" % PATH)
		return errors
	if all().is_empty():
		errors.append("%s defines no effects" % PATH)
		return errors
	for effect_id: String in all():
		var def: Variant = all()[effect_id]
		if not (def is Dictionary):
			errors.append("effect '%s' is not an object" % effect_id)
			continue
		if String((def as Dictionary).get("display_name", "")).is_empty():
			errors.append("effect '%s' has no display_name" % effect_id)
		if duration(effect_id) <= 0.0:
			errors.append("effect '%s' has a duration of %s; it would end before it was felt"
				% [effect_id, duration(effect_id)])
		var mods := modifiers(effect_id)
		if mods.is_empty():
			errors.append("effect '%s' has no modifiers, so nothing about it is observable" % effect_id)
		for key: String in mods:
			if not MODIFIERS.has(key):
				errors.append("effect '%s' names modifier '%s', which no gameplay code reads"
					% [effect_id, key])
				continue
			var value: Variant = mods[key]
			if not (value is float or value is int):
				errors.append("effect '%s' modifier '%s' is not a number" % [effect_id, key])
				continue
			var range: Array = MODIFIERS[key]
			if float(value) < float(range[0]) or float(value) > float(range[1]):
				errors.append("effect '%s' modifier '%s' is %s, outside [%s, %s]"
					% [effect_id, key, value, range[0], range[1]])
	return errors
