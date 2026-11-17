extends Node
## Base class for tests. Records assertion failures instead of aborting.

var errors: Array[String] = []


func check(cond: bool, msg := "assertion failed") -> void:
	if not cond:
		errors.append(msg)


func eq(a: Variant, b: Variant, msg := "") -> void:
	if a != b:
		errors.append("%s expected %s == %s" % [msg, str(a), str(b)])


func near(a: float, b: float, eps := 1e-4, msg := "") -> void:
	if absf(a - b) > eps:
		errors.append("%s expected %f ~= %f" % [msg, a, b])


func frames(n := 1) -> void:
	for i in n:
		await get_tree().process_frame


## True when a real renderer is available (pixel read-back tests).
func gpu() -> bool:
	return DisplayServer.get_name() != "headless"


func solid(color: Color, sz := Vector2i(32, 32)) -> ImageTexture:
	var img := Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func center_pixel(tex: Texture2D) -> Color:
	var img := tex.get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)
