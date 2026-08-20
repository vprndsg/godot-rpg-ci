## The actor animation contract: what a character sheet is allowed to be.
##
## Nothing about a character is written down in code. A manifest says which
## sheet the pixels are on, how big a frame is, where the feet are inside it,
## which directions were authored, and what clips exist -- each with its own
## frame count and its own frame rate. `scripts/actor_sprite.gd` reads the
## answers and draws them; it knows no character's name, no frame size and no
## walk speed.
##
## That indirection is the whole point. A Blender -> PixelOver character with
## eight directions, a 96x128 frame, a six-frame trot at 12fps and a one-off
## `sniff` drops in as JSON. The four legacy townspeople -- 32x48, four
## directions, `idle` and `walk` -- are the same schema with less filled in.
##
## ## Schema
##
## ```json
## {
##   "version": 2,
##   "directions": ["down", "down_left", ...],      // default authoring order
##   "clip_fallbacks": {"run": "walk"},              // used when a clip is absent
##   "sheets": {
##     "coyote": {
##       "texture": "res://assets/packs/coyote/sheet.png",
##       "frame_size": [96, 96], "anchor": [48, 88],
##       "normal": "res://.../sheet_normal.png"      // optional, layout-identical
##     }
##   },
##   "actors": {
##     "coyote": {
##       "sheet": "coyote",
##       "directions": ["down", "down_left", "left", "up_left",
##                      "up", "up_right", "right", "down_right"],
##       "clips": {
##         "idle": {"row": 0,  "frames": 2, "fps": 3,  "loop": true},
##         "walk": {"row": 8,  "frames": 8, "fps": 10, "loop": true},
##         "sniff": {"row": 16, "frames": 6, "fps": 8, "loop": false,
##                   "directions": ["down", "right"]}   // sparse on purpose
##       },
##       "fallbacks": {"trot": "walk"}                  // per-actor override
##     }
##   }
## }
## ```
##
## A clip's `row` is the sheet row of its **first** direction; direction *d*
## of that clip is `row + d` in the clip's own direction order. Frames run
## horizontally from column 0.
##
## ## Directions
##
## Eight names, and they are **grid** directions like everything else in this
## project -- so on screen the four axes are the diagonals and the four
## diagonals are the screen axes:
##
## ```
##            up (grid -y)              up_right      up      down_right
##      up_left  .  up_right                 \        |        /
##          .    |    .                       \       |       /
##  left  --  actor  --  right    screen:   left ---- + ---- right
##          .    |    .                       /       |       \
##    down_left  .  down_right               /        |        \
##          down (grid +y)             up_left      down      down_left
## ```
##
## ## Fallback
##
## A character need not author everything. Asking for a clip it lacks walks
## the fallback chain (`run` -> `walk` -> `idle`); asking for a direction a
## clip lacks picks the nearest authored one by angle. A manifest that is
## *malformed* -- a row off the end of the sheet, a zero-frame clip, a
## fallback pointing at nothing -- is a different thing entirely and fails
## validation loudly. Missing is fine; broken is not.
class_name ActorManifest
extends RefCounted

const PATH := "res://assets/sprites/actors.json"

## The eight grid directions, in angle order starting at grid +y. Index
## arithmetic below assumes this order and this order only.
const DIRECTIONS: PackedStringArray = [
	"down", "down_left", "left", "up_left", "up", "up_right", "right", "down_right",
]

## Which direction wins when two are equally close to the way an actor is
## moving. The grid axes come first, which reproduces the four-direction rule
## this project shipped with: a step of exactly (1, 1) faces `down`, not
## `right`.
const TIE_ORDER: PackedStringArray = [
	"down", "up", "left", "right", "down_left", "up_left", "up_right", "down_right",
]

## The clip vocabulary the engine and the design docs share. A manifest may
## define others -- a contextual one-shot, say -- and nothing here has to know
## about it; this is what a caller can ask for and expect *something* back,
## because the fallback chain covers all of it.
const KNOWN_CLIPS: PackedStringArray = [
	"idle", "walk", "run", "trot", "sniff", "turn", "sit",
]

