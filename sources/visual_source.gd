class_name VisualSource
extends Node
## Common interface for anything that supplies frames to a layer.
##
## Sources are driven by the MusicalClock: the owner calls update(t) each frame
## with clock time; sources never read wall time directly. A source *instance*
## owns a playhead. Layers sharing an instance share the playhead; independent
## playback of the same file requires separate instances (see AssetManager).

signal state_changed(state: State)

enum State { UNPREPARED, PREPARING, READY, FAILED }

var source_id := ""
var asset_id := ""
var state: State = State.UNPREPARED
var error := ""
## Arbitrary metadata (face tracks, document regions...) consumed by annotation layers.
var metadata := {}
## Clock time at which this instance started; playhead = (t - start_time) * speed.
var start_time := 0.0
var speed := 1.0
var loop := true


func prepare() -> void:
	_set_state(State.READY)


func get_texture() -> Texture2D:
	return null


func get_size() -> Vector2i:
	var tex := get_texture()
	return Vector2i(tex.get_size()) if tex else Vector2i.ZERO


## Seconds, or -1.0 when not applicable (stills, text).
func get_duration() -> float:
	return -1.0


func get_playhead() -> float:
	return 0.0


func can_seek() -> bool:
	return false


func can_loop() -> bool:
	return false


func has_frame() -> bool:
	return state == State.READY and get_texture() != null


func seek(_seconds: float) -> void:
	pass


## Called each frame with clock time.
func update(_t: float) -> void:
	pass


## Map clock time to a media position, honouring loop.
func media_time(t: float) -> float:
	var pos := maxf((t - start_time) * speed, 0.0)
	var d := get_duration()
	if d > 0.0:
		pos = fposmod(pos, d) if loop else minf(pos, d)
	return pos


func describe() -> Dictionary:
	return {
		"id": source_id,
		"asset": asset_id,
		"type": get_class_name(),
		"state": State.keys()[state],
		"size": get_size(),
		"duration": get_duration(),
		"playhead": get_playhead(),
		"seek": can_seek(),
		"loop": can_loop(),
		"frame": has_frame(),
	}


func get_class_name() -> String:
	return "VisualSource"


func _set_state(s: State, err := "") -> void:
	state = s
	error = err
	state_changed.emit(s)
