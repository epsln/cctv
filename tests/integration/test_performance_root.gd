extends "res://tests/test_case.gd"

var pr: PerformanceRoot


func before_each() -> void:
	pr = PerformanceRoot.new()
	pr.args = {"show": "res://tests/fixtures/show.json", "replay": true, "no-projector": true, "no-operator": true}
	add_child(pr)


func test_parse_args() -> void:
	var a := PerformanceRoot.parse_args(PackedStringArray(["--show=x.json", "--replay", "junk", "--fps=30"]))
	eq(a, {"show": "x.json", "replay": true, "fps": "30"})


func test_show_loads_initial_composition() -> void:
	eq(pr.errors.size(), 0, str(pr.errors))
	eq(pr.output_size, Vector2i(64, 36))
	eq(pr.clock.mode, MusicalClock.Mode.REPLAY)
	eq(pr.compositor.active_id(), "a")
	check(pr.feedback.enabled)


func test_replay_clock_advances_per_frame() -> void:
	await frames(3)
	near(pr.clock.time, pr.clock.frame / 30.0, 1e-6)
	check(pr.clock.frame >= 3)


func test_quantized_trigger_starts_on_next_beat() -> void:
	pr.clock.seek(0.1)
	eq(pr.trigger("b", "crossfade", 1.0, true), OK)
	near(pr.compositor.t_start, 0.5, 1e-6, "next beat at 120bpm")
	near(pr.compositor.duration, 0.5, 1e-6, "1 beat")


func test_invalid_composition_keeps_current() -> void:
	eq(pr.trigger("broken"), ERR_INVALID_DATA)
	eq(pr.trigger("nope"), ERR_DOES_NOT_EXIST)
	eq(pr.compositor.active_id(), "a")
	check(not pr.compositor.is_transitioning())


func test_full_transition_in_replay() -> void:
	pr.trigger("b", "wipe", 1.0, false)
	for i in 20:
		await frames(1)
	eq(pr.compositor.active_id(), "b")


func test_status_and_output() -> void:
	await frames(2)
	var s := pr.status()
	for k in ["time", "frame", "transition", "metrics", "sources"]:
		check(s.has(k), k)
	check(pr.output_texture() != null)


func test_operator_and_projector_build() -> void:
	var p2 := PerformanceRoot.new()
	p2.args = {"show": "res://tests/fixtures/show.json", "replay": true}
	add_child(p2)
	await frames(2)
	check(p2.projector != null and p2.operator != null)
	check(p2.projector.get_node("out").texture == p2.output_texture())
	p2.queue_free()


func test_output_has_pixels() -> void:
	if not gpu():
		return
	pr.trigger("b", "cut", 0.0, false)
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := pr.output_texture().get_image()
	check(img.get_size() == Vector2i(64, 36), "output size %s" % img.get_size())
	var c := img.get_pixel(32, 18)
	check(c.r + c.g + c.b > 0.05, "non-black output %s" % c)
