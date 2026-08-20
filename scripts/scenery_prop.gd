## One piece of scenery on screen.
##
## A Sprite2D and nothing more: no body, no area, no shape. Scenery is
## presentation, and a prop that could be collided with would quietly become
## gameplay -- see `scripts/scenery_registry.gd` for why that separation is
## the point. What blocks the player is a solid tile in the map; this is the
## picture standing on it.
##
## The node's own position is the prop's **anchor** -- the pixel that touches
## the ground -- so a 400px redwood and a 48px villager standing on the same
## cell sort identically in the y-sorted plane. The image is offset around
## that point and may be any size at all.
class_name SceneryProp
extends Sprite2D

## Set for props that move at a different rate from the world. Read by
## ScenePlanes each frame; 1.0 (the default) means it is never touched.
var parallax := 1.0
## Where the prop sits when it is not fixed to the world: the anchor a
## camera-space prop keeps relative to the view, or the viewport fraction a
## screen-space prop pins itself to.
var space := "world"
var screen_anchor := Vector2(0.5, 0.5)
var pixel_offset := Vector2.ZERO
## The world position the prop would have with no parallax -- what a
## parallaxed prop is displaced from.
var rest_position := Vector2.ZERO

var _frames := 1
var _fps := 0.0
var _loop := true
var _frame_size := Vector2.ZERO
var _time := 0.0
var _frame := 0


## Build a prop from a registry entry plus one map placement. `texture` may be
## passed in to override the registry's -- tests and tools do that; ordinary
## loading leaves it null and the registry's path is loaded.
func configure(registry: SceneryRegistry, prop_name: String, placement: Dictionary,
		texture_override: Texture2D = null) -> void:
	name = "Scenery_%s" % prop_name
	centered = true
	space = String(placement.get("space", "world"))
	parallax = float(placement.get("parallax", 1.0))
	pixel_offset = _point(placement.get("offset"), Vector2.ZERO)
	screen_anchor = _point(placement.get("screen"), Vector2(0.5, 0.5))
	flip_h = bool(placement.get("flip_h", false))
	visible = bool(placement.get("visible", true))
	var tint := String(placement.get("modulate", ""))
	if Color.html_is_valid(tint):
		modulate = Color.html(tint)
	# Ordering inside a plane that is not y-sorted. The playable plane ignores
	# this and sorts by ground contact like everything else in it.
	z_index = int(placement.get("sort", 0))

	texture = texture_override
	if texture == null:
		var path := registry.texture_path_of(prop_name)
		if not path.is_empty() and ResourceLoader.exists(path):
			texture = load(path)

	var anim := registry.animation(prop_name)
	_frames = int(anim.get("frames", 1))
	_fps = float(anim.get("fps", 0.0))
	_loop = bool(anim.get("loop", true))
	_frame_size = registry.frame_size(prop_name)
	_apply_anchor(registry.anchor(prop_name))

	var occluder := registry.occluder_polygon(prop_name)
	if not occluder.is_empty():
		_add_occluder(occluder)


## Put the node's origin on the prop's ground-contact pixel. Everything about
## placement and sorting depends on this and on nothing else about the image.
func _apply_anchor(anchor: Vector2) -> void:
	var size := _frame_size
	if size == Vector2.ZERO:
		size = texture.get_size() if texture != null else Vector2.ZERO
	if size == Vector2.ZERO:
		return
	if _frame_size != Vector2.ZERO:
		region_enabled = true
		_redraw()
	offset = size * 0.5 - anchor


## Light occlusion is its own footprint, like a tile's: at most the logical
## one, often smaller, and never the size of the picture. A trunk blocks
## light; the canopy hanging over three neighbouring cells does not.
func _add_occluder(polygon: PackedVector2Array) -> void:
	var shape := OccluderPolygon2D.new()
	shape.polygon = polygon
	var node := LightOccluder2D.new()
	node.name = "Occluder"
	node.occluder = shape
	add_child(node)


func _process(delta: float) -> void:
	if _frames <= 1 or _fps <= 0.0:
		return
	_time += delta
	var step := int(_time * _fps)
	if _loop:
		step %= _frames
	else:
		step = mini(step, _frames - 1)
	if step != _frame:
		_frame = step
		_redraw()


func _redraw() -> void:
	if _frame_size == Vector2.ZERO:
		return
	region_rect = Rect2(_frame * _frame_size.x, 0.0, _frame_size.x, _frame_size.y)


static func _point(raw: Variant, fallback: Vector2) -> Vector2:
	if not (raw is Array) or (raw as Array).size() != 2:
		return fallback
	return Vector2(float(raw[0]), float(raw[1]))
