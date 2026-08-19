## The game's one camera. Rides the player, clamps to the current map, and
## offers the small cinematic surface future work coordinates with.
##
## Ordinary play never calls anything here except fit_to_map(), which
## World.enter() runs on every map change -- following the player is free
## because the node is a child of the player scene. The focus API exists so
## a cutscene or a lighting beat can borrow the camera without inventing a
## second one: it slides the view somewhere, holds it, and hands it back,
## all through `offset` so the player-following transform underneath is
## never disturbed.
class_name GameCamera
extends Camera2D


## Keep the camera inside the map so small interiors do not show the void.
func fit_to_map(map: MapData) -> void:
	# A diamond grid is not the rectangle its cell counts suggest: it leans
	# left as it descends, so the far corner of a tall map sits at negative x.
	var bounds := Iso.grid_bounds(Vector2i(map.width, map.height))
	limit_left = int(bounds.position.x)
	# Tall tiles draw above the cell they stand on, so give the back row its
	# headroom rather than slicing the tops off the far wall -- and raised
	# terrain lifts everything on it by another level's worth each.
	limit_top = int(bounds.position.y) - TileRegistry.footprint_top() \
		- int(map.max_elevation() * Iso.ELEVATION_HEIGHT)
	limit_right = int(bounds.end.x)
	limit_bottom = int(bounds.end.y)

	var view := get_viewport_rect().size
	# A map narrower than the screen would jitter against its own limits;
	# centre it instead of clamping.
	position_smoothing_enabled = bounds.size.x > view.x and bounds.size.y > view.y


## Glide the view to a world position without leaving the player's transform.
## Returns the tween so a cutscene can await it. Pair with release_focus().
func focus_on(world_position: Vector2, duration := 0.6) -> Tween:
	var tween := create_tween()
	tween.tween_property(self, "offset", world_position - global_position, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return tween


## Return the view to the player. The camera is theirs by default; anything
## that borrows it must give it back.
func release_focus(duration := 0.6) -> Tween:
	var tween := create_tween()
	tween.tween_property(self, "offset", Vector2.ZERO, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return tween
