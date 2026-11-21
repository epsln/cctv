extends "res://tests/test_case.gd"
## Manifest v2, proxies, shared refcounts, face tracks, collections/selector,
## procedural and text sources.

const FIX := "res://tests/fixtures"
var am: AssetManager


func before_each() -> void:
	am = AssetManager.new()
	add_child(am)
	eq(am.load_manifest(FIX + "/library_v2.json"), OK)


func after_each() -> void:
	am.queue_free()


func selector() -> AssetSelector:
	var s := AssetSelector.new(am)
	eq(s.load_collections(FIX + "/collections.json"), OK)
	return s


func test_manifest_v2_fields() -> void:
	eq(am.manifest_version, 2)
	eq(am.library_version, "testlib0001")
	var e: Dictionary = am.assets["cctv/cam0"]
	eq(e["proxies"][0]["path"], FIX + "/clip.ogv", "relative proxy paths resolved")
	eq(e["thumbnail"], FIX + "/still.png")
	eq(am.resolved("cctv/cam0"), {"id": "cctv/cam0", "content_hash": "sha256:c0", "analyses": e["analyses"]})
	check(am.has_tag("talking_heads/anchor", "has_faces"))


func test_rejects_invalid_manifest() -> void:
	var p := "user://bad_manifest.json"
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 2, "assets": [{"id": "x", "type": "hologram"}]}))
	f.close()
	var m := AssetManager.new()
	add_child(m)
	eq(m.load_manifest(p), ERR_INVALID_DATA)
	m.free()


func test_proxy_selection() -> void:
	am.register(
		{
			"id": "multi",
			"type": "video",
			"path": "c.ogv",
			"proxies": [{"height": 1080, "path": "c1080.ogv"}, {"height": 540, "path": "c540.ogv"}]
		}
	)
	eq(am.proxy_path("multi", 300), "c540.ogv", "smallest covering proxy")
	eq(am.proxy_path("multi", 540), "c540.ogv")
	eq(am.proxy_path("multi", 541), "c1080.ogv")
	eq(am.proxy_path("multi", 4000), "c1080.ogv", "largest when none covers")
	eq(am.proxy_path("multi", 0), "c1080.ogv")
	eq(am.proxy_path("cctv/cam1", 10), FIX + "/clip.ogv")


func test_shared_refcount_frees_on_last_release() -> void:
	var a := am.shared("cctv/cam0")
	var b := am.shared("cctv/cam0")
	check(a == b)
	eq(am.shared_refcount(a), 2)
	am.release(a)
	check(is_instance_valid(a) and not a.is_queued_for_deletion(), "still referenced")
	am.release(b)
	check(a.is_queued_for_deletion(), "freed after last release")
	var c := am.shared("cctv/cam0")
	check(c != a, "fresh instance afterwards")
	am.release(c)


func test_face_tracks_loaded_and_interpolated() -> void:
	var s := am.instance("talking_heads/anchor")
	var tracks: Array = s.metadata.get("face_tracks", [])
	eq(tracks.size(), 2)
	var at := AnnotationLayer.tracks_at(tracks, 0.5)
	eq(at.size(), 1)
	eq(at[0]["id"], 1)
	near(float(at[0]["box"][0]), 0.2, 1e-5, "interpolated x")
	near(float(at[0]["conf"]), 0.8, 1e-5)
	eq(AnnotationLayer.tracks_at(tracks, 1.1).size(), 1, "held briefly after last sample")
	eq(AnnotationLayer.tracks_at(tracks, 1.5).size(), 0, "gone after the hold")
	eq(AnnotationLayer.tracks_at(tracks, 2.2).size(), 1)
	eq(AnnotationLayer.tracks_at(tracks, 2.2, 0.7).size(), 0, "min confidence")
	eq(AnnotationLayer.boxes_at(s.metadata, 0.0), [[0.1, 0.1, 0.2, 0.2]])
	am.release(s)


func test_pdf_page_raster_is_image() -> void:
	var s := am.instance("documents/dossier/p2")
	check(s is ImageSource and not s is PdfPageSource, "pre-rasterized page")
	eq(s.state, VisualSource.State.READY)
	eq(s.metadata["page"], 2)
	am.release(s)


func test_procedural_source() -> void:
	var s := am.instance("gen/osc")
	check(s is ProceduralSource)
	eq(s.state, VisualSource.State.READY, s.error)
	eq(s.get_size(), Vector2i(64, 36))
	am.release(s)
	am.register({"id": "bad", "type": "procedural", "generator": "lissajous", "params": {"nope": 1}})
	var b := am.instance("bad")
	eq(b.state, VisualSource.State.FAILED)
	am.release(b)


func test_text_presets() -> void:
	for st in TextSource.PRESETS:
		am.register({"id": "t_" + st, "type": "text", "text": "abc", "style": st})
		var s: TextSource = am.instance("t_" + st)
		eq(s.style, st)
		eq(s.get_size(), Vector2i(TextSource.PRESETS[st]["box"][0], TextSource.PRESETS[st]["box"][1]))
		am.release(s)
	am.register({"id": "t_stamp2", "type": "text", "text": "void", "style": "stamp"})
	var u: TextSource = am.instance("t_stamp2")
	eq(u.text, "VOID", "stamp is upper-case")
	am.release(u)


func test_collections_members() -> void:
	var s := selector()
	eq(s.members("cctv").size(), 6)
	eq(s.members("bureaucratic_documents"), ["documents/dossier/p1", "documents/dossier/p2", "documents/dossier/p3"])
	eq(s.members("redacted_pages"), ["documents/dossier/p4"])
	eq(s.members("math"), ["gen/osc"], "undefined name falls back to a tag")
	eq(s.members("nothing"), [])
	check("cctv" in s.names() and "math" in s.names())


func test_selector_deterministic_and_logged() -> void:
	var r1 := RandomNumberGenerator.new()
	r1.seed = 42
	var r2 := RandomNumberGenerator.new()
	r2.seed = 42
	var a := selector().select("cctv", 3, r1)
	var b := selector().select("cctv", 3, r2)
	eq(a, b, "same seed, same picks")
	eq(a.size(), 3)
	var s := selector()
	var r := RandomNumberGenerator.new()
	r.seed = 42
	s.select("cctv", 2, r)
	var e: Dictionary = s.log[-1]
	eq(e["collection"], "cctv")
	eq(e["seed"], 42)
	eq(e["ids"].size(), 2)
	eq(e["assets"][0]["content_hash"].left(8), "sha256:c")


func test_selector_repetition_window() -> void:
	var s := selector()
	s.repeat_window = 5
	var r := RandomNumberGenerator.new()
	r.seed = 1
	var seen := []
	for i in 6:
		var id := s.pick_one("cctv", r)
		check(id not in seen.slice(maxi(0, seen.size() - 5)), "no repeat within the window: %s" % id)
		seen.append(id)
	eq(seen.size(), 6)
	# With a window of 1, the collection still never repeats back-to-back.
	s.repeat_window = 1
	var last := ""
	for i in 20:
		var id := s.pick_one("cctv", r)
		check(id != last)
		last = id


func test_selector_constraints() -> void:
	var s := selector()
	var r := RandomNumberGenerator.new()
	r.seed = 3
	var picks := s.select("cctv", 6, r, {"max_videos": 2})
	eq(picks.size(), 2, "only videos in cctv: capped at 2")
	var ex := s.select("tv_news", 3, r, {"exclude": ["tv_news/ch0"]})
	eq(ex.size(), 2)
	check("tv_news/ch0" not in ex)
	eq(s.select("nothing", 1, r), [])
	eq(s.log[-1].get("error"), "empty")
