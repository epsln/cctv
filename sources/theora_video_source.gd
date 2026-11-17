class_name TheoraVideoSource
extends VisualSource
## Video backend using Godot's built-in Theora decoder (VideoStreamPlayer).
## Replaceable: any VisualSource subclass exposing the same interface can be
## swapped in (e.g. an FFmpeg GDExtension) without touching layers.
##
## Synchronisation: the decoder runs on its own playback clock; update(t)
## compares the decoder position with the clock-derived media time and seeks
## when drift exceeds drift_tolerance. In replay/capture set drift_tolerance
## to about one frame for tighter (but more expensive) sync.

var path := ""
var drift_tolerance := 0.25
var volume_db := -80.0

var seek_count := 0
var last_seek_usec := 0
var max_seek_usec := 0

var _player: VideoStreamPlayer
var _length := -1.0


func _init(p := "") -> void:
	path = p


func prepare() -> void:
	_set_state(State.PREPARING)
	if not FileAccess.file_exists(path):
		_set_state(State.FAILED, "missing video: " + path)
		return
	var stream := VideoStreamTheora.new()
	stream.file = path
	_player = VideoStreamPlayer.new()
	_player.stream = stream
	_player.loop = loop
	_player.volume_db = volume_db
	_player.visible = false  # we only consume the texture
	add_child(_player)
	_player.play()
	_length = _player.get_stream_length()
	if _length <= 0.0:
		_length = -1.0
	_set_state(State.READY)


func get_texture() -> Texture2D:
	return _player.get_video_texture() if _player else null


func get_duration() -> float:
	return _length


func get_playhead() -> float:
	return _player.stream_position if _player else 0.0


func can_seek() -> bool:
	return true


func can_loop() -> bool:
	return true


func is_playing() -> bool:
	return _player != null and _player.is_playing()


func seek(seconds: float) -> void:
	if _player == null:
		return
	var t0 := Time.get_ticks_usec()
	if not _player.is_playing():
		_player.play()
	_player.stream_position = seconds
	last_seek_usec = Time.get_ticks_usec() - t0
	max_seek_usec = maxi(max_seek_usec, last_seek_usec)
	seek_count += 1


func update(t: float) -> void:
	if state != State.READY:
		return
	if not _player.is_playing():
		if loop or _length < 0.0:
			_player.play()
		else:
			return
	var target := media_time(t)
	var drift := absf(_player.stream_position - target)
	if _length > 0.0:
		drift = minf(drift, _length - drift)  # wrap-around near loop point
	if drift > drift_tolerance:
		seek(target)


func set_paused(p: bool) -> void:
	if _player:
		_player.paused = p


func get_class_name() -> String:
	return "TheoraVideoSource"


func describe() -> Dictionary:
	var d := super.describe()
	d["seeks"] = seek_count
	d["last_seek_ms"] = last_seek_usec / 1000.0
	return d
