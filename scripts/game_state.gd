## Autoload: the only mutable game-wide state.
##
## Quest and dialogue progress lives in `flags`. Keeping it in one flat
## dictionary means a save file is a JSON blob and tests can assert on it
## without booting the whole game.
extends Node

const SAVE_PATH := "user://savegame.json"
const SAVE_VERSION := 1

signal flag_changed(flag: String, value: Variant)
signal gold_changed(gold: int)
signal inventory_changed(item_id: String, count: int)
signal effect_started(effect_id: String)
signal effect_ended(effect_id: String)

## What the player starts with. Enough for one drink, which is the point:
## the shop is reachable before the errand and comfortable after it.
const STARTING_GOLD := 6

var flags: Dictionary = {}
## Marks in the purse. The code calls it gold; Port Azure says marks.
var gold: int = STARTING_GOLD
## item id -> count. Absent means none; a count never reaches zero and stays.
var inventory: Dictionary = {}
## effect id -> seconds remaining. Ticked here because status is game-wide
## state, not something a scene owns and loses on a map change.
var effects: Dictionary = {}
var current_map: String = ""
var current_spawn: String = "start"
var player_name: String = "Wren"


func get_flag(flag: String, fallback: Variant = false) -> Variant:
	return flags.get(flag, fallback)


func set_flag(flag: String, value: Variant = true) -> void:
	if flags.get(flag) == value:
		return
	flags[flag] = value
	flag_changed.emit(flag, value)


func has_flag(flag: String) -> bool:
	return bool(flags.get(flag, false))


## Evaluates the `requires` block used by dialogue nodes and choices.
## Supported forms: "flag_name", {"flag": true}, {"flag": "value"}.
## An empty requirement always passes.
func requirements_met(requires: Variant) -> bool:
	if requires == null:
		return true
	if requires is String:
		return has_flag(requires)
	if requires is Array:
		for entry: Variant in requires:
			if not requirements_met(entry):
				return false
		return true
	if requires is Dictionary:
		for key: String in requires:
			match key:
				"has_item":
					if not has_item(String(requires[key])):
						return false
				"gold_at_least":
					if gold < int(requires[key]):
						return false
				"effect_active":
					if not effect_active(String(requires[key])):
						return false
				_:
					if get_flag(key, false) != requires[key]:
						return false
		return true
	push_warning("Unsupported `requires` value: %s" % [requires])
	return true


func reset() -> void:
	flags.clear()
	inventory.clear()
	for effect_id: String in effects.keys():
		_end_effect(effect_id)
	gold = STARTING_GOLD
	current_map = ""
	current_spawn = "start"


func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"flags": flags.duplicate(true),
		"gold": gold,
		"inventory": inventory.duplicate(true),
		"effects": effects.duplicate(true),
		"map": current_map,
		"spawn": current_spawn,
		"player_name": player_name,
	}


func from_dict(d: Dictionary) -> bool:
	if int(d.get("version", 0)) != SAVE_VERSION:
		push_warning("Save version mismatch, ignoring save file.")
		return false
	flags = d.get("flags", {}).duplicate(true)
	gold = int(d.get("gold", STARTING_GOLD))
	inventory = d.get("inventory", {}).duplicate(true)
	effects = d.get("effects", {}).duplicate(true)
	current_map = String(d.get("map", ""))
	current_spawn = String(d.get("spawn", "start"))
	player_name = String(d.get("player_name", player_name))
	return true


func save_game() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("Could not open %s for writing" % SAVE_PATH)
		return
	f.store_string(JSON.stringify(to_dict(), "  "))
	f.close()


func load_game() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed is Dictionary and from_dict(parsed)


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


# --------------------------------------------------------------------------
# the purse
# --------------------------------------------------------------------------

func add_gold(amount: int) -> void:
	if amount == 0:
		return
	gold = maxi(0, gold + amount)
	gold_changed.emit(gold)


func can_afford(amount: int) -> bool:
	return gold >= amount


## Spend, or refuse and change nothing. Callers branch on the result rather
## than checking the purse first, so there is one place a price is charged.
func spend_gold(amount: int) -> bool:
	if amount < 0 or not can_afford(amount):
		return false
	add_gold(-amount)
	return true