const CLIP_KEYS: PackedStringArray = ["row", "frames", "fps", "loop", "directions"]
const SHEET_KEYS: PackedStringArray = ["texture", "frame_size", "anchor", "normal", "emission"]
const ACTOR_KEYS: PackedStringArray = ["sheet", "frame_size", "anchor", "directions", "clips", "fallbacks"]

## The clip everything falls back to in the end. An actor with no `idle`
## falls back to whatever clip it does have, so a sheet is never undrawable.
const LAST_RESORT := "idle"

var data: Dictionary = {}

static var _default: ActorManifest = null


## The shipped manifest, parsed once.
static func load_default() -> ActorManifest:
	if _default == null:
		_default = ActorManifest.new()
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f == null:
			push_error("Missing %s -- run tools/gen_art.py" % PATH)
		else:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				_default.data = parsed
			else:
				push_error("%s is not a JSON object" % PATH)
	return _default


## Drop the parsed data so the next call re-reads the file. Named away from
## `reload()` on purpose: `Script` already has one, and it wins -- see
## TileRegistry.clear_cache().
static func clear_cache() -> void:
	_default = null


## Build one from a dictionary -- what load_default() does after the parse.
## Tests use this to try manifests that should never be files.
static func from_dict(raw: Dictionary) -> ActorManifest:
	var m := ActorManifest.new()
	m.data = raw
	return m


# --------------------------------------------------------------------------
# directions
# --------------------------------------------------------------------------

## Index of a direction name in the canonical order, or -1.
static func direction_index(direction: String) -> int:
	return DIRECTIONS.find(direction)


## A direction as a unit vector in **grid** space. Unit, so that "one step
## ahead" is the same distance diagonally as along an axis -- which is what
## lets the player's interactor reach equally far in all eight.
static func direction_vector(direction: String) -> Vector2:
	var index := direction_index(direction)
	if index < 0:
		return Vector2.DOWN
	var radians := deg_to_rad(90.0 + index * 45.0)
	return Vector2(cos(radians), sin(radians)).normalized()


## Which of `available` a grid-space step faces.
##
## Takes a step in tiles, not pixels: on screen the axes are diagonals, and
## comparing screen x against screen y would pick the wrong one every time.
## The choice is by angle against the real step rather than by quantising
## first, so a step of (2, 1) faces `right` even for a character that
## authored all eight directions' worth of nearly-right.
static func facing_for(step: Vector2, available: PackedStringArray = DIRECTIONS) -> String:
	if available.is_empty():
		return DIRECTIONS[0]
	if step == Vector2.ZERO:
		return available[0]
	var best := ""
	var best_error := INF
	for direction: String in available:
		var error := absf(step.angle_to(direction_vector(direction)))
		# Ties are resolved by TIE_ORDER, not by whichever came first in the
		# manifest -- authoring order must never change how a character turns.
		if error < best_error - 0.0001 or (absf(error - best_error) <= 0.0001
				and _tie_rank(direction) < _tie_rank(best)):
			best = direction
			best_error = error
	return best


## The authored direction closest to one the actor does not have. Same rule as
## facing_for(), fed the missing direction's own vector.
static func nearest_direction(direction: String, available: PackedStringArray) -> String:
	if available.has(direction):
		return direction
	return facing_for(direction_vector(direction), available)


static func _tie_rank(direction: String) -> int:
	var index := TIE_ORDER.find(direction)
	return index if index >= 0 else TIE_ORDER.size()


# --------------------------------------------------------------------------
# lookups
# --------------------------------------------------------------------------

func actors() -> Dictionary:
	return data.get("actors", {})


func has_actor(actor: String) -> bool:
	return actors().has(actor)


func actor_names() -> Array:
	var out: Array = actors().keys()
	out.sort()
	return out


func sheets() -> Dictionary:
	return data.get("sheets", {})


