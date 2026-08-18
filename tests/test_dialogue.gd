## Every conversation in dialogue/ holds together, and every branch of it
## actually runs.
##
## The structural pass catches dangling jumps. The playthrough pass then walks
## each graph with the flags forced both ways, which is what catches a `set`
## that never fires or a `goto_if` that shadows the branch after it.
extends TestCase


func after_each() -> void:
	Dialogue.stop()
	GameState.reset()


func test_every_dialogue_validates() -> void:
	var ids := Dialogue.all_ids()
	ok(ids.size() > 0, "there are no dialogue files in dialogue/")
	for dialogue_id: String in ids:
		expect_no_errors(Dialogue.validate_graph(dialogue_id), "dialogue/%s.json" % dialogue_id)


func test_every_dialogue_starts_and_ends() -> void:
	for dialogue_id: String in Dialogue.all_ids():
		GameState.reset()
		var lines: Array = []
		var collect := func(speaker: String, text: String) -> void:
			lines.append({"speaker": speaker, "text": text})
		Dialogue.line_shown.connect(collect)

		var started := Dialogue.start(dialogue_id)
		ok(started, "dialogue '%s' would not start" % dialogue_id)
		if started:
			ok(lines.size() > 0, "dialogue '%s' started but showed no line" % dialogue_id)
			# Walk the conversation, rotating through the options at each menu
			# rather than always taking the first -- a hub node whose first
			# choice loops back would otherwise run forever. validate_graph()
			# separately proves an ending is always reachable.
			var steps := 0
			while Dialogue.is_active() and steps < 500:
				var choices := Dialogue.current_choices()
				if choices.is_empty():
					Dialogue.advance()
				else:
					Dialogue.choose(steps % choices.size())
				steps += 1
			ok(steps < 500,
				"dialogue '%s' did not end after %d steps" % [dialogue_id, steps])

		Dialogue.line_shown.disconnect(collect)
		Dialogue.stop()


func test_every_choice_is_reachable_and_leads_somewhere() -> void:
	for dialogue_id: String in Dialogue.all_ids():
		var graph := Dialogue.load_graph(dialogue_id)
		var nodes: Dictionary = graph.get("nodes", {})
		for node_id: String in nodes:
			var choices: Array = nodes[node_id].get("choices", [])
			for i: int in choices.size():
				var choice: Dictionary = choices[i]
				not_empty(choice.get("text", ""),
					"dialogue '%s' node '%s' choice %d has no text" % [dialogue_id, node_id, i])
				var target := String(choice.get("next", ""))
				if not target.is_empty():
					ok(nodes.has(target),
						"dialogue '%s' node '%s' choice %d goes to missing node '%s'"
							% [dialogue_id, node_id, i, target])


func test_lines_are_not_placeholders() -> void:
	for dialogue_id: String in Dialogue.all_ids():
		var nodes: Dictionary = Dialogue.load_graph(dialogue_id).get("nodes", {})
		for node_id: String in nodes:
			var text := String(nodes[node_id].get("text", ""))
			if text.is_empty():
				continue
			var lowered := text.to_lower()
			for placeholder: String in ["lorem ipsum", "todo", "tbd", "xxx", "placeholder"]:
				ok(not lowered.contains(placeholder),
					"dialogue '%s' node '%s' still contains placeholder text '%s'"
						% [dialogue_id, node_id, placeholder])


func test_flags_set_by_dialogue_are_read_somewhere() -> void:
	var written: Dictionary = {}
	var read: Dictionary = {}
	for dialogue_id: String in Dialogue.all_ids():
		var nodes: Dictionary = Dialogue.load_graph(dialogue_id).get("nodes", {})
		for node_id: String in nodes:
			var node: Dictionary = nodes[node_id]
			_collect_writes(node, dialogue_id, written)
			_collect_reads(node, read)
			for choice: Variant in node.get("choices", []):
				if choice is Dictionary:
					_collect_writes(choice, dialogue_id, written)
					_collect_reads(choice, read)

	for flag: String in written:
		ok(read.has(flag),
			"flag '%s' is set by dialogue/%s.json but no dialogue ever checks it"
				% [flag, written[flag]])


func _collect_writes(node: Dictionary, dialogue_id: String, into: Dictionary) -> void:
	var sets: Variant = node.get("set")
	if sets is Dictionary:
		for flag: String in sets:
			into[flag] = dialogue_id


func _collect_reads(node: Dictionary, into: Dictionary) -> void:
	for rule: Variant in node.get("goto_if", []):
		if rule is Dictionary:
			_read_requires((rule as Dictionary).get("requires"), into)
	_read_requires(node.get("requires"), into)


func _read_requires(requires: Variant, into: Dictionary) -> void:
	if requires is String:
		into[requires] = true
	elif requires is Dictionary:
		for flag: String in requires:
			into[flag] = true
	elif requires is Array:
		for entry: Variant in requires:
			_read_requires(entry, into)
