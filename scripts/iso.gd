## The isometric projection, in one place.
##
## Maps stay square. A cell is still (x, y) in an ASCII grid, walkability is
## still 4-connected, and the validator never learned what a diamond is --
## isometric is a *projection*, applied when a cell becomes a screen position,
## and nowhere else. Everything that crosses that line comes through here so
## the engine, the game code and the Python map renderer cannot drift apart.
##
## The formula is not invented: it reproduces Godot's own
## TILE_SHAPE_ISOMETRIC + TILE_LAYOUT_DIAMOND_DOWN + TILE_OFFSET_AXIS_HORIZONTAL
## layout exactly, and tests/test_iso.gd pins `cell_centre()` against a real
## TileMapLayer.map_to_local() so it stays that way.
##
##       (0,0)                 grid +x runs down-right on screen,
##       . ' ` .               grid +y runs down-left. Screen-down is
##   (0,1)     (1,0)           therefore "further from the camera",
##       ` . ' `. .            which is why y-sorting orders the world.
##           (1,1)
class_name Iso
extends RefCounted


## Width and height of the ground diamond, in pixels.
static func tile() -> Vector2:
	return Vector2(TileRegistry.tile_size())


## A grid-space vector (in tiles) as a screen-space vector (in pixels).
##
## This is the linear half of the projection, so it is the one to use for
## directions, velocities and offsets. Note that the four grid neighbours all
## come out the same distance away on screen, which is why one `REACH` works
## in every direction.
static func grid_vector(v: Vector2) -> Vector2:
	var t := tile()
	return Vector2((v.x - v.y) * t.x * 0.5, (v.x + v.y) * t.y * 0.5)


## Screen position of a cell's centre.
##
## Fractional cells are meaningful: an actor halfway between two tiles is at
## a fractional cell, and this projects it where you would expect.
static func cell_centre(cell: Vector2) -> Vector2:
	return grid_vector(cell) + tile() * 0.5


## Inverse of `cell_centre()`, keeping the fraction. Use `cell_at()` when you
## want the cell an actor is standing in.
static func screen_to_grid(pos: Vector2) -> Vector2:
	var t := tile()
	var p := pos - t * 0.5
	# p.x / t.x is (x - y)/2 and p.y / t.y is (x + y)/2; add and subtract.
	var u := p.x / t.x
	var v := p.y / t.y
	return Vector2(v + u, v - u)


## Which cell a screen position falls inside.
##
## Rounding rather than flooring is what makes this a diamond test: the unit
## square around a lattice point in grid space *is* the diamond on screen.
static func cell_at(pos: Vector2) -> Vector2i:
	var g := screen_to_grid(pos)
	return Vector2i(floori(g.x + 0.5), floori(g.y + 0.5))


## The ground diamond as a polygon centred on the origin, wound clockwise on
## screen. `shrink` insets it -- a portal uses that so brushing the corner of
## a doorway is not the same as walking through it.
static func diamond(shrink: float = 1.0) -> PackedVector2Array:
	var h := tile() * 0.5 * shrink
	return PackedVector2Array([
		Vector2(0.0, -h.y), Vector2(h.x, 0.0), Vector2(0.0, h.y), Vector2(-h.x, 0.0),
	])


## Screen rectangle covering a whole grid, corner diamonds included.
##
## A diamond grid leans left as it goes down, so this starts at a negative x
## for anything taller than one row. Cameras clamp to it.
static func grid_bounds(size: Vector2i) -> Rect2:
	var t := tile()
	var span := float(size.x + size.y)
	return Rect2(
		Vector2(-(size.y - 1) * t.x * 0.5, 0.0),
		Vector2(span * t.x * 0.5, span * t.y * 0.5)
	)
