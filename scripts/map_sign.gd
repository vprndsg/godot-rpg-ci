## A readable sign. Maps place these with a `signs` entry; the solid tile it
## sits on comes from the tile layers, this node only supplies the text.
class_name MapSign
extends Area2D

var text: String = ""


func configure(sign_text: String) -> void:
	text = sign_text


func interact(_player: Player) -> void:
	Dialogue.show_line("", text)
