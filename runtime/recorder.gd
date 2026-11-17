class_name Recorder
extends Node
## Timestamped frame capture of the final output.
##
## After each rendered frame (RenderingServer.frame_post_draw) the output
## texture is read back and handed to a worker thread for PNG encoding, so the
## control path never waits on disk. GPU readback itself is synchronous in the
## Compatibility renderer; its cost is measured (readback_usec) and can be
## reduced with `every` (capture every Nth frame) and `scale`.
##
## Files: <dir>/frame_<frame>.png plus <dir>/frames.jsonl with one record per
## frame: {"frame", "t", "file", "active", "wall_usec", "readback_usec"}.
## If the worker backlog exceeds max_pending the frame is dropped and counted.
##
## For deterministic offline rendering use Godot's Movie Maker instead
## (tools/render_movie.sh): replay clock + fixed fps + --write-movie.

var dir := "user://captures"
var every := 1
var scale := 1.0
var max_pending := 8
var source: Callable  # () -> Texture2D
var context: Callable  # () -> Dictionary extra fields per frame
var recording := false

var captured := 0
var dropped := 0
var readback_usec := 0
var max_readback_usec := 0

var _pending_t := -1.0
var _pending_frame := -1
var _tasks: Array[int] = []
var _index: FileAccess
var _mutex := Mutex.new()


func start(path := "") -> Error:
	if path != "":
		dir = path
	var abs_dir := ProjectSettings.globalize_path(dir)
	var err := DirAccess.make_dir_recursive_absolute(abs_dir)
	if err != OK:
		return err
	_index = FileAccess.open(dir.path_join("frames.jsonl"), FileAccess.WRITE)
	if _index == null:
		return FileAccess.get_open_error()
	recording = true
	if not RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.connect(_on_post_draw)
	return OK


func stop() -> void:
	recording = false
	if RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()
	if _index:
		_index.close()
		_index = null


## Notify which clock state the frame being rendered represents.
func on_frame(t: float, frame: int) -> void:
	_pending_t = t
	_pending_frame = frame


static func frame_file(frame: int) -> String:
	return "frame_%06d.png" % frame


func _on_post_draw() -> void:
	if not recording or _pending_frame < 0 or _pending_frame % every != 0:
		return
	_reap()
	var file := frame_file(_pending_frame)
	var rec := {"frame": _pending_frame, "t": _pending_t, "file": file, "wall_usec": Time.get_ticks_usec()}
	if context.is_valid():
		rec.merge(context.call())
	if _tasks.size() >= max_pending:
		dropped += 1
		rec["dropped"] = true
		_write_index(rec)
		return
	var tex: Texture2D = source.call()
	if tex == null:
		return
	var t0 := Time.get_ticks_usec()
	var img := tex.get_image()
	readback_usec = Time.get_ticks_usec() - t0
	max_readback_usec = maxi(max_readback_usec, readback_usec)
	rec["readback_usec"] = readback_usec
	_write_index(rec)
	var out := ProjectSettings.globalize_path(dir.path_join(file))
	_tasks.append(WorkerThreadPool.add_task(_save.bind(img, out, scale)))
	captured += 1
	_pending_frame = -1


static func _save(img: Image, path: String, s: float) -> void:
	if s != 1.0:
		img.resize(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)), Image.INTERPOLATE_BILINEAR)
	img.save_png(path)


func _write_index(rec: Dictionary) -> void:
	_mutex.lock()
	_index.store_line(JSON.stringify(rec))
	_mutex.unlock()


func _reap() -> void:
	var keep: Array[int] = []
	for t in _tasks:
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
		else:
			keep.append(t)
	_tasks = keep


func _exit_tree() -> void:
	stop()


func stats() -> Dictionary:
	return {
		"captured": captured,
		"dropped": dropped,
		"readback_ms": readback_usec / 1000.0,
		"max_readback_ms": max_readback_usec / 1000.0,
	}
