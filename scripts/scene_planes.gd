## The depth planes a scene is composed from, and who owns what.
##
## The tile world used to be everything visible. It is now one plane of five,
## and the only one that is gameplay:
##
## ```
##   screen_foreground   CanvasLayer   fog-side vignettes, framing, letterbox art
##   foreground          Node2D  z+    giant cropped trunks, branches over the lens
##   playable            Node2D  ysort THE WORLD: MapLoader, actors, collision,
##                                     elevation, interactables  <- gameplay lives here
##   far_background      Node2D  z-    distant ridges, silhouettes, atmosphere
##   screen_background   CanvasLayer   flat skies behind everything
## ```
##
## Rules that make this worth having:
##
## - **Only `playable` is y-sorted.** Depth inside the world is ground
##   contact, as it always was. The other planes are ordered by their `sort`
##   key and by being different planes, which is deterministic and cheap.
## - **Only `playable` contains gameplay.** Nothing in a scenery plane
##   collides, is interacted with, or is walked on. `tests/test_scenery.gd`
##   asserts no physics body ever appears in one.
## - **Scenery is placed by its anchor**, so a 400px redwood in `foreground`
##   and a villager in `playable` are positioned by the same rule.
## - The two CanvasLayer planes sit on the layer numbers
##   `data/rendering.json` assigns, below every screen effect and far below
##   the UI.
##
## `scripts/scenery_registry.gd` is the metadata; maps place props with a
## `"scenery"` array; docs/architecture/scenery.md is the design.
class_name ScenePlanes
extends Node2D

const SCREEN_BACKGROUND := "screen_background"
const FAR_BACKGROUND := "far_background"
const PLAYABLE := "playable"
const FOREGROUND := "foreground"
const SCREEN_FOREGROUND := "screen_foreground"

## Back to front. Index in this array is the only thing that decides which
## plane draws over which, so the ordering is one list and not five numbers
## scattered across a scene file.
const PLANES: PackedStringArray = [
	SCREEN_BACKGROUND, FAR_BACKGROUND, PLAYABLE, FOREGROUND, SCREEN_FOREGROUND,
]

## Planes that live on a CanvasLayer and therefore never move with the world.
const SCREEN_PLANES: PackedStringArray = [SCREEN_BACKGROUND, SCREEN_FOREGROUND]

## z_index for the world-space planes. Far apart so a prop's own `sort` can
## order things inside a plane without ever reaching the next one.
const PLANE_Z := {FAR_BACKGROUND: -100, PLAYABLE: 0, FOREGROUND: 100}

var _planes: Dictionary = {}
## Props that have to be repositioned as the view moves: parallaxed,
## camera-relative or screen-space. World-space props at parallax 1.0 are
## never in here, so a map with no scenery costs nothing per frame.
var _moving: Array[SceneryProp] = []
var _registry: SceneryRegistry = null


static func is_screen_plane(plane: String) -> bool:
	return SCREEN_PLANES.has(plane)


func _ready() -> void:
	_build()


## The container for one plane. A Node2D for world planes, a CanvasLayer for
## screen ones -- callers that only want to parent something do not need to
## know which.
func plane(plane_name: String) -> Node:
	_build()
	return _planes.get(plane_name)


func playable() -> Node2D:
	return plane(PLAYABLE) as Node2D


func far_background() -> Node2D:
	return plane(FAR_BACKGROUND) as Node2D


func foreground() -> Node2D:
	return plane(FOREGROUND) as Node2D


## Use a registry other than the shipped one. The seam a test drives, and the
## seam a future editor tool or a per-chapter asset pack would use.
func use_registry(registry: SceneryRegistry) -> void:
	_registry = registry


## Rebuild every scenery plane for a map. The playable plane is untouched:
## MapLoader owns it, and this must never reach into the world it is
## composing around.
func apply_map(map: MapData) -> void:
	_build()
	clear_scenery()
	if _registry == null:
		_registry = SceneryRegistry.load_default()
	for placement: Dictionary in map.scenery:
		_spawn(map, placement)


