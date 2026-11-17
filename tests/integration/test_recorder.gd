extends "res://tests/test_case.gd"


func test_frame_file_naming() -> void:
	eq(Recorder.frame_file(42), "frame_000042.png")


func test_capture_writes_timestamped_frames() -> void:
	if not gpu():
		return
	var dir := "user://test_capture_%d" % Time.get_ticks_usec()
	var pr := PerformanceRoot.new()
	pr.args = {"show": "res://tests/fixtures/show.json", "replay": true, "no-projector": true,
		"no-operator": true, "capture": dir, "capture-every": "2"}
	add_child(pr)
	for i in 12:
		await RenderingServer.frame_post_draw
	pr.recorder.stop()
	check(pr.recorder.captured >= 3, "captured %d" % pr.recorder.captured)
	var lines := FileAccess.get_file_as_string(dir + "/frames.jsonl").strip_edges().split("\n")
	eq(lines.size(), pr.recorder.captured + pr.recorder.dropped)
	var prev_t := -1.0
	for l in lines:
		var rec: Dictionary = JSON.parse_string(l)
		eq(int(rec["frame"]) % 2, 0, "every 2nd frame")
		near(rec["t"], rec["frame"] / 30.0, 1e-6, "replay timestamp matches frame")
		check(rec["t"] > prev_t, "monotonic")
		prev_t = rec["t"]
		eq(rec["active"], "a")
		if not rec.get("dropped", false):
			check(FileAccess.file_exists(dir + "/" + rec["file"]), rec["file"])
	var img := Image.load_from_file(dir + "/" + JSON.parse_string(lines[0])["file"])
	eq(img.get_size(), Vector2i(64, 36))
	pr.queue_free()


func test_scale_and_drop_accounting() -> void:
	if not gpu():
		return
	var dir := "user://test_capture_s_%d" % Time.get_ticks_usec()
	var pr := PerformanceRoot.new()
	pr.args = {"show": "res://tests/fixtures/show.json", "replay": true, "no-projector": true, "no-operator": true}
	add_child(pr)
	pr.start_capture(dir, 1, 0.5)
	pr.recorder.max_pending = 0  # force drops
	for i in 4:
		await RenderingServer.frame_post_draw
	check(pr.recorder.dropped > 0, "drops counted")
	pr.recorder.max_pending = 8
	for i in 4:
		await RenderingServer.frame_post_draw
	pr.recorder.stop()
	var lines := FileAccess.get_file_as_string(dir + "/frames.jsonl").strip_edges().split("\n")
	var last: Dictionary = JSON.parse_string(lines[-1])
	eq(Image.load_from_file(dir + "/" + last["file"]).get_size(), Vector2i(32, 18))
	pr.queue_free()
