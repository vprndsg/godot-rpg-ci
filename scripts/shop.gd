## A merchant's stock list, defined by data/shops/<id>.json and named by an
## NPC's `shop` field.
##
## The shop owns prices and availability. What the conversation looks like is
## the dialogue's business: a `buy` on a choice asks the shop for one item, and
## the shop is what decides whether that is a thing this merchant sells.
class_name Shop
extends RefCounted

const DIR := "res://data/shops"

static var _cache: Dictionary = {}


static func path_for(shop_id: String) -> String:
	return "%s/%s.json" % [DIR, shop_id]


static func exists(shop_id: String) -> bool:
	return FileAccess.file_exists(path_for(shop_id))


static func all_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		push_error("Cannot open %s" % DIR)
		return out
	for file: String in dir.get_files():
		var file_name := file.trim_suffix(".remap")
		if file_name.ends_with(".json"):
			out.append(file_name.trim_suffix(".json"))
	out.sort()
	return out


static func load_def(shop_id: String) -> Dictionary:
	if _cache.has(shop_id):
		return _cache[shop_id]
	var path := path_for(shop_id)
	if not FileAccess.file_exists(path):
		push_error("No shop at %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	var def: Dictionary = parsed if parsed is Dictionary else {}
	_cache[shop_id] = def
	return def


static func display_name(shop_id: String) -> String:
	return String(load_def(shop_id).get("display_name", shop_id.capitalize()))


static func stock(shop_id: String) -> Array:
	var entries: Variant = load_def(shop_id).get("stock", [])
	return entries if entries is Array else []


static func item_ids(shop_id: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for entry: Variant in stock(shop_id):
		if entry is Dictionary:
			out.append(String((entry as Dictionary).get("item", "")))
	return out


static func sells(shop_id: String, item_id: String) -> bool:
	return item_ids(shop_id).has(item_id)


## What this merchant charges. An entry with no `price` charges the
## catalogue price, so a shop file only records where it disagrees.
static func price_of(shop_id: String, item_id: String) -> int:
	for entry: Variant in stock(shop_id):
		if entry is Dictionary and String((entry as Dictionary).get("item", "")) == item_id:
			return int((entry as Dictionary).get("price", ItemRegistry.price(item_id)))
	return 0


## The one shop that sells `item_id`, or "" -- used by dialogue validation to
## prove a `buy` choice is standing in front of a merchant who stocks it.
static func shops_selling(item_id: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for shop_id: String in all_ids():
		if sells(shop_id, item_id):
			out.append(shop_id)
	return out


## Structural problems in one shop. Empty means it is sound.
static func validate(shop_id: String) -> PackedStringArray:
	var errors: PackedStringArray = []
	var def := load_def(shop_id)
	if def.is_empty():
		errors.append("data/shops/%s.json is missing or is not a JSON object" % shop_id)
		return errors
	if String(def.get("display_name", "")).is_empty():
		errors.append("shop '%s' has no display_name" % shop_id)
	var entries := stock(shop_id)
	if entries.is_empty():
		errors.append("shop '%s' sells nothing" % shop_id)
	for i: int in entries.size():
		var entry: Variant = entries[i]
		if not (entry is Dictionary):
			errors.append("shop '%s' stock entry %d is not an object" % [shop_id, i])
			continue
		var item_id := String((entry as Dictionary).get("item", ""))
		if item_id.is_empty():
			errors.append("shop '%s' stock entry %d names no item" % [shop_id, i])
			continue
		if not ItemRegistry.exists(item_id):
			errors.append("shop '%s' sells '%s', which data/items/items.json does not define"
				% [shop_id, item_id])
			continue
		if price_of(shop_id, item_id) <= 0:
			errors.append("shop '%s' sells '%s' for %d marks"
				% [shop_id, item_id, price_of(shop_id, item_id)])
	return errors