func clear_scenery() -> void:
	_moving.clear()
	for plane_name: String in PLANES:
		if plane_name == PLAYABLE:
			continue
		var container: Node = _planes.get(plane_name)
		if container == null:
			continue
		for child: Node in container.get_children():
			container.remove_child(child)
			child.queue_free()


## Every scenery prop currently placed, in plane order. Tests and tools ask
## rather than walking five containers.
func scenery() -> Array[SceneryProp]:
	var out: Array[SceneryProp] = []
	for plane_name: String in PLANES:
		var container: Node = _planes.get(plane_name)
		if container == null:
			continue
		for child: Node in container.get_children():
			if child is SceneryProp:
				out.append(child)
	return out


func _spawn(map: MapData, placement: Dictionary) -> void:
	var prop_name := String(placement.get("prop", ""))
	if _registry == null or not _registry.has_prop(prop_name):
		push_warning("Map '%s' places unknown scenery prop '%s'" % [map.id, prop_name])
		return
	var plane_name := String(placement.get("plane", _registry.default_plane(prop_name)))
	var container: Node = _planes.get(plane_name)
	if container == null:
		push_warning("Map '%s' places '%s' in unknown plane '%s'" % [map.id, prop_name, plane_name])
		return

	var prop := SceneryProp.new()
	prop.configure(_registry, prop_name, placement)
	if prop.space == "world":
		var cell := _cell_of(placement)
		# The anchor is the ground the prop stands on -- the same position an
		# actor standing there would have, which is what makes them sort
		# together in the playable plane.
		prop.rest_position = map.world_position(cell) + prop.pixel_offset
		prop.position = prop.rest_position
	container.add_child(prop)
	if prop.space != "world" or not is_equal_approx(prop.parallax, 1.0):
		_moving.append(prop)


func _process(_delta: float) -> void:
	if _moving.is_empty():
		return
	var camera := get_viewport().get_camera_2d() if is_inside_tree() else null
	var view := Vector2(Presentation.viewport())
	var centre := camera.get_screen_center_position() if camera != null else Vector2.ZERO
	for prop: SceneryProp in _moving:
		match prop.space:
			"screen":
				# Fractions of the frame: the prop is part of the picture, not
				# of the world, so it never moves at all.
				prop.position = view * prop.screen_anchor + prop.pixel_offset
			"camera":
				prop.position = centre + prop.pixel_offset
			_:
				# Parallax: displace from where the prop would be if it were
				# locked to the world, by how much of the camera's travel it
				# is meant to ignore.
				prop.position = prop.rest_position + (centre - prop.rest_position) * (1.0 - prop.parallax)


static func _cell_of(placement: Dictionary) -> Vector2i:
	var raw: Variant = placement.get("at")
	if not (raw is Array) or (raw as Array).size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(raw[0]), int(raw[1]))


## Build the five containers once. In code, not in a .tscn, for the same
## reason the lighting nodes are: a plane is architecture, and architecture in
## a scene file is architecture nobody can diff.
##
## The one exception is `Playable`, which the world scene authors because
## MapLoader and Player have to be parented somewhere at edit time. It is
## adopted and configured here rather than duplicated, so the plane's
## properties still come from this file and only this file.
func _build() -> void:
	if not _planes.is_empty():
		return
	for plane_name: String in PLANES:
		var node_name := plane_name.to_pascal_case()
		var container: Node = get_node_or_null(NodePath(node_name))
		var adopted := container != null
		if is_screen_plane(plane_name):
			var layer: CanvasLayer = container if adopted else CanvasLayer.new()
			layer.layer = Presentation.layer(plane_name)
			container = layer
		else:
			var node: Node2D = container if adopted else Node2D.new()
			node.z_index = int(PLANE_Z.get(plane_name, 0))
			# Only the world plane sorts by ground contact. A background of
			# silhouettes has no ground to contact, and sorting it would cost
			# a comparison per node for an ordering its `sort` keys already
			# state exactly.
			node.y_sort_enabled = plane_name == PLAYABLE
			container = node
		container.name = node_name
		_planes[plane_name] = container
		if not adopted:
			add_child(container)
