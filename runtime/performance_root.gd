class_name PerformanceRoot
extends Node
## Top-level runtime: clock -> compositions (A/B) -> transition -> feedback ->
## global effects -> projector/operator/recorder.
##
## Command-line (after `--`):
##   --show=PATH            show file (default res://shows/demo.json)
##   --replay               externally advanced clock: +1/fps per rendered frame
##   --fps=N                target/replay frame rate (default from show, 60)
##   --projector-screen=N   fullscreen projector on screen N
##   --no-projector         do not open the projector window
##   --no-operator          main window shows the bare output (Movie Maker/benchmark)
##   --capture=DIR          record timestamped PNG frames + frames.jsonl
##   --capture-every=N      capture every Nth frame (default 1)
##   --capture-scale=F      downscale captured frames (default 1.0)

signal frame_done(t: float, frame: int)
signal composition_changed(comp_id: String)

const DEFAULT_SHOW := "res://shows/demo.json"

var args := {}
var show := {}
var show_path := ""
var output_size := Vector2i(1920, 1080)
var fps := 60.0
var errors: PackedStringArray = []

var clock: MusicalClock
var assets: AssetManager
var compositor: TransitionCompositor
var feedback: FeedbackPass
var global_fx: EffectChain
var metrics: FrameMetrics
var projector: Window
var operator: Control
var recorder: Recorder
var main_out: TextureRect
var _last_usec := 0


static func parse_args(list: PackedStringArray) -> Dictionary:
	var out := {}
	for a in list:
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else true
	return out


func _ready() -> void:
	if args.is_empty():
		args = parse_args(OS.get_cmdline_user_args())
	setup(args.get("show", DEFAULT_SHOW))
	if not args.has("no-projector"):
		_open_projector(int(args.get("projector-screen", -1)))
	if not args.has("no-operator"):
		operator = load("res://runtime/operator_view.gd").new()
		operator.performance = self
		add_child(operator)
	else:
		main_out = TextureRect.new()
		main_out.name = "MainOutput"
		main_out.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		main_out.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		main_out.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(main_out)
	if args.has("capture"):
		start_capture(str(args["capture"]), int(args.get("capture-every", 1)), float(args.get("capture-scale", 1.0)))


func start_capture(dir: String, every := 1, scale := 1.0) -> Error:
	if recorder == null:
		recorder = Recorder.new()
		recorder.name = "Recorder"
		recorder.source = output_texture
		recorder.context = func(): return {"active": compositor.active_id(), "progress": compositor.progress}
		add_child(recorder)
		frame_done.connect(recorder.on_frame)
	recorder.every = maxi(every, 1)
	recorder.scale = scale
	var err := recorder.start(dir)
	if err != OK:
		errors.append("cannot start capture in %s (%d)" % [dir, err])
	return err


