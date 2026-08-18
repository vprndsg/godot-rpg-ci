## The project still boots: every script compiles, every scene instantiates,
## every asset the code expects is on disk.
##
## These are the cheapest tests in the suite and the ones most likely to catch
## a bad edit, so they run first.
extends TestCase

const SKIP_DIRS: PackedStringArray = ["res://.godot", "res://build"]


func test_every_script_compiles() -> void:
	for path: String in _files_with_suffix("res://", ".gd"):
		# load() surfaces a parse error as a null result. Autoload scripts are
		# the exception -- the engine has already cached its failed attempt by
		# now -- which is why test_autoloads_are_present exists separately.
		var script: Resource = load(path)
		ok(script is GDScript, "%s failed to parse -- see the SCRIPT ERROR above" % path)


func test_every_scene_instantiates() -> void:
	for path: String in _files_with_suffix("res://", ".tscn"):
		var packed: Resource = load(path)
		if not ok(packed is PackedScene, "%s did not load as a PackedScene" % path):
			continue
		var instance: Node = (packed as PackedScene).instantiate()
		if ok(instance != null, "%s instantiated to null" % path):
			instance.free()


func test_autoloads_are_present() -> void:
	for autoload_name: String in ["GameState", "Dialogue", "Router"]:
		ok(tree.root.has_node(NodePath(autoload_name)),
			"autoload '%s' is missing from project.godot" % autoload_name)


func test_input_actions_are_bound() -> void:
	var required: PackedStringArray = [
		"move_up", "move_down", "move_left", "move_right",
		"interact", "quick_save", "continue_game",
		"choice_1", "choice_2", "choice_3", "choice_4",
	]
	for action: String in required:
		if not ok(InputMap.has_action(action),
				"input action '%s' is missing -- run tools/setup_input.gd" % action):
			continue
		ok(InputMap.action_get_events(action).size() > 0,
			"input action '%s' has no keys bound" % action)


func test_generated_assets_exist() -> void:
	for path: String in [
		"res://assets/tiles/tiles.json",
		"res://assets/tiles/terrain.png",
		"res://assets/tiles/terrain.tres",
		"res://assets/sprites/actors.png",
		"res://assets/sprites/actors.json",
		"res://scenes/main.tscn",
	]:
		ok(ResourceLoader.exists(path) or FileAccess.file_exists(path),
			"missing %s -- run tools/gen_art.py and tools/build_tileset.gd" % path)


func test_main_scene_matches_project_setting() -> void:
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	if not not_empty(main_scene, "application/run/main_scene is unset"):
		return
	ok(ResourceLoader.exists(main_scene), "main scene %s does not exist" % main_scene)


func _files_with_suffix(root: String, suffix: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var queue: Array[String] = [root]
	while not queue.is_empty():
		var dir_path: String = queue.pop_front()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for sub: String in dir.get_directories():
			var child := dir_path.path_join(sub)
			if not SKIP_DIRS.has(child):
				queue.append(child)
		for file: String in dir.get_files():
			var name := file.trim_suffix(".remap")
			if name.ends_with(suffix):
				found.append(dir_path.path_join(name))
	found.sort()
	return found
