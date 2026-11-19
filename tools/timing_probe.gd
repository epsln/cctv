extends SceneTree
## Timing probe: follow the analyser with a live MusicalClock (no rendering)
## and measure how well clock and scheduler track the musical state.
##
##   godot --headless --path . -s res://tools/timing_probe.gd -- \
##       --duration=30 --port=9870 --out=res://bench/results/timing.json
##
## Records, per frame: timing source, bpm, beat position, phase error against
## the latest analyser state, state age. Also records one scheduled event per
## beat with its lateness. Writes a summary and exits non-zero on GDScript errors.

const SETTLE_S := 3.0

var clock: MusicalClock
var rx: MusicalStateReceiver
var sched: Scheduler
var duration := 30.0
var out_path := "res://bench/results/timing.json"
var frames: Array = []
var events: Array = []
var _t0 := 0


func _initialize() -> void:
	var a := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		a[kv[0]] = kv[1] if kv.size() > 1 else "true"
	duration = float(a.get("duration", duration))
	out_path = a.get("out", out_path)
	Engine.max_fps = int(a.get("fps", 60))
	clock = MusicalClock.new()
	clock.mode = MusicalClock.Mode.LIVE
	clock.process_priority = -100
	root.add_child(clock)
	rx = MusicalStateReceiver.new()
	rx.port = int(a.get("port", MusicalStateReceiver.DEFAULT_PORT))
	rx.clock = clock
	root.add_child(rx)
	sched = Scheduler.new()
	sched.clock = clock
	root.add_child(sched)
	sched.executed.connect(_on_event)
	_schedule_beat()
	_t0 = Time.get_ticks_usec()


func _schedule_beat() -> void:
	sched.schedule(_schedule_beat, "next_beat", 0.0, "beat")


func _on_event(ev: Dictionary) -> void:
	events.append({"t": ev["executed_time"], "late_ms": ev["late_ms"], "src": ev["timing_source"], "bpm": ev["bpm"]})


func _process(_delta: float) -> bool:
	var d := clock.describe()
	(
		frames
		. append(
			{
				"t": clock.time,
				"src": d["timing_source"],
				"bpm": d["bpm"],
				"pos": d["beat_position"],
				"err": d["phase_error"],
				"conf": d["beat_confidence"],
				"age_ms": rx.stats["age_ms"],
				"bar": d["bar_source"],
			}
		)
	)
	if (Time.get_ticks_usec() - _t0) / 1e6 >= duration:
		_finish()
		return true
	return false


func _finish() -> void:
	var followed := frames.filter(func(f): return f["src"] != "internal")
	# Phase error statistics exclude the first SETTLE_S of following (initial convergence).
	var t_lock: float = followed[0]["t"] if not followed.is_empty() else INF
	var settled := followed.filter(func(f): return f["t"] >= t_lock + SETTLE_S)
	var errs := settled.map(func(f): return absf(f["err"]) * 60.0 / f["bpm"] * 1000.0)
	errs.sort()
	var lates := events.map(func(e): return e["late_ms"])
	lates.sort()
	var summary := {
		"duration_s": duration,
		"frames": frames.size(),
		"followed_ratio": followed.size() / maxf(1.0, frames.size()),
		"first_follow_s": t_lock,
		"phase_error_ms_p50": _pct(errs, 0.5),
		"phase_error_ms_p95": _pct(errs, 0.95),
		"beat_events": events.size(),
		"event_late_ms_p50": _pct(lates, 0.5),
		"event_late_ms_max": lates[-1] if not lates.is_empty() else -1.0,
		"receiver": rx.describe(),
		"clock": clock.describe(),
	}
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"summary": summary, "frames": frames, "events": events}, " "))
	print(JSON.stringify(summary, " "))


static func _pct(sorted: Array, q: float) -> float:
	if sorted.is_empty():
		return -1.0
	return float(sorted[mini(sorted.size() - 1, int(q * sorted.size()))])
