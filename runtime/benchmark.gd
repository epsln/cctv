class_name Benchmark
extends Node
## Milestone 1 feasibility benchmark.
##
##   godot --path . res://scenes/benchmark.tscn -- [options]
##     --duration=S        run length in seconds (default 60)
##     --sample=S          timeline sample interval for long sessions (default 10)
##     --switch-beats=N    trigger a composition switch every N beats (default 8)
##     --seek-every=S      seek a random video every S seconds (default 5)
##     --out=PATH          result JSON (default bench/results/<timestamp>.json)
##     --show=PATH         workload (default res://shows/bench.json)
##     --vsync=off         measure headroom instead of vsync-locked pacing
##     --fps=N             override the show's target frame rate (e.g. 30 on a laptop)
##
## Family shows (shows/bench_families.json) have no fixed compositions: each
## switch applies the next composition family with a fresh seed, and beat
## events (cuts, swaps, spawns) run between switches.
##
## Measures frame pacing, late frames, prepare/switch latency, seek latency,
## decoder drift corrections, process CPU, RSS and GPU memory, an upload
## micro-benchmark, and RSS growth over the session. Exits 1 on runtime errors.

const DEFAULT_SHOW := "res://shows/bench.json"
const KINDS := ["crossfade", "wipe", "glitch_cut", "cut"]

var args := {}
var perf: PerformanceRoot
var duration := 60.0
var sample_every := 10.0
var switch_beats := 8
var seek_every := 5.0

var switches: Array = []
var seeks: Array = []
var timeline: Array = []
var _t0_usec := 0
var _last_sample := 0.0
var _last_seek := 0.0
var _next_switch_beat := 0
var _switch_i := 0
var _cpu0 := 0.0
var _rng := RandomNumberGenerator.new()
var _done := false
var _max_decoders := 0


func _ready() -> void:
	args = PerformanceRoot.parse_args(OS.get_cmdline_user_args())
	duration = float(args.get("duration", 60))
	sample_every = float(args.get("sample", 10))
	switch_beats = int(args.get("switch-beats", 8))
	seek_every = float(args.get("seek-every", 5))
	_rng.seed = int(args.get("seed", 1))
	if args.get("vsync", "") == "off":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	perf = PerformanceRoot.new()
	perf.name = "PerformanceRoot"
	perf.args = {"show": args.get("show", DEFAULT_SHOW), "no-operator": true, "no-projector": true}
	if args.has("fps"):
		perf.args["fps"] = args["fps"]
	add_child(perf)
	_next_switch_beat = switch_beats
	_t0_usec = Time.get_ticks_usec()
	_cpu0 = cpu_seconds()


func elapsed() -> float:
	return (Time.get_ticks_usec() - _t0_usec) / 1_000_000.0


func _process(_d: float) -> void:
	if _done:
		return
	var e := elapsed()
	_max_decoders = maxi(_max_decoders, perf.assets.active_videos())
	var beat := perf.clock.beat_index()
	if beat >= _next_switch_beat and not perf.compositor.is_transitioning():
		_next_switch_beat = beat + switch_beats
		_switch()
	if e - _last_seek >= seek_every:
		_last_seek = e
		_seek_random()
	if e - _last_sample >= sample_every or timeline.is_empty():
		_last_sample = e
		timeline.append(sample())
	if e >= duration:
		_done = true
		_finish()


func _switch() -> void:
	if perf.composition_ids().is_empty() and perf.director.family:
		_switch_family()
		return
	var ids := perf.composition_ids()
	var target: String = ids[(ids.find(perf.compositor.active_id()) + 1) % ids.size()]
	var kind: String = KINDS[_switch_i % KINDS.size()]
	_switch_i += 1
	var t0 := Time.get_ticks_usec()
	var err := perf.trigger(target, kind, 2.0, true)
	(
		switches
		. append(
			{
				"t": perf.clock.time,
				"to": target,
				"kind": kind,
				"ok": err == OK,
				"prepare_ms": (Time.get_ticks_usec() - t0) / 1000.0,
			}
		)
	)


func _switch_family() -> void:
	var fams := CompositionFamily.ids()
	var target: String = fams[(fams.find(perf.director.family.family_id) + 1) % fams.size()]
	var kind: String = KINDS[_switch_i % KINDS.size()]
	_switch_i += 1
	var t0 := Time.get_ticks_usec()
	var err := perf.director.apply_family(target, null, -1, {}, kind, 2.0, "next_beat")
	(
		switches
		. append(
			{
				"t": perf.clock.time,
				"to": target,
				"seed": perf.director.family.seed if perf.director.family else -1,
				"kind": kind,
				"ok": err == OK,
				"prepare_ms": (Time.get_ticks_usec() - t0) / 1000.0,
			}
		)
	)


func _seek_random() -> void:
	var vids := perf.assets.get_children().filter(
		func(s): return s is TheoraVideoSource and s.state == VisualSource.State.READY
	)
	if vids.is_empty():
		return
	var v: TheoraVideoSource = vids[_rng.randi() % vids.size()]
	var target := _rng.randf() * maxf(v.get_duration() - 0.5, 0.0)
	v.start_time = perf.clock.time - target  # move the logical playhead
	v.update(perf.clock.time)
	seeks.append({"t": perf.clock.time, "source": v.source_id, "to": target, "ms": v.last_seek_usec / 1000.0})


