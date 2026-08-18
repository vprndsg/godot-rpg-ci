## Minimal test base class. No addon, no plugin, no editor.
##
## Subclass it, write methods named `test_*`, and assert with ok()/equal()/
## fail(). tests/run_tests.gd finds every tests/test_*.gd and runs them.
## Methods may `await` -- the runner awaits whatever they return, so a test
## that needs real frames just awaits `frames(n)`.
class_name TestCase
extends RefCounted

var tree: SceneTree = null

var _current := ""
var _failures: PackedStringArray = []
var _checks := 0


func before_all() -> void:
	pass


func after_all() -> void:
	pass


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func begin(method: String) -> void:
	_current = method
	_failures = []
	_checks = 0


func failures() -> PackedStringArray:
	return _failures


func check_count() -> int:
	return _checks


func ok(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(message)
	return condition


func fail(message: String) -> void:
	_checks += 1
	_failures.append(message)


func equal(actual: Variant, expected: Variant, message: String) -> bool:
	return ok(actual == expected, "%s (got %s, expected %s)" % [message, actual, expected])


func not_empty(value: Variant, message: String) -> bool:
	return ok(value != null and not str(value).is_empty(), message)


## Report a batch of problems produced by a validator, one line each.
func expect_no_errors(errors: PackedStringArray, subject: String) -> void:
	_checks += 1
	for error: String in errors:
		_failures.append("%s: %s" % [subject, error])


## Await n idle frames. Physics runs alongside, so this is also how you let
## movement and collisions settle.
func frames(count: int = 1) -> void:
	for i: int in count:
		await tree.process_frame


func physics_frames(count: int = 1) -> void:
	for i: int in count:
		await tree.physics_frame
