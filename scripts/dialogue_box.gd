## Draws whatever the Dialogue autoload is running.
##
## Pure view: it never decides what comes next, it only reflects signals and
## forwards input. That is why tests can run every conversation without a
## window open.
extends CanvasLayer

const CHARS_PER_SECOND := 45.0

const CHOICE_FONT_SIZE := 9
const CHOICE_BG := Color(0.13, 0.15, 0.21, 1.0)
const CHOICE_BG_HOVER := Color(0.21, 0.25, 0.34, 1.0)
## Padding around the content: the panel style's top and bottom margins.
const PANEL_PADDING := 10.0
## Never shrink below this, so short lines still read as a dialogue box.
const MIN_HEIGHT := 34.0

@onready var panel: Panel = $Panel
@onready var speaker_label: Label = $Panel/Layout/Speaker
@onready var body_label: RichTextLabel = $Panel/Layout/Body
@onready var choice_box: VBoxContainer = $Panel/Layout/Choices
@onready var layout: VBoxContainer = $Panel/Layout

var _full_text := ""
var _revealed := 0.0
var _choice_styles: Dictionary = {}


func _ready() -> void:
	_build_choice_styles()
	panel.visible = false
	Dialogue.line_shown.connect(_on_line_shown)
	Dialogue.choices_offered.connect(_on_choices_offered)
	Dialogue.dialogue_finished.connect(_on_finished)


func _process(delta: float) -> void:
	if not panel.visible or _revealed >= _full_text.length():
		return
	_revealed = minf(_revealed + delta * CHARS_PER_SECOND, float(_full_text.length()))
	body_label.visible_characters = int(_revealed)


func _unhandled_input(event: InputEvent) -> void:
	if not panel.visible:
		return
	if event.is_action_pressed("interact") and not _text_complete():
		# First press finishes the typewriter, second advances -- the Player
		# handles the advance, so only swallow the input while still typing.
		_revealed = float(_full_text.length())
		body_label.visible_characters = -1
		get_viewport().set_input_as_handled()
		return
	for i: int in choice_box.get_child_count():
		if event.is_action_pressed("choice_%d" % (i + 1)):
			Dialogue.choose(i)
			get_viewport().set_input_as_handled()
			return


## Buttons default to desktop-sized padding, which at a 320x192 base viewport
## leaves no room for the line the choices are answering.
func _build_choice_styles() -> void:
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = CHOICE_BG_HOVER if state in ["hover", "pressed"] else CHOICE_BG
		style.content_margin_left = 3.0
		style.content_margin_right = 3.0
		style.content_margin_top = 0.0
		style.content_margin_bottom = 0.0
		style.corner_radius_top_left = 2
		style.corner_radius_top_right = 2
		style.corner_radius_bottom_right = 2
		style.corner_radius_bottom_left = 2
		_choice_styles[state] = style


func _text_complete() -> bool:
	return _revealed >= float(_full_text.length())


func _on_line_shown(speaker: String, text: String) -> void:
	panel.visible = true
	speaker_label.text = speaker
	speaker_label.visible = not speaker.is_empty()
	_full_text = text
	_revealed = 0.0
	body_label.text = text
	body_label.visible_characters = 0
	_clear_choices()
	_fit_panel()


func _on_choices_offered(choices: Array) -> void:
	_clear_choices()
	for i: int in choices.size():
		var button := Button.new()
		button.text = "%d. %s" % [i + 1, choices[i]]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_NONE
		# The base viewport is 320x192, so the theme default would swallow the
		# whole box. Keep choices smaller than the line they answer.
		button.add_theme_font_size_override("font_size", CHOICE_FONT_SIZE)
		for state: String in _choice_styles:
			button.add_theme_stylebox_override(state, _choice_styles[state])
		button.pressed.connect(Dialogue.choose.bind(i))
		choice_box.add_child(button)
	choice_box.visible = true
	_fit_panel()


func _on_finished(_id: String) -> void:
	panel.visible = false
	_clear_choices()


## Size the box to whatever is in it, growing upward from the bottom edge.
##
## A one-line sign gets a thin box; a long line with three choices gets a tall
## one. The wait is needed because a RichTextLabel only knows how many lines it
## wraps to once the container has given it a width.
func _fit_panel() -> void:
	await get_tree().process_frame
	if not is_instance_valid(layout):
		return
	var content: float = layout.get_combined_minimum_size().y
	panel.offset_top = -maxf(MIN_HEIGHT, content + PANEL_PADDING)


func _clear_choices() -> void:
	for child: Node in choice_box.get_children():
		child.queue_free()
		choice_box.remove_child(child)
	choice_box.visible = false
