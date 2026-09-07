## The item catalogue: what exists, what it costs, what using it does.
##
## Items are data for the same reason tiles are. Nothing in the runtime may
## branch on an item's id -- what a bottle does when you drink it is written in
## data/items/items.json and applied by GameState.use_item().
class_name ItemRegistry
extends RefCounted

const PATH := "res://data/items/items.json"

static var _cache: Dictionary = {}


static func data() -> Dictionary:
	if _cache.is_empty():
		if not FileAccess.file_exists(PATH):
			push_error("No file at %s" % PATH)
			return {}
		var f := FileAccess.open(PATH, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		_cache = parsed if parsed is Dictionary else {}
	return _cache


static func all() -> Dictionary:
	var items: Variant = data().get("items", {})
	return items if items is Dictionary else {}


static func names() -> PackedStringArray:
	var out: PackedStringArray = []
	for id: String in all():
		out.append(id)
	out.sort()
	return out


static func exists(item_id: String) -> bool:
	return all().has(item_id)


static func definition(item_id: String) -> Dictionary:
	var def: Variant = all().get(item_id, {})
	return def if def is Dictionary else {}


static func display_name(item_id: String) -> String:
	return String(definition(item_id).get("display_name", item_id.capitalize()))


static func description(item_id: String) -> String:
	return String(definition(item_id).get("description", ""))


## What the item is worth in marks. A shop may charge something else.
static func price(item_id: String) -> int:
	return int(definition(item_id).get("price", 0))


static func use_block(item_id: String) -> Dictionary:
	var use: Variant = definition(item_id).get("use", {})
	return use if use is Dictionary else {}


static func is_usable(item_id: String) -> bool:
	return not use_block(item_id).is_empty()


## The status effect using the item applies, or "" for an item that has none.
static func effect_of(item_id: String) -> String:
	return String(use_block(item_id).get("effect", ""))


## Whether using the item spends it. Default true: most usables are consumed,
## and a tool that is not says so explicitly.
static func is_consumed(item_id: String) -> bool:
	return bool(use_block(item_id).get("consumed", true))


static func use_text(item_id: String) -> String:
	return String(use_block(item_id).get("text", ""))


## Structural problems in the catalogue. Empty means it is sound.
static func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	if data().is_empty():
		errors.append("%s is missing or is not a JSON object" % PATH)
		return errors
	if all().is_empty():
		errors.append("%s defines no items" % PATH)
		return errors
	for item_id: String in all():
		var def: Variant = all()[item_id]
		if not (def is Dictionary):
			errors.append("item '%s' is not an object" % item_id)
			continue
		if String((def as Dictionary).get("display_name", "")).is_empty():
			errors.append("item '%s' has no display_name" % item_id)
		if String((def as Dictionary).get("description", "")).is_empty():
			errors.append("item '%s' has no description" % item_id)
		if price(item_id) <= 0:
			errors.append("item '%s' costs %d marks; a price is what makes it purchasable"
				% [item_id, price(item_id)])
		if not is_usable(item_id):
			continue
		var effect := effect_of(item_id)
		if effect.is_empty():
			errors.append("item '%s' has a `use` block but names no effect" % item_id)
		elif not StatusEffects.exists(effect):
			errors.append("item '%s' applies effect '%s', which data/items/status_effects.json does not define"
				% [item_id, effect])
		if use_text(item_id).is_empty():
			errors.append("item '%s' is usable but says nothing when used" % item_id)
	return errors
