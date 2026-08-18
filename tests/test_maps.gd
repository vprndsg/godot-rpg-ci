## Every map in maps/ is playable.
##
## MapData.validate() does the heavy lifting (grid shape, legend, spawns,
## reachability). This suite runs it over every file and adds the checks that
## only make sense across maps: that doors lead both ways and that the world
## is one connected place rather than several islands.
extends TestCase


func test_every_map_validates() -> void:
	var ids := MapData.all_ids()
	ok(ids.size() > 0, "there are no maps in maps/")
	for map_id: String in ids:
		var map := MapData.load_map(map_id)
		expect_no_errors(map.validate(), "maps/%s.json" % map_id)


func test_maps_have_sane_dimensions() -> void:
	for map_id: String in MapData.all_ids():
		var map := MapData.load_map(map_id)
		ok(map.width >= 8 and map.height >= 6,
			"map '%s' is %dx%d, too small to play in" % [map_id, map.width, map.height])
		ok(map.width <= 256 and map.height <= 256,
			"map '%s' is %dx%d; split it up before it becomes unreviewable" % [map_id, map.width, map.height])


func test_doors_lead_both_ways() -> void:
	for map_id: String in MapData.all_ids():
		var map := MapData.load_map(map_id)
		for portal: Dictionary in map.portals:
			var target := String(portal.get("to", ""))
			if not MapData.exists(target):
				continue  # already reported by validate()
			var back := false
			for other: Dictionary in MapData.load_map(target).portals:
				if String(other.get("to", "")) == map_id:
					back = true
					break
			ok(back, "maps/%s.json sends the player to '%s', which has no way back" % [map_id, target])


func test_all_maps_are_connected() -> void:
	var ids := MapData.all_ids()
	if ids.is_empty():
		return
	var start := "port_azure_town" if ids.has("port_azure_town") else ids[0]

	var seen: Dictionary = {start: true}
	var queue: Array[String] = [start]
	while not queue.is_empty():
		var map_id: String = queue.pop_front()
		for portal: Dictionary in MapData.load_map(map_id).portals:
			var target := String(portal.get("to", ""))
			if MapData.exists(target) and not seen.has(target):
				seen[target] = true
				queue.append(target)

	for map_id: String in ids:
		ok(seen.has(map_id),
			"map '%s' cannot be reached from '%s' through any door" % [map_id, start])


func test_every_map_has_walkable_room_to_move() -> void:
	for map_id: String in MapData.all_ids():
		var map := MapData.load_map(map_id)
		var spawn := map.primary_spawn()
		if not map.in_bounds(spawn):
			continue  # already reported by validate()
		var reachable := map.reachable_from(spawn).size()
		var area := map.width * map.height
		ok(reachable >= 8,
			"map '%s' only has %d walkable cells around its spawn" % [map_id, reachable])
		# A map where almost nothing is reachable usually means a wall was
		# drawn one row too long and sealed the player in.
		ok(float(reachable) / float(area) > 0.1,
			"map '%s': only %d of %d cells are reachable from spawn %s -- is the player walled in?"
				% [map_id, reachable, area, spawn])
