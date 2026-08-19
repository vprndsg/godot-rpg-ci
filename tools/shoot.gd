## Screenshots of the real game, for looking at lighting.
##
##     xvfb-run -a godot --path . --rendering-driver opengl3 \
##         --resolution 960x576 --script res://tools/shoot.gd
##
## or just `tools/ci.sh shots`.
##
## The Python renderers in tools/ (art_sheet.py, render_map.py) read terrain.png
## and the map JSON directly, which is what makes them fast and engine-free --
## and also means they cannot show you a single thing about lighting. An
## ambient CanvasModulate, a PointLight2D falloff and a baked occluder only
## exist once Godot is drawing. So this boots the actual game, walks to a
## place worth looking at, and saves what the player would see.
##
## Output goes to docs/shots/, deliberately *outside* the drift-checked
## docs/art/: these frames come out of whatever GL driver the machine has
## (llvmpipe in CI sandboxes, a real GPU elsewhere) and are not byte
## reproducible. They are reference images to look at, not build outputs.
extends SceneTree

const OUT_DIR := "res://docs/shots"

## Where to stand and what it is meant to show. Add a row whenever you add a
## lighting behaviour that a still frame can prove.
const SHOTS: Array[Dictionary] = [
	{"name": "town", "map": "port_azure_town", "at": Vector2i(14, 13),
	 "shows": "outdoor profile; lamp emitters down the high street"},
	{"name": "town_lamp", "map": "port_azure_town", "at": Vector2i(14, 17),
	 "shows": "a single lamp's pool of light against the trees"},
	{"name": "town_hill", "map": "port_azure_town", "at": Vector2i(6, 14),
	 "shows": "raised terrain at dusk: the player on the level-2 plateau, cliff faces below"},
	{"name": "inn_fireplace", "map": "port_azure_inn_ground", "at": Vector2i(14, 4),
	 "shows": "warm interior ambient + the hearth's shadow-casting point light"},
	{"name": "inn_taproom", "map": "port_azure_inn_ground", "at": Vector2i(8, 8),
	 "shows": "the taproom read as a whole, hearth at the far end"},
	{"name": "inn_upper", "map": "port_azure_inn_upper", "at": Vector2i(8, 8),
	 "shows": "no lighting block: full bright, exactly as before the system"},
]


func _initialize() -> void:
	_run()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("shoot.gd needs a display -- run it under xvfb-run, not --headless.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Deliberately untyped, and loaded rather than preloaded: the script given
	# to --script is compiled before the autoloads exist, so a static reference
	# to World (whose _ready talks to Router) would fail to compile before the
	# game ever starts. tests/run_tests.gd dodges the same trap the same way.
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var world: Node = main.start_game()
	# Lighting glides between environments; a still wants the destination.
	world.lighting.transition_seconds = 0.0
	await process_frame

	for shot: Dictionary in SHOTS:
		world.enter(String(shot["map"]))
		await process_frame
		# place_on, not a raw position: a body lives on the flat plane at any
		# elevation, and a teleport must land at the new height rather than
		# easing up to it over the frames this shot does not wait for.
		world.player.place_on(shot["at"])
		# The camera eases after the player by design; snap it for the frame.
		world.camera.position_smoothing_enabled = false
		await process_frame
		world.camera.reset_smoothing()
		world.camera.force_update_scroll()
		# Let the tile layers, lights and occluders settle before grabbing.
		for i: int in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = root.get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot["name"]]
		image.save_png(path)
		print("%-14s %-22s %d lights, ambient %s -- %s" % [
			shot["name"], shot["map"], world.lighting.dynamic_light_count(),
			world.lighting.ambient_node.color.to_html(false), shot["shows"]])

	quit(0)
