class_name ImageSource
extends VisualSource
## Static image from any filesystem path (res://, user://, or absolute).

var path := ""
var _tex: Texture2D


func _init(p := "") -> void:
	path = p


func prepare() -> void:
	_set_state(State.PREPARING)
	var img := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	if img == null or img.is_empty():
		_set_state(State.FAILED, "cannot load image: " + path)
		return
	_tex = ImageTexture.create_from_image(img)
	_set_state(State.READY)


func set_image(img: Image) -> void:
	_tex = ImageTexture.create_from_image(img)
	_set_state(State.READY)


func get_texture() -> Texture2D:
	return _tex


func get_class_name() -> String:
	return "ImageSource"
