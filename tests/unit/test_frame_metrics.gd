extends "res://tests/test_case.gd"


func test_late_frames_and_percentiles() -> void:
	var m := FrameMetrics.new(60.0)
	for i in 98:
		m.record(16_667)
	m.record(40_000)
	m.record(50_000)
	eq(m.frames, 100)
	eq(m.late_frames, 2)
	near(m.percentile_ms(50), 16.667, 0.01)
	near(m.percentile_ms(100), 50.0, 0.01)
	near(m.summary()["max_ms"], 50.0)


func test_ring_window() -> void:
	var m := FrameMetrics.new(60.0)
	m.window = 4
	for v in [100_000, 100_000, 100_000, 100_000, 10_000, 10_000, 10_000, 10_000]:
		m.record(v)
	near(m.percentile_ms(99), 10.0, 0.001, "old samples evicted")
	eq(m.frames, 8)


func test_next_beat_time() -> void:
	var c := MusicalClock.new()
	c.bpm = 120
	near(c.next_beat_time(0.0), 0.5, 1e-9, "strictly after onset")
	near(c.next_beat_time(0.6), 1.0, 1e-9)
	c.free()
