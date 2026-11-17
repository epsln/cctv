extends "res://tests/test_case.gd"

var fb: FeedbackPass
var src: ImageTexture


func before_each() -> void:
	fb = FeedbackPass.new()
	add_child(fb)
	src = solid(Color.RED, Vector2i(16, 16))
	fb.setup(src, Vector2i(16, 16))
	fb.set_params({"decay": 0.5, "zoom": 1.0, "spin": 0.0, "beat_cut": 0.0})


func test_ping_pong_never_samples_write_target() -> void:
	for i in 4:
		fb.update({})
		var w := fb.write_index()
		var hist: Texture2D = fb._mats[w].get_shader_parameter("history")
		check(hist == fb._vps[1 - w].get_texture(), "history is the other target")
		check(fb.get_output() == fb._vps[w].get_texture(), "output is write target")
	eq(fb.frames_rendered, 4)


func test_reset_zeroes_history_for_one_frame() -> void:
	fb.update({})
	eq(fb._mats[fb.write_index()].get_shader_parameter("history_gain"), 0.0, "first frame clean")
	fb.update({})
	eq(fb._mats[fb.write_index()].get_shader_parameter("history_gain"), 1.0)
	fb.reset()
	fb.update({})
	eq(fb._mats[fb.write_index()].get_shader_parameter("history_gain"), 0.0)


func test_clock_seek_resets() -> void:
	var c := MusicalClock.new()
	c.mode = MusicalClock.Mode.REPLAY
	add_child(c)
	fb.bind_clock(c)
	c.seek(3.0)
	eq(fb.resets, 1)


func test_disabled_passthrough() -> void:
	fb.enabled = false
	check(fb.get_output() == src)


func _render() -> void:
	fb.update({})
	await RenderingServer.frame_post_draw


func test_trails_decay_and_reset_pixels() -> void:
	if not gpu():
		return
	await _render()
	await _render()
	near(center_pixel(fb.get_output()).r, 1.0, 0.02, "red input")
	var black := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	black.fill(Color.BLACK)
	src.update(black)
	await _render()
	near(center_pixel(fb.get_output()).r, 0.5, 0.03, "trail at decay 0.5")
	await _render()
	near(center_pixel(fb.get_output()).r, 0.25, 0.03, "trail decays")
	fb.reset()
	await _render()
	near(center_pixel(fb.get_output()).r, 0.0, 0.02, "reset clears history")