# --------------------------------------------------------------------------
# the pack
# --------------------------------------------------------------------------

func item_count(item_id: String) -> int:
	return int(inventory.get(item_id, 0))


func has_item(item_id: String) -> bool:
	return item_count(item_id) > 0


func add_item(item_id: String, count: int = 1) -> void:
	if count <= 0:
		return
	if not ItemRegistry.exists(item_id):
		push_warning("Refusing to add unknown item '%s'" % item_id)
		return
	inventory[item_id] = item_count(item_id) + count
	inventory_changed.emit(item_id, item_count(item_id))


## Take items out of the pack. False -- and nothing removed -- if they are not
## all there, so a partial spend can never happen.
func remove_item(item_id: String, count: int = 1) -> bool:
	if count <= 0 or item_count(item_id) < count:
		return false
	var left := item_count(item_id) - count
	if left > 0:
		inventory[item_id] = left
	else:
		inventory.erase(item_id)
	inventory_changed.emit(item_id, left)
	return true


## Buy one item from a merchant. The shop decides whether it is for sale and
## what it costs; this decides whether the purse can bear it.
##
## Returns "" on success, or a short reason the sale did not happen -- which is
## what lets a conversation say something specific instead of just failing.
func buy(shop_id: String, item_id: String) -> String:
	if not Shop.exists(shop_id):
		return "no such shop"
	if not Shop.sells(shop_id, item_id):
		return "not for sale here"
	var price := Shop.price_of(shop_id, item_id)
	if not spend_gold(price):
		return "not enough marks"
	add_item(item_id)
	return ""


## Use one item out of the pack: apply whatever effect it declares, and spend
## it if it is consumable. False when there is none, or it does nothing.
func use_item(item_id: String) -> bool:
	if not has_item(item_id) or not ItemRegistry.is_usable(item_id):
		return false
	if ItemRegistry.is_consumed(item_id) and not remove_item(item_id):
		return false
	var effect := ItemRegistry.effect_of(item_id)
	if not effect.is_empty():
		apply_effect(effect)
	return true


## The first thing in the pack that can be used, or "". This is what the use
## key reaches for, so a player with one bottle never opens a menu for it.
func first_usable_item() -> String:
	for item_id: String in inventory:
		if ItemRegistry.is_usable(item_id):
			return item_id
	return ""


# --------------------------------------------------------------------------
# status effects
# --------------------------------------------------------------------------

## Start (or restart) a timed effect. Re-applying refreshes the clock rather
## than stacking: two ales are a longer evening, not a stronger one.
func apply_effect(effect_id: String) -> bool:
	if not StatusEffects.exists(effect_id):
		push_warning("Unknown status effect '%s'" % effect_id)
		return false
	var fresh := not effect_active(effect_id)
	effects[effect_id] = StatusEffects.duration(effect_id)
	if fresh:
		effect_started.emit(effect_id)
	return true


func effect_active(effect_id: String) -> bool:
	return effect_remaining(effect_id) > 0.0


func effect_remaining(effect_id: String) -> float:
	return float(effects.get(effect_id, 0.0))


func clear_effect(effect_id: String) -> void:
	if effect_active(effect_id):
		_end_effect(effect_id)


## The combined value of one modifier across every active effect.
##
## Gameplay asks this and never asks which effects are running, which is what
## keeps a new drink out of the movement code.
func modifier(key: String, fallback: float = 1.0) -> float:
	var value := fallback
	for effect_id: String in effects:
		var mods := StatusEffects.modifiers(effect_id)
		if mods.has(key):
			value *= float(mods[key])
	return value


func _process(delta: float) -> void:
	if effects.is_empty():
		return
	for effect_id: String in effects.keys():
		var left := effect_remaining(effect_id) - delta
		if left <= 0.0:
			_end_effect(effect_id)
		else:
			effects[effect_id] = left


func _end_effect(effect_id: String) -> void:
	effects.erase(effect_id)
	effect_ended.emit(effect_id)
