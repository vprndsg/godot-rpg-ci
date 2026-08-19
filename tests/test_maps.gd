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


## The validator's rules actually fire.
##
## Every other test here asserts the shipped maps come back *clean*, which
## says nothing about whether the checks still run: invert a condition or
## drop the flood fill and all three maps stay green while the guarantee is
## gone. So this feeds it maps that are broken on purpose -- one fault each,
## built in memory because none of these should ever be a file.
func test_the_validator_catches_broken_maps() -> void:
	# tile -> what its errors must mention, for a map that is sound apart
	# from the one fault named in the key.
	var cases := {
		"a short row": [{
			"legend": {".": "grass"},
			"ground": ["....", "..."],
			"spawns": {"start": [0, 0]},
		}, "row 1 is 3 chars"],
		"a character with no legend entry": [{
			"legend": {".": "grass"},
			"ground": ["..#.", "...."],
			"spawns": {"start": [0, 0]},
		}, "missing from the legend"],
		"a legend entry naming no real tile": [{
			"legend": {".": "grass", "%": "unobtanium"},
			"ground": ["..%.", "...."],
			"spawns": {"start": [0, 0]},
		}, "unknown tile 'unobtanium'"],
		"a spawn inside a wall": [{
			"legend": {".": "grass", "#": "wall_stone"},
			"ground": ["#...", "...."],
			"spawns": {"start": [0, 0]},
		}, "is inside a solid tile"],
		"an npc with no definition file": [{
			"legend": {".": "grass"},
			"ground": ["....", "...."],
			"spawns": {"start": [0, 0]},
			"npcs": [{"npc": "nobody", "at": [2, 0]}],
		}, "has no definition at data/npcs/nobody.json"],
	}
	for label: String in cases:
		var errors := "\n".join(MapData.from_dict(cases[label][0]).validate())
		ok(errors.contains(String(cases[label][1])),
			"the validator accepted %s -- it should report '%s', got: %s"
				% [label, cases[label][1], errors])


## Reachability is the check that cannot be seen in a text diff, and the one
## a refactor of the flood fill would silently break: nothing on the far side
## of a wall is solid, so only walking there proves the far side is walled
## off. Both directions are asserted -- sealed is an error, opened is not --
## because a fill that returned everything would pass a one-sided test.
func test_the_validator_walks_to_npcs_and_signs() -> void:
	var sealed := {
		"legend": {".": "grass", "#": "wall_stone"},
		"ground": [
			".....",
			".###.",
			".#.#.",
			".###.",
			".....",
		],
		"spawns": {"start": [0, 0]},
		"npcs": [{"npc": "bartender", "at": [2, 2]}],
	}
	var errors := "\n".join(MapData.from_dict(sealed).validate())
	ok(errors.contains("unreachable from spawn"),
		"an npc bricked into a closet must be reported, got: %s" % errors)

	# Knock one brick out and the very same map is sound.
	var opened: Dictionary = sealed.duplicate(true)
	opened["ground"] = [".....", ".###.", ".#...", ".###.", "....."]
	expect_no_errors(MapData.from_dict(opened).validate(),
		"the same npc with a way in should validate")

	# A sign is mounted on a solid tile, so it is read from the cell beside
	# it -- walling off every neighbour makes it unreadable, not unreachable.
	var boxed_in: Dictionary = sealed.duplicate(true)
	boxed_in["npcs"] = []
	boxed_in["legend"] = {".": "grass", "#": "wall_stone", "!": "sign"}
	boxed_in["ground"] = [".....", ".###.", ".#!#.", ".###.", "....."]
	boxed_in["signs"] = [{"at": [2, 2], "text": "Nobody can read this."}]
	errors = "\n".join(MapData.from_dict(boxed_in).validate())
	ok(errors.contains("cannot be read"),
		"a sign with no reachable neighbour must be reported, got: %s" % errors)
