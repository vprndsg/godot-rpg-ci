## Autoload: the only mutable game-wide state.
##
## Quest and dialogue progress lives in `flags`. Keeping it in one flat
## dictionary means a save file is a JSON blob and tests can assert on it
## without booting the whole game.
extends Node

const SAVE_PATH := "user://savegame.json"
const SAVE_VERSION := 1

signal flag_changed(flag: String, value: Variant)

var flags: Dictionary = {}
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
		for flag: String in requires:
			if get_flag(flag, false) != requires[flag]:
				return false
		return true
	push_warning("Unsupported `requires` value: %s" % [requires])
	return true


func reset() -> void:
	flags.clear()
	current_map = ""
	current_spawn = "start"


func to_dict() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"flags": flags.duplicate(true),
		"map": current_map,
		"spawn": current_spawn,
		"player_name": player_name,
	}


func from_dict(d: Dictionary) -> bool:
	if int(d.get("version", 0)) != SAVE_VERSION:
		push_warning("Save version mismatch, ignoring save file.")
		return false
	flags = d.get("flags", {}).duplicate(true)
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