## The sheet block an actor draws from, or {} when either is missing.
func sheet_of(actor: String) -> Dictionary:
	var entry: Dictionary = actors().get(actor, {})
	return sheets().get(String(entry.get("sheet", "")), {})


## Frame size in pixels. Per-actor when stated, else the sheet's -- two
## characters may share one texture and still be different sizes if their
## rows are laid out for it.
func frame_size(actor: String) -> Vector2i:
	return _vec(actor, "frame_size", Vector2i(16, 24))


## The pixel inside a frame that touches the ground. World sorting is by
## ground contact, so this -- not the middle of the image -- is what the
## sprite's origin is placed at.
func anchor(actor: String) -> Vector2i:
	var size := frame_size(actor)
	return _vec(actor, "anchor", Vector2i(size.x / 2, size.y - 2))


func texture_path(actor: String) -> String:
	return String(sheet_of(actor).get("texture", ""))


## Optional layout-identical material maps, by the same naming contract packs
## use. Empty when the sheet ships none.
func material_map(actor: String, kind: String) -> String:
	return String(sheet_of(actor).get(kind, ""))


## The directions this actor authored, in the order its rows are stacked.
func directions(actor: String) -> PackedStringArray:
	var entry: Dictionary = actors().get(actor, {})
	var raw: Variant = entry.get("directions", data.get("directions", DIRECTIONS))
	var out: PackedStringArray = []
	for name: Variant in raw:
		out.append(String(name))
	return out


func clip_names(actor: String) -> Array:
	var out: Array = actors().get(actor, {}).get("clips", {}).keys()
	out.sort()
	return out


func has_clip(actor: String, clip: String) -> bool:
	return actors().get(actor, {}).get("clips", {}).has(clip)


## Which clip an actor actually plays when asked for `clip`.
##
## Walks the fallback chain -- the actor's own `fallbacks` first, then the
## manifest-wide `clip_fallbacks` -- and stops at the first clip that exists.
## Returns "" only for an actor with no clips at all, which validation
## rejects. Cycles are impossible to loop on: the chain gives up after one
## pass over the clip vocabulary.
func resolve_clip_name(actor: String, clip: String) -> String:
	var entry: Dictionary = actors().get(actor, {})
	var clips: Dictionary = entry.get("clips", {})
	if clips.is_empty():
		return ""
	var actor_fallbacks: Dictionary = entry.get("fallbacks", {})
	var shared: Dictionary = data.get("clip_fallbacks", {})
	var seen: Dictionary = {}
	var wanted := clip
	while not wanted.is_empty() and not seen.has(wanted):
		if clips.has(wanted):
			return wanted
		seen[wanted] = true
		wanted = String(actor_fallbacks.get(wanted, shared.get(wanted, "")))
	if clips.has(LAST_RESORT):
		return LAST_RESORT
	var names := clip_names(actor)
	return String(names[0])


## Everything the sprite needs to draw one clip of one actor, already resolved:
##
##     {clip, row, frames, fps, loop, directions, frame_size, anchor, texture}
##
## `clip` is what actually got played, which may not be what was asked for.
## Empty when the actor is unknown.
func resolve_clip(actor: String, clip: String) -> Dictionary:
	if not has_actor(actor):
		return {}
	var name := resolve_clip_name(actor, clip)
	if name.is_empty():
		return {}
	var raw: Dictionary = actors()[actor]["clips"][name]
	var authored := directions(actor)
	if raw.has("directions"):
		authored = PackedStringArray()
		for d: Variant in raw["directions"]:
			authored.append(String(d))
	return {
		"clip": name,
		"row": int(raw.get("row", 0)),
		"frames": maxi(1, int(raw.get("frames", 1))),
		"fps": maxf(0.0, float(raw.get("fps", 0.0))),
		"loop": bool(raw.get("loop", true)),
		"directions": authored,
		"frame_size": frame_size(actor),
		"anchor": anchor(actor),
		"texture": texture_path(actor),
	}