func setup(path: String) -> Error:
	show_path = path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		errors.append("cannot open show " + path)
		show = {"compositions": {}}
	else:
		var parsed = JSON.parse_string(f.get_as_text())
		show = parsed if parsed is Dictionary else {"compositions": {}}
	var base := path.get_base_dir()
	var sz: Array = show.get("output", [1920, 1080])
	output_size = Vector2i(sz[0], sz[1])
	fps = float(args.get("fps", show.get("fps", 60)))
	Engine.max_fps = 0
	metrics = FrameMetrics.new(fps)

	clock = MusicalClock.new()
	clock.name = "MusicalClock"
	clock.process_priority = -100
	clock.bpm = float(show.get("bpm", 124))
	clock.mode = MusicalClock.Mode.REPLAY if args.has("replay") else MusicalClock.Mode.LIVE
	add_child(clock)

	assets = AssetManager.new()
	assets.name = "AssetManager"
	add_child(assets)
	if show.has("manifest"):
		var mp: String = show["manifest"]
		if mp.is_relative_path():
			mp = base.path_join(mp)
		if assets.load_manifest(mp) != OK:
			errors.append("cannot load manifest " + mp)

	compositor = TransitionCompositor.new()
	compositor.name = "TransitionCompositor"
	compositor.set_size_px(output_size)
	add_child(compositor)
	compositor.transition_finished.connect(func(id): composition_changed.emit(id))

	feedback = FeedbackPass.new()
	feedback.name = "Feedback"
	add_child(feedback)
	feedback.setup(compositor.get_texture(), output_size)
	var fbc: Dictionary = show.get("feedback", {})
	feedback.enabled = bool(fbc.get("enabled", false))
	var fbp := fbc.duplicate()
	fbp.erase("enabled")
	feedback.set_params(fbp)
	feedback.bind_clock(clock)

	global_fx = EffectChain.new()
	global_fx.name = "GlobalEffects"
	add_child(global_fx)
	if global_fx.configure(show.get("global_effects", []), feedback.get_output(), output_size) != OK:
		errors.append("invalid global effects")
		global_fx.configure([], feedback.get_output(), output_size)

	var first: String = show.get("initial", "")
	if first == "" and not show.get("compositions", {}).is_empty():
		first = show["compositions"].keys()[0]
	if first != "":
		trigger(first, "cut", 0.0, false)
	return OK if errors.is_empty() else ERR_INVALID_DATA


func composition_ids() -> Array:
	return show.get("compositions", {}).keys()


## Prepare a composition and transition to it. Preparation is transactional:
## an invalid composition is discarded and the current one keeps playing.
## quantize=true starts the transition on the next beat onset.
func trigger(comp_id: String, kind := "crossfade", beats := 2.0, quantize := true) -> Error:
	var spec: Dictionary = show.get("compositions", {}).get(comp_id, {})
	if spec.is_empty():
		errors.append("unknown composition " + comp_id)
		return ERR_DOES_NOT_EXIST
	spec = spec.duplicate(true)
	spec["id"] = comp_id
	var c := Composition.new()
	if c.build(spec, assets, output_size) != OK:
		errors.append_array(c.errors)
		c.release()
		return ERR_INVALID_DATA
	var t0 := clock.next_beat_time() if quantize else clock.time
	return compositor.start(c, kind, t0, beats * clock.beat_length())


func output_texture() -> Texture2D:
	return global_fx.get_output()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		metrics.record(now - _last_usec)
	_last_usec = now
	if clock.mode == MusicalClock.Mode.REPLAY:
		clock.advance(1.0 / fps)
	step()


## Evaluate one frame at the current clock time.
func step() -> void:
	var t := clock.time
	var u := clock.uniforms()
	compositor.update(t, u)
	feedback.set_input(compositor.get_texture())
	feedback.update(u)
	global_fx.set_input(feedback.get_output())
	global_fx.update(u)
	if projector:
		projector.get_node("out").texture = output_texture()
	if main_out:
		main_out.texture = output_texture()
	frame_done.emit(t, clock.frame)


func _open_projector(screen: int) -> void:
	projector = Window.new()
	projector.title = "CCTV projector"
	projector.size = Vector2i(960, 540)
	var r := TextureRect.new()
	r.name = "out"
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	projector.add_child(r)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.show_behind_parent = true
	projector.add_child(bg)
	projector.move_child(bg, 0)
	add_child(projector)
	if screen >= 0 and screen < DisplayServer.get_screen_count():
		projector.current_screen = screen
		projector.borderless = true
		projector.mode = Window.MODE_FULLSCREEN
	projector.close_requested.connect(func(): projector.hide())


func status() -> Dictionary:
	return {
		"time": clock.time,
		"frame": clock.frame,
		"beat": clock.beat_index(),
		"beat_phase": clock.beat_phase(),
		"mode": MusicalClock.Mode.keys()[clock.mode],
		"transition": compositor.describe(),
		"feedback": feedback.enabled,
		"metrics": metrics.summary(),
		"sources": assets.describe(),
		"capture": recorder.stats() if recorder else {},
		"errors": errors,
	}
