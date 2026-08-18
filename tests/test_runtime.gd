## The game actually runs.
##
## Everything above this file checks data. This one boots the real scene tree
## headlessly and plays: it walks the player into walls, steps through every
## door, and talks to every NPC. It is the difference between "the JSON parses"
## and "the inn can be entered".
extends TestCase

const MAIN_SCENE := "res://scenes/main.tscn"

var main: Node = null
var world: World = null


func before_all() -> void:
	GameState.reset()


func after_each() -> void:
	Dialogue.stop()
	if main != null:
		main.queue_free()
		main = null
		world = null
	GameState.reset()


## Boot the game the way a player would and hand back the live World.
func _boot(map_id: String = "", spawn_id: String = "start") -> World:
	GameState.reset()
	if not map_id.is_empty():
		GameState.current_map = map_id
		GameState.current_spawn = spawn_id
	main = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await frames(2)
	world = main.world()
	return world


func test_game_boots_into_a_playable_world() -> void:
	await _boot()
	if not ok(world != null, "the main scene never created a World"):
		return
	ok(world.loader.current != null, "no map was loaded on boot")
	ok(is_instance_valid(world.player), "the world has no player")
	equal(world.loader.current.id, World.DEFAULT_MAP, "boot did not land on the default map")


func test_player_spawns_somewhere_walkable() -> void:
	for map_id: String in MapData.all_ids():
		await _boot(map_id)
		if world == null:
			fail("could not boot into '%s'" % map_id)
			continue
		var map := world.loader.current
		var ts := TileRegistry.tile_size()
		var cell := Vector2i(int(world.player.global_position.x / ts), int(world.player.global_position.y / ts))
		ok(map.is_walkable(cell),
			"player spawned inside a solid tile on '%s' at cell %s" % [map_id, cell])
		await after_each()


func test_every_map_loads_without_errors() -> void:
	await _boot()
	if world == null:
		return
	for map_id: String in MapData.all_ids():
		var map := world.enter(map_id)
		ok(map.parse_errors.is_empty(),
			"entering '%s' failed: %s" % [map_id, ", ".join(map.parse_errors)])
		await frames(2)
		ok(world.loader.ground_layer.get_used_cells().size() > 0,
			"map '%s' painted no ground tiles" % map_id)


func test_walls_stop_the_player() -> void:
	await _boot()
	if world == null:
		return
	var map := world.loader.current
	var ts := TileRegistry.tile_size()

	# Find a walkable cell with a solid tile directly east of it, then try to
	# walk east through it.
	var from := Vector2i(-1, -1)
	for y: int in map.height:
		for x: int in map.width - 1:
			if map.is_walkable(Vector2i(x, y)) and map.is_solid(Vector2i(x + 1, y)):
				from = Vector2i(x, y)
				break
		if from.x >= 0:
			break
	if not ok(from.x >= 0, "no wall to test against on '%s'" % map.id):
		return

	world.player.global_position = map.world_position(from)
	await physics_frames(2)
	var before := world.player.global_position.x

	Input.action_press("move_right")
	await physics_frames(20)
	Input.action_release("move_right")
	await physics_frames(2)

	var travelled := world.player.global_position.x - before
	ok(travelled < float(ts),
		"player walked %.1fpx east through a solid tile at %s on '%s'" % [travelled, from + Vector2i.RIGHT, map.id])


func test_open_ground_lets_the_player_move() -> void:
	await _boot()
	if world == null:
		return
	var map := world.loader.current
	var spawn := map.primary_spawn()

	# Pick a direction that is open for two tiles so the walk is unambiguous.
	var options := {
		"move_right": Vector2i.RIGHT, "move_left": Vector2i.LEFT,
		"move_down": Vector2i.DOWN, "move_up": Vector2i.UP,
	}
	for action: String in options:
		var step: Vector2i = options[action]
		if not (map.is_walkable(spawn + step) and map.is_walkable(spawn + step * 2)):
			continue
		world.player.global_position = map.world_position(spawn)
		await physics_frames(2)
		var before := world.player.global_position
		Input.action_press(action)
		await physics_frames(20)
		Input.action_release(action)
		await physics_frames(2)
		var moved := world.player.global_position.distance_to(before)
		ok(moved > 8.0, "player barely moved (%.1fpx) walking %s across open ground" % [moved, action])
		return
	fail("spawn on '%s' has no direction with two clear tiles" % map.id)