## The region of the sheet one frame of a resolved clip occupies. `direction`
## is snapped to the nearest one the clip authored, so a character missing its
## diagonals still faces roughly the right way instead of drawing nothing.
static func frame_region(resolved: Dictionary, direction: String, frame: int) -> Rect2:
	var size: Vector2i = resolved.get("frame_size", Vector2i(16, 24))
	var authored: PackedStringArray = resolved.get("directions", DIRECTIONS)
	var row := int(resolved.get("row", 0))
	var index := maxi(0, authored.find(nearest_direction(direction, authored)))
	var column := clampi(frame, 0, int(resolved.get("frames", 1)) - 1)
	return Rect2(column * size.x, (row + index) * size.y, size.x, size.y)


func _vec(actor: String, key: String, fallback: Vector2i) -> Vector2i:
	var entry: Dictionary = actors().get(actor, {})
	var raw: Variant = entry.get(key, sheet_of(actor).get(key, []))
	if not (raw is Array) or (raw as Array).size() != 2:
		return fallback
	return Vector2i(int(raw[0]), int(raw[1]))


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------

## Everything wrong with this manifest, in plain language. Empty means it is
## sound. tests/test_animation.gd runs it over the shipped file and over
## deliberately broken ones -- a manifest that silently half-works is the
## worst outcome for headless authoring, so absent is tolerated and malformed
## never is.
##
## `check_textures` is off for in-memory fixtures, which name no real files.
func validate(check_textures: bool = true) -> PackedStringArray:
	var errors: PackedStringArray = []
	if int(data.get("version", 0)) < 2:
		errors.append("manifest has no \"version\": 2 -- the pre-migration actor "
			+ "format is gone; re-run tools/gen_art.py")

	for name: String in data.get("directions", []):
		if not DIRECTIONS.has(String(name)):
			errors.append("default directions list has '%s'; expected one of %s" % [name, DIRECTIONS])

	for clip_name: String in data.get("clip_fallbacks", {}):
		var target := String(data["clip_fallbacks"][clip_name])
		if target == clip_name:
			errors.append("clip_fallbacks: '%s' falls back to itself" % clip_name)

	var sizes: Dictionary = {}
	for sheet_name: String in sheets():
		var sheet: Dictionary = sheets()[sheet_name]
		var subject := "sheet '%s'" % sheet_name
		for key: String in sheet:
			if not key.begins_with("_") and not SHEET_KEYS.has(key):
				errors.append("%s: unknown key '%s' (expected one of %s)" % [subject, key, SHEET_KEYS])
		errors.append_array(_validate_size(subject, sheet, "frame_size"))
		var texture := String(sheet.get("texture", ""))
		if texture.is_empty():
			errors.append("%s has no 'texture'" % subject)
		elif check_textures:
			if not ResourceLoader.exists(texture):
				errors.append("%s names texture '%s', which does not exist" % [subject, texture])
			else:
				var image: Texture2D = load(texture)
				if image != null:
					sizes[sheet_name] = image.get_size()
			for kind: String in ["normal", "emission"]:
				var extra := String(sheet.get(kind, ""))
				if not extra.is_empty() and not ResourceLoader.exists(extra):
					errors.append("%s names a %s map '%s', which does not exist" % [subject, kind, extra])

	if actors().is_empty():
		errors.append("manifest defines no actors")

	for actor: String in actors():
		var entry: Dictionary = actors()[actor]
		var subject := "actor '%s'" % actor
		for key: String in entry:
			if not key.begins_with("_") and not ACTOR_KEYS.has(key):
				errors.append("%s: unknown key '%s' (expected one of %s)" % [subject, key, ACTOR_KEYS])
		var sheet_name := String(entry.get("sheet", ""))
		if not sheets().has(sheet_name):
			errors.append("%s names sheet '%s', which the manifest does not define" % [subject, sheet_name])

		var size := frame_size(actor)
		if size.x <= 0 or size.y <= 0:
			errors.append("%s has frame size %s; frames must have positive dimensions" % [subject, size])
		var foot := anchor(actor)
		if foot.x < 0 or foot.y < 0 or foot.x >= size.x or foot.y >= size.y:
			errors.append("%s: anchor %s is outside its own %s frame -- the anchor is the pixel "
				% [subject, foot, size] + "that touches the ground, so it has to be in the picture")

		var authored := directions(actor)
		if authored.is_empty():
			errors.append("%s authors no directions" % subject)
		var seen_directions: Dictionary = {}
		for direction: String in authored:
			if not DIRECTIONS.has(direction):
				errors.append("%s has direction '%s'; expected one of %s" % [subject, direction, DIRECTIONS])
			if seen_directions.has(direction):
				errors.append("%s lists direction '%s' twice" % [subject, direction])
			seen_directions[direction] = true

		var clips: Dictionary = entry.get("clips", {})
		if clips.is_empty():
			errors.append("%s has no clips; a character has to be drawable" % subject)
		for clip_name: String in clips:
			errors.append_array(_validate_clip(
				"%s clip '%s'" % [subject, clip_name], clips[clip_name], authored,
				size, sizes.get(sheet_name, Vector2.ZERO)))

		for missing: String in entry.get("fallbacks", {}):
			var target := String(entry["fallbacks"][missing])
			if target == missing:
				errors.append("%s: fallback '%s' points at itself" % [subject, missing])
			elif not clips.has(target):
				errors.append("%s: fallback '%s' -> '%s', which this actor does not have"
					% [subject, missing, target])
	return errors


