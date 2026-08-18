## Headless test runner.
##
##     godot --headless --path . --script res://tests/run_tests.gd
##     godot --headless --path . --script res://tests/run_tests.gd -- --only maps
##
## Exits non-zero when anything fails, which is all CI needs to gate a merge.
extends SceneTree

const TESTS_DIR := "res://tests"

var _total := 0
var _failed := 0
var _failures: PackedStringArray = []


func _initialize() -> void:
	# Not awaited on purpose: returning from _initialize lets the tree start
	# processing, which is what the async tests need.
	_run_all()


func _run_all() -> void:
	var filter := _arg_value("--only")
	var start_ms := Time.get_ticks_msec()

	print("")
	print("Port Azure test suite")
	print("=====================")

	for script_path: String in _discover():
		var suite_name := script_path.get_file().trim_suffix(".gd")
		if not filter.is_empty() and not suite_name.contains(filter):
			continue
		await _run_suite(script_path, suite_name)

	var elapsed := Time.get_ticks_msec() - start_ms
	print("")
	if _failed == 0:
		print("PASSED  %d tests in %d ms" % [_total, elapsed])
	else:
		print("FAILED  %d of %d tests in %d ms" % [_failed, _total, elapsed])
		print("")
		for line: String in _failures:
			print("  x %s" % line)
	print("")
	quit(0 if _failed == 0 else 1)


func _discover() -> PackedStringArray:
	var found: PackedStringArray = []
	var dir := DirAccess.open(TESTS_DIR)
	if dir == null:
		printerr("Cannot open %s" % TESTS_DIR)
		return found
	for file: String in dir.get_files():
		var name := file.trim_suffix(".remap")
		if name.begins_with("test_") and name.ends_with(".gd"):
			found.append("%s/%s" % [TESTS_DIR, name])
	found.sort()
	return found


func _run_suite(script_path: String, suite_name: String) -> void:
	var script: GDScript = load(script_path)
	if script == null:
		_failed += 1
		_total += 1
		_failures.append("%s: script failed to load" % suite_name)
		return

	var suite: TestCase = script.new()
	suite.tree = self
	suite.before_all()

	print("")
	print("- %s" % suite_name)

	for method: Dictionary in script.get_script_method_list():
		var method_name: String = method["name"]
		if not method_name.begins_with("test_"):
			continue
		_total += 1
		suite.begin(method_name)
		suite.before_each()
		await suite.call(method_name)
		suite.after_each()

		var problems := suite.failures()
		var label := method_name.trim_prefix("test_").replace("_", " ")
		if problems.is_empty():
			print("    ok   %s (%d checks)" % [label, suite.check_count()])
		else:
			_failed += 1
			print("    FAIL %s" % label)
			for problem: String in problems:
				print("         %s" % problem)
				_failures.append("%s / %s: %s" % [suite_name, label, problem])

	suite.after_all()


func _arg_value(flag: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return ""
