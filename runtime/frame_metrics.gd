class_name FrameMetrics
extends RefCounted
## Frame-time statistics. A frame is "late" when its interval exceeds
## late_factor x the target period (i.e. at least one vsync was missed).

var target_fps := 60.0
var late_factor := 1.5
var window := 600
var frames := 0
var late_frames := 0
var total_usec := 0
var max_usec := 0
var _ring: PackedInt64Array = []
var _ri := 0


func _init(fps := 60.0) -> void:
	target_fps = fps


func record(dt_usec: int) -> void:
	frames += 1
	total_usec += dt_usec
	max_usec = maxi(max_usec, dt_usec)
	if dt_usec > int(late_factor * 1_000_000.0 / target_fps):
		late_frames += 1
	if _ring.size() < window:
		_ring.append(dt_usec)
	else:
		_ring[_ri] = dt_usec
		_ri = (_ri + 1) % window


func percentile_ms(p: float) -> float:
	if _ring.is_empty():
		return 0.0
	var s := _ring.duplicate()
	s.sort()
	return s[clampi(int(ceil(p / 100.0 * s.size())) - 1, 0, s.size() - 1)] / 1000.0


func mean_fps() -> float:
	return frames * 1_000_000.0 / total_usec if total_usec > 0 else 0.0


func recent_fps() -> float:
	if _ring.is_empty():
		return 0.0
	var sum := 0
	for v in _ring:
		sum += v
	return _ring.size() * 1_000_000.0 / sum


func summary() -> Dictionary:
	return {
		"frames": frames,
		"late_frames": late_frames,
		"late_ratio": float(late_frames) / maxi(frames, 1),
		"mean_fps": mean_fps(),
		"recent_fps": recent_fps(),
		"p50_ms": percentile_ms(50),
		"p95_ms": percentile_ms(95),
		"p99_ms": percentile_ms(99),
		"max_ms": max_usec / 1000.0,
	}
