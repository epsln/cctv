class_name Scheduler
extends Node
## Beat-aware event scheduler.
##
## Events target a beat position, not a wall-clock time, so they stay on the
## beat when the tempo changes or the clock slews towards external timing.
## Each event has an ID and an explicit outcome: executed (with lateness),
## cancelled, or rejected. A request for "next_bar" without bar alignment is
## rejected rather than silently snapped to a beat.
##
## Quantisation ("when"):
##   "now"        execute at the next frame
##   "next_beat"  next beat onset
##   "next_bar"   next bar start (requires clock.bar_aligned)
##   "beats"      `n` beats from now (fractional allowed)
##   "grid"       next multiple of `n` beats (e.g. 2, 8, 16)

signal executed(event: Dictionary)

const WHEN := ["now", "next_beat", "next_bar", "beats", "grid"]
const LOG_SIZE := 256

var clock: MusicalClock
## Executions later than this (ms) count as late.
var late_threshold_ms := 20.0
var errors: PackedStringArray = []

var _next_id := 1
var _pending: Array = []  # events sorted by target position
var _log: Array = []  # recent finished events (ring)
var _actions := {}  # id -> Callable
var _stats := {"scheduled": 0, "executed": 0, "late": 0, "cancelled": 0, "rejected": 0, "max_late_ms": 0.0}
var _late_sum_ms := 0.0


func _ready() -> void:
	process_priority = -90  # after MusicalClock (-100), before rendering updates


## Schedule `action`. Returns the event ID, or -1 if rejected (see last_event()).
func schedule(action: Callable, when := "next_beat", n := 0.0, label := "") -> int:
	var id := _next_id
	_next_id += 1
	var ev := {
		"id": id,
		"label": label,
		"when": when,
		"n": n,
		"requested_time": clock.time,
		"requested_position": clock.beat_position(),
		"status": "pending",
	}
	var target := _target(when, n)
	if is_nan(target):
		ev["status"] = "rejected"
		ev["reason"] = ("no bar alignment" if when == "next_bar" else "invalid quantisation %s/%s" % [when, n])
		_stats["rejected"] += 1
		errors.append("event %d (%s) rejected: %s" % [id, label, ev["reason"]])
		_record(ev)
		return -1
	ev["target_position"] = target
	ev["target_time"] = clock.time_at_position(target)
	_actions[id] = action
	var i := _pending.bsearch_custom(target, func(a, t): return float(a["target_position"]) <= t)
	_pending.insert(i, ev)
	_stats["scheduled"] += 1
	return id


func _target(when: String, n: float) -> float:
	var p := clock.beat_position()
	match when:
		"now":
			return p
		"next_beat":
			return floorf(p) + 1.0
		"next_bar":
			return clock.next_bar_position() if clock.bar_aligned else NAN
		"beats":
			return p + n if n >= 0.0 else NAN
		"grid":
			return (floorf(p / n) + 1.0) * n if n > 0.0 else NAN
	return NAN


func cancel(id: int) -> bool:
	for i in _pending.size():
		if int(_pending[i]["id"]) == id:
			var ev: Dictionary = _pending[i]
			_pending.remove_at(i)
			_actions.erase(id)
			ev["status"] = "cancelled"
			_stats["cancelled"] += 1
			_record(ev)
			return true
	return false


func _process(_delta: float) -> void:
	run_due()


## Execute every event whose target position has been reached.
func run_due() -> void:
	var p := clock.beat_position()
	while not _pending.is_empty() and float(_pending[0]["target_position"]) <= p + 1e-9:
		var ev: Dictionary = _pending.pop_front()
		var action: Callable = _actions[ev["id"]]
		_actions.erase(ev["id"])
		var late_beats := p - float(ev["target_position"])
		var late_ms := late_beats * clock.beat_length() * 1000.0
		ev["status"] = "executed"
		ev["executed_time"] = clock.time
		ev["executed_frame"] = clock.frame
		ev["executed_position"] = p
		ev["late_ms"] = late_ms
		ev["bpm"] = clock.bpm
		ev["timing_source"] = clock.timing_source
		_stats["executed"] += 1
		_late_sum_ms += late_ms
		_stats["max_late_ms"] = maxf(_stats["max_late_ms"], late_ms)
		if late_ms > late_threshold_ms:
			_stats["late"] += 1
		if action.is_valid():
			var r = action.call()
			if r is int and r != OK:
				ev["status"] = "failed"
				ev["error"] = r
		_record(ev)
		executed.emit(ev)


func _record(ev: Dictionary) -> void:
	_log.append(ev)
	if _log.size() > LOG_SIZE:
		_log.pop_front()


func pending() -> Array:
	return _pending.duplicate(true)


func recent(n := 16) -> Array:
	return _log.slice(maxi(0, _log.size() - n))


func last_event() -> Dictionary:
	return _log[-1] if not _log.is_empty() else {}


func describe() -> Dictionary:
	var s := _stats.duplicate()
	s["mean_late_ms"] = _late_sum_ms / maxf(1.0, float(_stats["executed"]))
	s["pending"] = _pending.size()
	return s