func test_every_npc_can_be_talked_to() -> void:
	await _boot()
	if world == null:
		return
	var talked: Dictionary = {}
	for map_id: String in MapData.all_ids():
		world.enter(map_id)
		await frames(2)
		var placed: Array = world.loader.current.npcs
		var live := tree.get_nodes_in_group("npcs")
		equal(live.size(), placed.size(), "map '%s' placed %d NPCs but spawned %d" % [map_id, placed.size(), live.size()])

		for node: Node in live:
			var npc: Npc = node
			GameState.reset()
			Dialogue.stop()
			npc.interact(world.player)
			ok(Dialogue.is_active(),
				"talking to '%s' on '%s' opened no dialogue" % [npc.npc_id, map_id])
			Dialogue.stop()
			talked[npc.npc_id] = true

	for npc_id: String in Npc.all_ids():
		ok(talked.has(npc_id), "never managed to talk to '%s'" % npc_id)


## Standing next to something and facing it must actually find it.
##
## Calling npc.interact() directly proves the dialogue works; it does not prove
## the player can ever trigger it. This walks the real path -- overlapping
## areas, facing, reach -- for every interactable in the game.
func test_facing_an_interactable_finds_it() -> void:
	await _boot()
	if world == null:
		return
	const STEPS := {
		Vector2i.LEFT: "right", Vector2i.RIGHT: "left",
		Vector2i.UP: "down", Vector2i.DOWN: "up",
	}
	for map_id: String in MapData.all_ids():
		world.enter(map_id)
		await frames(2)
		var map := world.loader.current

		var targets: Array[Dictionary] = []
		for entry: Dictionary in map.npcs:
			targets.append({"at": entry["at"], "what": "npc '%s'" % entry.get("npc", "?")})
		for entry: Dictionary in map.signs:
			targets.append({"at": entry["at"], "what": "sign"})
		for entry: Dictionary in map.portals:
			if bool(entry.get("interact", false)):
				targets.append({"at": entry["at"], "what": "portal to '%s'" % entry.get("to", "?")})

		for target: Dictionary in targets:
			var cell: Vector2i = target["at"]
			var found := false
			var stood_anywhere := false
			# Try every side; one clear approach is enough.
			for step: Vector2i in STEPS:
				var from := cell + step
				if not map.is_walkable(from):
					continue
				stood_anywhere = true
				world.player.global_position = map.world_position(from)
				world.player.face(STEPS[step])
				await physics_frames(3)
				if world.player.find_interactable() != null:
					found = true
					break
			if stood_anywhere:
				ok(found, "%s on '%s' at %s cannot be interacted with from any adjacent tile"
					% [target["what"], map_id, cell])
			else:
				fail("%s on '%s' at %s has no walkable tile beside it" % [target["what"], map_id, cell])


func test_doors_move_the_player_to_the_other_side() -> void:
	await _boot()
	if world == null:
		return
	for map_id: String in MapData.all_ids():
		for portal: Dictionary in MapData.load_map(map_id).portals:
			var target := String(portal.get("to", ""))
			var spawn_id := String(portal.get("spawn", "start"))
			if not MapData.exists(target):
				continue
			world.enter(map_id)
			await frames(2)
			world.enter(target, spawn_id)
			await frames(2)
			if not ok(world.loader.current != null and world.loader.current.id == target,
					"door from '%s' did not land on '%s'" % [map_id, target]):
				continue
			var ts := TileRegistry.tile_size()
			var cell := Vector2i(
				int(world.player.global_position.x / ts),
				int(world.player.global_position.y / ts))
			ok(world.loader.current.is_walkable(cell),
				"door from '%s' drops the player into a wall at %s on '%s'" % [map_id, cell, target])


func test_saving_and_loading_round_trips() -> void:
	await _boot()
	GameState.set_flag("ledger_started", true)
	GameState.current_map = "port_azure_inn_ground"
	GameState.save_game()

	GameState.reset()
	ok(not GameState.has_flag("ledger_started"), "reset did not clear flags")

	ok(GameState.load_game(), "the save file did not load back")
	ok(GameState.has_flag("ledger_started"), "flag did not survive the save round trip")
	equal(GameState.current_map, "port_azure_inn_ground", "current map did not survive the save")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.SAVE_PATH))
