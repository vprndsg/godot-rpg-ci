## Rewrites the [input] section of project.godot from the table below.
##
##     godot --headless --path . --script res://tools/setup_input.gd
##
## Input actions are stored as serialised InputEvent objects, which are painful
## and version-specific to type by hand. Editing this table and re-running is
## the supported way to change the keymap headlessly.
extends SceneTree

const DEADZONE := 0.2

## action name -> list of physical key names (see the KEY_* constants).
const BINDINGS := {
	"move_up": ["W", "UP"],
	"move_down": ["S", "DOWN"],
	"move_left": ["A", "LEFT"],
	"move_right": ["D", "RIGHT"],
	"interact": ["E", "SPACE", "ENTER"],
	"continue_game": ["C"],
	"quick_save": ["F5"],
	"toggle_fullscreen": ["F"],
	"choice_1": ["1", "Kp 1"],
	"choice_2": ["2", "Kp 2"],
	"choice_3": ["3", "Kp 3"],
	"choice_4": ["4", "Kp 4"],
}


func _initialize() -> void:
	for action: String in BINDINGS:
		var events: Array = []
		for key_name: String in BINDINGS[action]:
			var keycode := OS.find_keycode_from_string(key_name)
			if keycode == KEY_NONE:
				printerr("Unknown key name '%s' for action '%s'" % [key_name, action])
				quit(1)
				return
			var event := InputEventKey.new()
			event.device = -1
			event.physical_keycode = keycode
			events.append(event)
		ProjectSettings.set_setting("input/" + action, {
			"deadzone": DEADZONE,
			"events": events,
		})

	var err := ProjectSettings.save()
	if err != OK:
		printerr("Could not save project.godot (error %d)" % err)
		quit(1)
		return
	print("Wrote %d input actions to project.godot." % BINDINGS.size())
	quit(0)
