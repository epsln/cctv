extends "res://tests/test_case.gd"

const FIX := "res://tests/fixtures"
var am: AssetManager


func before_each() -> void:
	am = AssetManager.new()
	am.pdf_cache_dir = "user://test_pdf_cache_%d" % Time.get_ticks_usec()
	add_child(am)
	eq(am.load_manifest(FIX + "/manifest.json"), OK, "manifest")


func test_manifest_registers_assets() -> void:
	eq(am.assets.size(), 4)
	eq(am.ids_of_type("video"), ["clip"])
	eq(am.assets["clip"]["path"], FIX + "/clip.ogv", "relative path resolved")


func test_image_source_ready_with_metadata() -> void:
	var s := am.instance("still")
	eq(s.state, VisualSource.State.READY)
	eq(s.get_size(), Vector2i(64, 48))
	eq(s.get_duration(), -1.0)
	check(not s.can_seek())
	check(s.metadata.has("faces"), "metadata passthrough")


func test_missing_image_fails_cleanly() -> void:
	var s := ImageSource.new("res://nope.png")
	add_child(s)
	s.prepare()
	eq(s.state, VisualSource.State.FAILED)
	check(not s.has_frame())


func test_pdf_page_rasterizes_async() -> void:
	var s := am.instance("doc2")
	eq(s.state, VisualSource.State.PREPARING, "async")
	for i in 300:
		if s.state != VisualSource.State.PREPARING:
			break
		await frames(1)
	eq(s.state, VisualSource.State.READY, s.error)
	check(s.get_size().x > 0, "page has pixels")
	eq(s.metadata["page"], 2)


func test_text_ticker_scrolls_with_clock() -> void:
	var s: TextSource = am.instance("tick")
	eq(s.state, VisualSource.State.READY)
	await frames(1)
	s.update(0.0)
	var a := s.get_scroll()
	s.update(1.0)
	near(s.get_scroll() - a, s.scroll_speed, 1e-3)


func test_video_source_properties() -> void:
	var s: TheoraVideoSource = am.instance("clip")
	eq(s.state, VisualSource.State.READY, s.error)
	near(s.get_duration(), 2.0, 0.1, "duration")
	check(s.can_seek() and s.can_loop())


func test_video_drift_correction_seeks() -> void:
	var s: TheoraVideoSource = am.instance("clip")
	await frames(2)
	s.update(1.5)  # far from decoder position -> correction
	eq(s.seek_count, 1)
	s.update(1.5)
	eq(s.seek_count, 1, "no further seek when in sync")


func test_media_time_loops() -> void:
	var s: TheoraVideoSource = am.instance("clip")
	s.start_time = 1.0
	near(s.media_time(0.5), 0.0, 1e-6, "before start clamps")
	near(s.media_time(1.0 + s.get_duration() + 0.5), 0.5, 1e-3, "wraps")
	s.loop = false
	near(s.media_time(100.0), s.get_duration(), 1e-6, "clamps when not looping")


func test_shared_vs_independent_instances() -> void:
	var a := am.shared("clip")
	var b := am.shared("clip")
	var c := am.instance("clip")
	check(a == b, "shared playhead")
	check(a != c, "independent instance")
	check(a.source_id != c.source_id)


func test_describe_reports_state() -> void:
	var s := am.instance("still")
	var d := s.describe()
	eq(d["state"], "READY")
	eq(d["type"], "ImageSource")