static func cpu_seconds() -> float:
	var f := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if f == null:
		return 0.0
	# /proc files report size 0, so read line-wise rather than get_as_text().
	var parts := f.get_line().split(")")[-1].split(" ", false)
	if parts.size() < 13:
		return 0.0
	# fields after ')' start at index 3 (state); utime=14, stime=15 -> offsets 11, 12
	return (float(parts[11]) + float(parts[12])) / 100.0


static func rss_mb() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return OS.get_static_memory_usage() / 1048576.0
	while not f.eof_reached():
		var l := f.get_line()
		if l.begins_with("VmRSS:"):
			return float(l.split(" ", false)[1]) / 1024.0
	return 0.0


func sample() -> Dictionary:
	var m := perf.metrics.summary()
	var drift_seeks := 0
	for s in perf.assets.get_children():
		if s is TheoraVideoSource:
			drift_seeks += s.seek_count
	return {
		"elapsed": elapsed(),
		"clock": perf.clock.time,
		"recent_fps": m["recent_fps"],
		"late_frames": m["late_frames"],
		"p99_ms": m["p99_ms"],
		"rss_mb": rss_mb(),
		"video_decoders": perf.assets.active_videos(),
		"family": perf.director.family.family_id if perf.director and perf.director.family else "",
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"seek_count_total": drift_seeks,
	}


## Synchronous ImageTexture.update cost for typical decoded frame sizes.
static func upload_benchmark(n := 30) -> Dictionary:
	var out := {}
	for sz in [Vector2i(640, 360), Vector2i(1280, 720), Vector2i(1920, 1080)]:
		var img := Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.3, 0.5, 0.7))
		var tex := ImageTexture.create_from_image(img)
		var t0 := Time.get_ticks_usec()
		for i in n:
			img.set_pixel(i % sz.x, 0, Color(i / float(n), 0, 0))
			tex.update(img)
		RenderingServer.force_sync()
		out["%dx%d" % [sz.x, sz.y]] = (Time.get_ticks_usec() - t0) / 1000.0 / n
	return out


static func slope_per_hour(tl: Array, key: String) -> float:
	if tl.size() < 2:
		return 0.0
	var n := float(tl.size())
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	for s in tl:
		var x: float = s["elapsed"]
		var y: float = s[key]
		sx += x
		sy += y
		sxx += x * x
		sxy += x * y
	var den := n * sxx - sx * sx
	return 0.0 if den == 0.0 else (n * sxy - sx * sy) / den * 3600.0


static func evaluate(m: Dictionary, fps: float) -> Dictionary:
	var period := 1000.0 / fps
	var checks := {
		"mean_fps": m["mean_fps"] >= 0.98 * fps,
		"late_ratio": m["late_ratio"] <= 0.01,
		"p99_frame": m["p99_ms"] <= 1.5 * period,
	}
	checks["pass"] = checks.values().all(func(v): return v)
	return checks


func _finish() -> void:
	timeline.append(sample())
	var m := perf.metrics.summary()
	var cpu := cpu_seconds() - _cpu0
	var seek_ms := seeks.map(func(s): return s["ms"])
	var prep_ms := switches.map(func(s): return s["prepare_ms"])
	var result := {
		"version": 1,
		"date": Time.get_datetime_string_from_system(true),
		"godot": Engine.get_version_info()["string"],
		"renderer": RenderingServer.get_video_adapter_name(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"display": DisplayServer.get_name(),
		"cpu_name": OS.get_processor_name(),
		"cpu_count": OS.get_processor_count(),
		"show": perf.show_path,
		"output": [perf.output_size.x, perf.output_size.y],
		"target_fps": perf.fps,
		"vsync": DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED,
		"duration_s": elapsed(),
		"frames": m,
		"acceptance": evaluate(m, perf.fps),
		"cpu_percent": 100.0 * cpu / maxf(elapsed(), 1e-6),  # 100 = one core
		# Excludes warm-up (first 25% / 60 s); only meaningful for long sessions.
		"rss_growth_mb_per_hour":
		slope_per_hour(timeline.filter(func(s): return s["elapsed"] >= minf(60.0, duration * 0.25)), "rss_mb"),
		"switches":
		{
			"count": switches.size(),
			"failed": switches.filter(func(s): return not s["ok"]).size(),
			"max_prepare_ms": prep_ms.max() if prep_ms else 0.0,
			"events": switches
		},
		"seeks": {"count": seeks.size(), "max_ms": seek_ms.max() if seek_ms else 0.0, "events": seeks},
		"upload_ms": upload_benchmark(),
		"max_video_decoders": _max_decoders,
		"sources": perf.assets.describe(),
		"timeline": timeline,
		"errors": perf.errors,
	}
	var path: String = args.get("out", "res://bench/results/bench_%d.json" % int(Time.get_unix_time_from_system()))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(result, "  "))
	f.close()
	print("benchmark: %s" % ProjectSettings.globalize_path(path))
	print(
		(
			"  fps=%.1f late=%d/%d p99=%.1fms rss=%.0fMB cpu=%.0f%% pass=%s"
			% [
				m["mean_fps"],
				m["late_frames"],
				m["frames"],
				m["p99_ms"],
				timeline[-1]["rss_mb"],
				result["cpu_percent"],
				result["acceptance"]["pass"]
			]
		)
	)
	get_tree().quit(1 if not perf.errors.is_empty() else 0)
