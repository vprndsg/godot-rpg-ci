## Owns every screen and atmospheric effect: builds them, binds them, sweeps
## them away on a map change.
##
## This used to be a reserved `Fx` node hanging off `WorldLighting`, which was
## the right hook and the wrong owner: fog, grading and quantization are not
## lighting, they are what happens to the frame *after* lighting, and growing
## them onto the lighting runtime would have made one node responsible for
## ambient tone, sun angle, point lights, occlusion and weather. So they have
## their own owner, and the dependency runs one way -- WorldFx knows nothing
## about WorldLighting, and WorldLighting knows nothing about WorldFx.
##
## ```
##   World
##   +-- Lighting   ambient, sun, tile-driven point lights
##   +-- Planes     background / playable / foreground scenery
##   +-- Fx         THIS: the effect stack, screen and world space
##   +-- DialogueBox
## ```
##
## Nothing here knows what an effect *is*. `data/fx/effects.json` declares the
## vocabulary -- shader, space, order, parameters -- and this node turns a
## resolved stack into ColorRects with ShaderMaterials. Adding an effect is a
## shader plus a catalog entry; there is no case statement to extend.
##
## Two spaces:
##
## - **screen** -- a full-rect ColorRect on the fx CanvasLayer, above every
##   world plane and below all UI. Grading stops at the world's edge; the
##   dialogue box is never graded.
## - **world** -- a ColorRect covering the map, at a z_index between the depth
##   planes, so a mist can sit behind the foreground trees and in front of the
##   player.
class_name WorldFx
extends Node2D

## How many screen-reading effects a map may stack before this is a
## performance problem worth saying out loud. Each one is a backbuffer copy,
## and this build runs in browsers under GL Compatibility.
const SCREEN_READ_BUDGET := 2

signal effects_changed(count: int)

var screen_layer: CanvasLayer
var world_root: Node2D

var _effects: Array[ColorRect] = []
var _map_bounds := Rect2()


func _ready() -> void:
	_ensure_children()


## Apply a map's whole atmosphere: resolve its fx block, tear down the old
## stack, build the new one. World.enter() calls this on every map change.
## A map with no "fx" block ends up with nothing, which is exactly what the
## world looked like before this existed.
func apply_map(map: MapData) -> void:
	_map_bounds = Iso.grid_bounds(Vector2i(map.width, map.height))
	apply_stack(FxConfig.resolve(map.fx), map.id)


## Build a resolved stack (FxConfig.resolve shape). Separated from apply_map()
## so a cutscene, a weather controller or a test can drive the same path
## without inventing a MapData.
func apply_stack(stack: Array[Dictionary], subject: String = "") -> void:
	_ensure_children()
	clear()
	var screen_reads := 0
	for spec: Dictionary in stack:
		var rect := _build(spec)
		if rect == null:
			continue
		_effects.append(rect)
		if bool(spec.get("reads_screen", false)):
			screen_reads += 1
	if screen_reads > SCREEN_READ_BUDGET:
		push_warning("Map '%s' stacks %d screen-reading effects; each is a backbuffer copy "
			% [subject, screen_reads] + "and this build runs in browsers. Fold them into fewer.")
	effects_changed.emit(_effects.size())


func clear() -> void:
	for rect: ColorRect in _effects:
		if is_instance_valid(rect):
			rect.get_parent().remove_child(rect)
			rect.queue_free()
	_effects.clear()


func effect_count() -> int:
	return _effects.size()


## The live effect of a given type, or null. Lets a cutscene tween a fog's
## density without rebuilding the stack.
func effect(type: String) -> ColorRect:
	for rect: ColorRect in _effects:
		if is_instance_valid(rect) and rect.get_meta("fx_type", "") == type:
			return rect
	return null


## The types currently running, in compositing order. Tests assert against
## this rather than walking two containers.
func active_types() -> PackedStringArray:
	var out: PackedStringArray = []
	for rect: ColorRect in _effects:
		if is_instance_valid(rect):
			out.append(String(rect.get_meta("fx_type", "")))
	return out


## Where a world-space effect composites: halfway between the playable plane
## and the foreground, so a mist sits in front of the player and behind the
## branches. Derived from the plane stack rather than written down, so the two
## cannot drift apart. An effect that wants to be somewhere else is a parameter
## this project has not needed yet.
static func world_z() -> int:
	return (int(ScenePlanes.PLANE_Z[ScenePlanes.PLAYABLE])
		+ int(ScenePlanes.PLANE_Z[ScenePlanes.FOREGROUND])) / 2


func _build(spec: Dictionary) -> ColorRect:
	var shader_path := String(spec.get("shader", ""))
	if not ResourceLoader.exists(shader_path):
		push_warning("Effect '%s' names shader '%s', which is missing" % [spec.get("type", "?"), shader_path])
		return null
	var material := ShaderMaterial.new()
	material.shader = load(shader_path)
	for name: String in spec.get("params", {}):
		material.set_shader_parameter(name, spec["params"][name])

	var rect := ColorRect.new()
	rect.name = "Fx_%s" % spec.get("type", "effect")
	rect.set_meta("fx_type", String(spec.get("type", "")))
	rect.material = material
	# The shaders paint every pixel themselves; the rect is only geometry.
	rect.color = Color(1, 1, 1, 1)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if String(spec.get("space", "screen")) == "world":
		rect.position = _map_bounds.position
		rect.size = _map_bounds.size
		rect.z_index = world_z()
		world_root.add_child(rect)
	else:
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		screen_layer.add_child(rect)
	return rect


## Children are built in code so no .tscn carries effect state, and built
## lazily so tests can drive this node before it enters a tree -- the same
## reasoning as WorldLighting's.
func _ensure_children() -> void:
	if screen_layer != null:
		return
	screen_layer = CanvasLayer.new()
	screen_layer.name = "ScreenFx"
	# Above every world plane, below every piece of UI. The whole reason the
	# layer numbers live in one file is so that ordering is a fact, not a
	# convention somebody has to remember.
	screen_layer.layer = Presentation.layer("screen_fx")
	add_child(screen_layer)

	world_root = Node2D.new()
	world_root.name = "WorldFx"
	add_child(world_root)
