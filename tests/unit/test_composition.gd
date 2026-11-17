extends "res://tests/test_case.gd"

const FIX := "res://tests/fixtures"
var am: AssetManager


func before_each() -> void:
	am = AssetManager.new()
	add_child(am)
	am.load_manifest(FIX + "/manifest.json")
	var red := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	red.fill(Color.RED)
	red.save_png("user://red.png")
	am.register(
		{
			"id": "red",
			"type": "image",
			"path": "user://red.png",
			"metadata": {"face_track": [{"t": 0.0, "boxes": [[0.5, 0.5, 0.25, 0.25]]}]}
		}
	)


func spec() -> Dictionary:
	return {
		"id": "test",
		"background": [0.0, 0.0, 1.0, 1.0],
		"layers":
		[
			{"kind": "layer", "id": "bg", "asset": "red", "rect": [0.0, 0.0, 0.5, 1.0]},
			{
				"kind": "group",
				"id": "panels",
				"rect": [0.5, 0.0, 0.5, 0.5],
				"clip": true,
				"effects": [{"type": "color_grade", "params": {"saturation": 0.0}}],
				"children":
				[
					{
						"kind": "layer",
						"id": "cam",
						"asset": "clip",
						"instance": "independent",
						"start": 0.5,
						"effects": [{"type": "glitch"}],
						"blend": "add"
					},
					{
						"kind": "layer",
						"id": "doc",
						"asset": "still",
						"opacity": 0.5,
						"bindings": [{"prop": "opacity", "signal": "uBeatEnvelope", "amount": 0.5}]
					},
				]
			},
			{"kind": "annotation", "id": "faces", "target": "bg", "style": "box", "label": "SUBJECT"},
			{"kind": "annotation", "id": "redact", "style": "redact", "boxes": [[0.1, 0.1, 0.2, 0.05]]},
		],
	}


func make(d: Dictionary, sz := Vector2i(64, 32)) -> Composition:
	var c := Composition.new()
	add_child(c)
	c.build(d, am, sz)
	return c


func test_builds_tree_in_order() -> void:
	var c := make(spec())
	eq(c.errors.size(), 0, str(c.errors))
	eq(c.root.get_children().map(func(n): return n.layer_id), ["bg", "panels", "faces", "redact"])
	eq((c.find("panels") as LayerGroup).items().map(func(n): return n.layer_id), ["cam", "doc"])


func test_roundtrip_is_stable() -> void:
	var a := make(spec()).to_dict()
	var b := make(a).to_dict()
	eq(JSON.stringify(a), JSON.stringify(b))
	eq(a["layers"][1]["children"][0]["instance"], "independent")
	eq(a["layers"][1]["children"][0]["blend"], "add")


func test_layout_is_normalized() -> void:
	var c := make(spec())
	eq(c.find("bg").size, Vector2(32, 32))
	eq(c.find("panels").position, Vector2(32, 0))
	eq(c.find("cam").size, Vector2(32, 16), "child relative to group")


func test_offscreen_only_when_group_has_effects() -> void:
	var c := make(spec())
	check((c.find("panels") as LayerGroup).is_offscreen())
	var d := spec()
	d["layers"][1].erase("effects")
	check(not (make(d).find("panels") as LayerGroup).is_offscreen())


func test_independent_instance_and_activation() -> void:
	var c := make(spec())
	var cam: Layer = c.find("cam")
	check(cam.owns_source)
	c.activate(10.0)
	near(cam.source.start_time, 9.5)
	check(am.shared("clip") != cam.source, "not the shared instance")


func test_opacity_binding() -> void:
	var c := make(spec())
	c.update(0.0, {"uBeatEnvelope": 1.0})
	near(c.find("doc").modulate.a, 1.0)
	c.update(0.0, {"uBeatEnvelope": 0.0})
	near(c.find("doc").modulate.a, 0.5)


func test_annotation_follows_target_metadata_and_crop() -> void:
	var d := spec()
	d["layers"][0]["crop"] = [0.5, 0.5, 0.5, 0.5]
	var c := make(d)
	c.update(0.0, {})
	var boxes: Array = c.find("faces").current_boxes()
	eq(boxes.size(), 1)
	eq(boxes[0], Rect2(0, 0, 0.5, 0.5))


func test_face_track_sampling() -> void:
	var meta := {"face_track": [{"t": 0.0, "boxes": [[0, 0, 1, 1]]}, {"t": 2.0, "boxes": []}]}
	eq(AnnotationLayer.boxes_at(meta, 1.0).size(), 1)
	eq(AnnotationLayer.boxes_at(meta, 2.5).size(), 0)


func test_invalid_specs_rejected() -> void:
	var bad := [
		{"id": "x", "layers": [{"kind": "layer", "id": "a", "asset": "nope"}]},
		{"id": "x", "layers": [{"kind": "layer", "id": "a", "asset": "red", "blend": "screen"}]},
		{
			"id": "x",
			"layers": [{"kind": "layer", "id": "a", "asset": "red"}, {"kind": "layer", "id": "a", "asset": "red"}]
		},
		{"id": "x", "layers": [{"kind": "annotation", "id": "a", "target": "missing"}]},
		{"id": "x", "layers": [{"kind": "sprite", "id": "a"}]},
	]
	for d in bad:
		var c := Composition.new()
		add_child(c)
		eq(c.build(d, am, Vector2i(8, 8)), ERR_INVALID_DATA, JSON.stringify(d))
		c.release()


func test_renders_layers() -> void:
	if not gpu():
		return
	var d := {
		"id": "px",
		"background": [0, 0, 1, 1],
		"layers": [{"kind": "layer", "id": "bg", "asset": "red", "rect": [0, 0, 0.5, 1]}]
	}
	var c := make(d)
	c.update(0.0, {})
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := c.get_texture().get_image()
	check(img.get_pixel(8, 16).is_equal_approx(Color.RED), "left red: %s" % img.get_pixel(8, 16))
	check(img.get_pixel(56, 16).is_equal_approx(Color.BLUE), "right bg: %s" % img.get_pixel(56, 16))


func test_offscreen_group_renders_effect() -> void:
	if not gpu():
		return
	var d := {
		"id": "g",
		"layers":
		[
			{
				"kind": "group",
				"id": "g",
				"rect": [0, 0, 1, 1],
				"effects": [{"type": "color_grade", "params": {"saturation": 0.0}}],
				"children": [{"kind": "layer", "id": "r", "asset": "red"}]
			}
		]
	}
	var c := make(d)
	for i in 3:
		c.update(0.0, {})
		await RenderingServer.frame_post_draw
	var p := c.get_texture().get_image().get_pixel(32, 16)
	near(p.r, p.g, 0.03, "grey through group effect: %s" % p)
	check(p.r > 0.1, "not empty")