func _validate_clip(subject: String, raw: Variant, authored: PackedStringArray,
		size: Vector2i, sheet_size: Vector2) -> PackedStringArray:
	var errors: PackedStringArray = []
	if not (raw is Dictionary):
		errors.append("%s must be an object like {\"row\": 0, \"frames\": 4, \"fps\": 7}" % subject)
		return errors
	var clip: Dictionary = raw
	for key: String in clip:
		if not key.begins_with("_") and not CLIP_KEYS.has(key):
			errors.append("%s: unknown key '%s' (expected one of %s)" % [subject, key, CLIP_KEYS])
	var frames := int(clip.get("frames", 0))
	if frames < 1:
		errors.append("%s has %d frames; a clip needs at least one" % [subject, frames])
	if clip.has("fps") and float(clip["fps"]) < 0.0:
		errors.append("%s has a negative frame rate" % subject)
	if frames > 1 and float(clip.get("fps", 0.0)) <= 0.0:
		errors.append("%s has %d frames but no frame rate, so it would never advance"
			% [subject, frames])
	if clip.has("loop") and not (clip["loop"] is bool):
		errors.append("%s: loop must be true or false" % subject)

	var rows := authored
	if clip.has("directions"):
		if not (clip["directions"] is Array):
			errors.append("%s: directions must be a list" % subject)
			return errors
		rows = PackedStringArray()
		for d: Variant in clip["directions"]:
			var direction := String(d)
			if not DIRECTIONS.has(direction):
				errors.append("%s has direction '%s'; expected one of %s" % [subject, direction, DIRECTIONS])
			rows.append(direction)

	var row := int(clip.get("row", 0))
	if row < 0:
		errors.append("%s starts at row %d" % [subject, row])
	if sheet_size != Vector2.ZERO:
		var bottom := (row + rows.size()) * size.y
		if bottom > int(sheet_size.y):
			errors.append("%s needs rows up to y=%d but its sheet is %dpx tall -- re-run tools/gen_art.py"
				% [subject, bottom, int(sheet_size.y)])
		if frames * size.x > int(sheet_size.x):
			errors.append("%s needs %d columns (%dpx) but its sheet is %dpx wide"
				% [subject, frames, frames * size.x, int(sheet_size.x)])
	return errors


static func _validate_size(subject: String, block: Dictionary, key: String) -> PackedStringArray:
	var errors: PackedStringArray = []
	var raw: Variant = block.get(key)
	if raw == null:
		errors.append("%s has no '%s'" % [subject, key])
	elif not (raw is Array) or (raw as Array).size() != 2:
		errors.append("%s: %s must be [width, height]" % [subject, key])
	return errors
