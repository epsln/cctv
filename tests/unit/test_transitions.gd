extends "res://tests/test_case.gd"

var am: AssetManager
var tc: TransitionCompositor


func before_each() -> void:
	am = AssetManager.new()
	add_child(am)
	for c in [["red", Color.RED], ["blue", Color.BLUE]]:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(c[1])
		img.save_png("user://%s.png" % c[0])
		am.register({"id": c[0], "type": "image", "path": "user://%s.png" % c[0]})
	tc = TransitionCompositor.new()
	tc.set_size_px(Vector2i(32, 16))
	add_child(tc)


func comp(asset: String) -> Composition:
	var c := Composition.new()
	c.build({"id": asset, "layers": [{"id": "l", "asset": asset}]}, am, Vector2i(32, 16))
	return c


func test_progress_from_clock_and_finish() -> void:
	tc.set_active(comp("red"), 0.0)
	var finished := []
	tc.transition_finished.connect(func(id): finished.append(id))
	eq(tc.start(comp("blue"), "crossfade", 1.0, 2.0), OK)
	check(tc.is_transitioning())
	tc.update(2.0, {})
	near(tc.progress, 0.5)
	eq(tc.describe()["incoming"], "blue")
	tc.update(3.0, {})
	check(not tc.is_transitioning())
	eq(tc.active_id(), "blue")
	eq(finished, ["blue"])


func test_old_composition_released() -> void:
	var a := comp("red")
	tc.set_active(a, 0.0)
	tc.start(comp("blue"), "wipe", 0.0, 0.5)
	tc.update(1.0, {})
	check(a.is_queued_for_deletion(), "slot A freed")


func test_interrupting_transition_completes_previous() -> void:
	tc.set_active(comp("red"), 0.0)
	tc.start(comp("blue"), "crossfade", 0.0, 4.0)
	tc.start(comp("red"), "glitch_cut", 1.0, 1.0)
	eq(tc.active_id(), "blue")
	eq(tc.describe()["incoming"], "red")


func test_cut_and_invalid() -> void:
	tc.set_active(comp("red"), 0.0)
	var rejected := comp("blue")
	eq(tc.start(rejected, "dissolve", 0.0, 1.0), ERR_INVALID_PARAMETER)
	rejected.release()
	tc.start(comp("blue"), "cut", 0.0, 0.0)
	eq(tc.active_id(), "blue")


func test_crossfade_pixels() -> void:
	if not gpu():
		return
	tc.set_active(comp("red"), 0.0)
	tc.start(comp("blue"), "crossfade", 0.0, 2.0)
	tc.update(1.0, {})
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var p := center_pixel(tc.get_texture())
	near(p.r, 0.5, 0.05, "half red %s" % p)
	near(p.b, 0.5, 0.05, "half blue")


func test_wipe_pixels() -> void:
	if not gpu():
		return
	tc.set_active(comp("red"), 0.0)
	tc.start(comp("blue"), "wipe", 0.0, 2.0)
	tc.update(1.0, {})
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := tc.get_texture().get_image()
	check(img.get_pixel(2, 8).b > 0.9, "left already blue")
	check(img.get_pixel(29, 8).r > 0.9, "right still red")
