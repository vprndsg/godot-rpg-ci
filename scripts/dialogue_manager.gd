## Autoload: runs conversations defined by the JSON files in dialogue/.
##
## The manager owns no UI. It walks the graph and emits signals; scenes/ui/
## dialogue_box.tscn listens and draws. That split is what lets tests/
## exercise every branch of every conversation headlessly.
extends Node

const DIALOGUE_DIR := "res://dialogue"

signal line_shown(speaker: String, text: String)
signal choices_offered(choices: Array)
signal dialogue_started(dialogue_id: String)
signal dialogue_finished(dialogue_id: String)

var active_id: String = ""
var _graph: Dictionary = {}
var _node_id: String = ""


func is_active() -> bool:
	return active_id != ""


static func path_for(dialogue_id: String) -> String:
	return "%s/%s.json" % [DIALOGUE_DIR, dialogue_id]


static func exists(dialogue_id: String) -> bool:
	return FileAccess.file_exists(path_for(dialogue_id))


## Returns the parsed graph, or an empty Dictionary if it is missing/invalid.
static func load_graph(dialogue_id: String) -> Dictionary:
	var path := path_for(dialogue_id)
	if not FileAccess.file_exists(path):
		push_error("No dialogue file at %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_error("%s is not a JSON object" % path)
		return {}
	return parsed


## Show a single line with no graph behind it -- signs, portal prompts,
## anything that just needs one box on screen.
func show_line(speaker: String, text: String) -> bool:
	if is_active():
		return false
	_graph = {"start": "_line", "nodes": {"_line": {"speaker": speaker, "text": text}}}
	active_id = "_line"
	dialogue_started.emit(active_id)
	_goto("_line")
	return true


func start(dialogue_id: String) -> bool:
	if is_active():
		return false
	var graph := load_graph(dialogue_id)
	if graph.is_empty():
		return false
	_graph = graph
	active_id = dialogue_id
	dialogue_started.emit(dialogue_id)
	_goto(String(graph.get("start", "")))
	return true


## Advance a plain line. No-op while choices are on screen -- the player has
## to pick one, so the UI calls choose() instead.
func advance() -> void:
	if not is_active():
		return
	var node := _current()
	if _visible_choices(node).size() > 0:
		return
	_goto(String(node.get("next", "")))


func choose(index: int) -> void:
	if not is_active():
		return
	var choices := _visible_choices(_current())
	if index < 0 or index >= choices.size():
		push_warning("Choice %d out of range" % index)
		return
	var choice: Dictionary = choices[index]
	_apply_effects(choice)
	_goto(String(choice.get("next", "")))


func stop() -> void:
	if not is_active():
		return
	var finished := active_id
	active_id = ""
	_graph = {}
	_node_id = ""
	dialogue_finished.emit(finished)


## Choices currently on offer, already filtered by flags. Empty on a plain line.
func current_choices() -> Array:
	return _visible_choices(_current()) if is_active() else []


## Id of the node being shown, for tests and debugging.
func current_node_id() -> String:
	return _node_id


func _current() -> Dictionary:
	return _graph.get("nodes", {}).get(_node_id, {})


## Choices whose `requires` is satisfied by the current flags.
func _visible_choices(node: Dictionary) -> Array:
	var out: Array = []
	for choice: Variant in node.get("choices", []):
		if choice is Dictionary and GameState.requirements_met(choice.get("requires")):
			out.append(choice)
	return out


func _apply_effects(node: Dictionary) -> void:
	var sets: Variant = node.get("set")
	if sets is Dictionary:
		for flag: String in sets:
			GameState.set_flag(flag, sets[flag])


func _goto(next_id: String) -> void:
	if next_id.is_empty():
		stop()
		return
	var nodes: Dictionary = _graph.get("nodes", {})
	if not nodes.has(next_id):
		push_error("Dialogue '%s' jumps to unknown node '%s'" % [active_id, next_id])
		stop()
		return
	_node_id = next_id
	var node: Dictionary = nodes[next_id]

	# A node can redirect based on flags before anything is shown, which is how
	# an NPC says something different after you finish their quest.
	var redirect: Variant = node.get("goto_if")
	if redirect is Array:
		for rule: Variant in redirect:
			if rule is Dictionary and GameState.requirements_met(rule.get("requires")):
				_goto(String(rule.get("next", "")))
				return

	_apply_effects(node)
	var speaker := String(node.get("speaker", _graph.get("speaker_default", "")))
	line_shown.emit(speaker, String(node.get("text", "")))

	var choices := _visible_choices(node)
	if choices.size() > 0:
		var labels: Array = []
		for c: Dictionary in choices:
			labels.append(String(c.get("text", "...")))
		choices_offered.emit(labels)


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

## Every dialogue id under dialogue/, sorted.
static func all_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(DIALOGUE_DIR)
	if dir == null:
		push_error("Cannot open %s" % DIALOGUE_DIR)
		return out
	for file: String in dir.get_files():
		var name := file.trim_suffix(".remap")
		if name.ends_with(".json"):
			out.append(name.trim_suffix(".json"))
	out.sort()
	return out


## Structural problems in one conversation. Empty means it is sound.
##
## A dangling `next` only shows up at runtime, in the middle of a
## conversation, on the one branch nobody clicked. Checking it here means CI
## catches it instead of a player.
static func validate_graph(dialogue_id: String) -> PackedStringArray:
	var errors: PackedStringArray = []
	var path := path_for(dialogue_id)
	if not FileAccess.file_exists(path):
		errors.append("no file at %s" % path)
		return errors

	var f := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()
	var parse_result := json.parse(f.get_as_text())
	f.close()
	if parse_result != OK:
		errors.append("invalid JSON at line %d: %s" % [json.get_error_line(), json.get_error_message()])
		return errors
	if not (json.data is Dictionary):
		errors.append("top level must be a JSON object")
		return errors

	var graph: Dictionary = json.data
	var nodes: Variant = graph.get("nodes")
	if not (nodes is Dictionary) or (nodes as Dictionary).is_empty():
		errors.append("no 'nodes' object")
		return errors
	var node_map: Dictionary = nodes

	var start := String(graph.get("start", ""))
	if start.is_empty():
		errors.append("no 'start' node named")
	elif not node_map.has(start):
		errors.append("start node '%s' is not defined" % start)

	# every jump lands on a real node
	var edges: Dictionary = {}
	for node_id: String in node_map:
		var node: Variant = node_map[node_id]
		if not (node is Dictionary):
			errors.append("node '%s' is not an object" % node_id)
			continue
		var targets: PackedStringArray = []

		var next := String((node as Dictionary).get("next", ""))
		if not next.is_empty():
			targets.append(next)

		for rule: Variant in (node as Dictionary).get("goto_if", []):
			if not (rule is Dictionary):
				errors.append("node '%s' has a goto_if entry that is not an object" % node_id)
				continue
			var jump := String((rule as Dictionary).get("next", ""))
			if jump.is_empty():
				errors.append("node '%s' has a goto_if with no 'next'" % node_id)
			else:
				targets.append(jump)

		var choices: Variant = (node as Dictionary).get("choices", [])
		for choice: Variant in choices:
			if not (choice is Dictionary):
				errors.append("node '%s' has a choice that is not an object" % node_id)
				continue
			if String((choice as Dictionary).get("text", "")).is_empty():
				errors.append("node '%s' has a choice with no text" % node_id)
			var choice_next := String((choice as Dictionary).get("next", ""))
			if not choice_next.is_empty():
				targets.append(choice_next)

		var has_text: bool = not String((node as Dictionary).get("text", "")).is_empty()
		var goto_rules: Array = (node as Dictionary).get("goto_if", [])
		var redirects_away: bool = not goto_rules.is_empty()
		if not has_text and not redirects_away:
			errors.append("node '%s' has no text and nothing to redirect to" % node_id)

		for target: String in targets:
			if not node_map.has(target):
				errors.append("node '%s' jumps to '%s', which does not exist" % [node_id, target])
		edges[node_id] = targets

	# every node can still reach an ending. A conversation you cannot leave
	# looks fine in a diff and traps the player in a menu forever.
	var ends_here: Dictionary = {}
	for node_id: String in node_map:
		var node: Variant = node_map[node_id]
		if not (node is Dictionary):
			continue
		var choices: Array = (node as Dictionary).get("choices", [])
		if choices.is_empty():
			if String((node as Dictionary).get("next", "")).is_empty():
				ends_here[node_id] = true
		else:
			for choice: Variant in choices:
				if choice is Dictionary and String((choice as Dictionary).get("next", "")).is_empty():
					ends_here[node_id] = true
					break

	if ends_here.is_empty():
		errors.append("no node ever ends the conversation")
	else:
		var can_end: Dictionary = ends_here.duplicate()
		var changed := true
		while changed:
			changed = false
			for node_id: String in edges:
				if can_end.has(node_id):
					continue
				for target: String in edges[node_id]:
					if can_end.has(target):
						can_end[node_id] = true
						changed = true
						break
		for node_id: String in node_map:
			if not can_end.has(node_id):
				errors.append("node '%s' can never reach an ending -- the player would be stuck" % node_id)

	# no orphans: a node nothing reaches is dead content, usually a typo
	if node_map.has(start):
		var seen: Dictionary = {start: true}
		var queue: Array[String] = [start]
		while not queue.is_empty():
			var node_id: String = queue.pop_front()
			for target: String in edges.get(node_id, PackedStringArray()):
				if node_map.has(target) and not seen.has(target):
					seen[target] = true
					queue.append(target)
		for node_id: String in node_map:
			if not seen.has(node_id):
				errors.append("node '%s' is unreachable from '%s'" % [node_id, start])

	return errors
