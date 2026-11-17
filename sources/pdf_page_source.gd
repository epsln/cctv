class_name PdfPageSource
extends ImageSource
## One rasterized PDF page. Pages are rasterized by tools/rasterize_pdf.sh
## (preferred, offline) into <cache_dir>/<stem>-<page>.png. If the PNG is
## missing, prepare() rasterizes it on a worker thread with pdftoppm, so the
## render thread never blocks on document work.

var pdf_path := ""
var page := 1
var dpi := 150
var cache_dir := "user://pdf_cache"
var _task := -1


func _init(pdf := "", p := 1, cache := "user://pdf_cache") -> void:
	pdf_path = pdf
	page = p
	cache_dir = cache
	path = page_png_path(pdf, p, cache)
	metadata = {"pdf": pdf, "page": p}


static func page_png_path(pdf: String, p: int, cache: String) -> String:
	return "%s/%s-%d.png" % [cache, pdf.get_file().get_basename(), p]


func prepare() -> void:
	if FileAccess.file_exists(path):
		super.prepare()
		return
	_set_state(State.PREPARING)
	_task = WorkerThreadPool.add_task(_rasterize)


func _rasterize() -> void:
	var cache_abs := ProjectSettings.globalize_path(cache_dir)
	DirAccess.make_dir_recursive_absolute(cache_abs)
	var out_base := cache_abs + "/" + pdf_path.get_file().get_basename() + "-" + str(page)
	var args := [
		"-png",
		"-r",
		str(dpi),
		"-f",
		str(page),
		"-l",
		str(page),
		"-singlefile",
		ProjectSettings.globalize_path(pdf_path),
		out_base,
	]
	var code := OS.execute("pdftoppm", args)
	_finish.call_deferred(code)


func _finish(code: int) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if code != 0:
		_set_state(State.FAILED, "pdftoppm failed (%d) for %s" % [code, pdf_path])
		return
	super.prepare()


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)


func get_class_name() -> String:
	return "PdfPageSource"
