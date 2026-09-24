extends SceneTree

const SOURCE_PATH := "res://assets/ui/workshop.svg"
const APP_DIRECTORY := "res://assets/app"
const NATIVE_SIZES := [16, 24, 32, 48, 64, 128, 256, 512, 1024]
const ICONSET_FILES := {
	"icon_16x16.png": 16,
	"icon_16x16@2x.png": 32,
	"icon_32x32.png": 32,
	"icon_32x32@2x.png": 64,
	"icon_128x128.png": 128,
	"icon_128x128@2x.png": 256,
	"icon_256x256.png": 256,
	"icon_256x256@2x.png": 512,
	"icon_512x512.png": 512,
	"icon_512x512@2x.png": 1024,
}


# 从既有矢量原稿直接生成每种原生尺寸，不经小尺寸位图放大。
func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 1 or not arguments[0].is_absolute_path():
		_fail("用法：Godot --headless --path 项目 --script res://tools/build_app_icons.gd -- 中间文件绝对目录")
		return
	var staging_directory: String = arguments[0]
	var iconset_directory := staging_directory.path_join("app_icon.iconset")
	for directory: String in [APP_DIRECTORY, staging_directory, iconset_directory]:
		var error := DirAccess.make_dir_recursive_absolute(directory)
		if error != OK:
			_fail("不能创建图标目录：%s（%s）" % [directory, error_string(error)])
			return
	var source := FileAccess.get_file_as_bytes(SOURCE_PATH)
	if source.is_empty():
		_fail("不能读取游戏矢量图标：%s" % SOURCE_PATH)
		return
	var source_image := Image.new()
	if source_image.load_svg_from_buffer(source) != OK or source_image.get_width() != source_image.get_height():
		_fail("应用图标源稿必须是可读取的正方形 SVG。")
		return
	var source_size := float(source_image.get_width())
	for native_size: int in NATIVE_SIZES:
		var raster := Image.new()
		var error := raster.load_svg_from_buffer(source, native_size / source_size)
		if error != OK or raster.get_size() != Vector2i(native_size, native_size):
			_fail("原生尺寸 %d 栅格化失败。" % native_size)
			return
		if not raster.detect_alpha() or raster.get_pixel(0, 0).a != 0.0:
			_fail("原生尺寸 %d 未保留透明圆角。" % native_size)
			return
		if raster.save_png(staging_directory.path_join("icon_%d.png" % native_size)) != OK:
			_fail("原生尺寸 %d PNG 保存失败。" % native_size)
			return
		for iconset_file: String in ICONSET_FILES:
			if ICONSET_FILES[iconset_file] == native_size:
				if raster.save_png(iconset_directory.path_join(iconset_file)) != OK:
					_fail("图标集文件保存失败：%s" % iconset_file)
					return
		if native_size == 1024 and raster.save_png(APP_DIRECTORY.path_join("app_icon.png")) != OK:
			_fail("应用 PNG 保存失败。")
			return
	var destination := FileAccess.open(APP_DIRECTORY.path_join("app_icon.svg"), FileAccess.WRITE)
	if destination == null:
		_fail("独立应用 SVG 保存失败。")
		return
	destination.store_buffer(source)
	destination.close()
	print("应用图标原生栅格化完成：%s；透明角校验通过。" % staging_directory)
	quit(0)


# 统一报告资源生成失败，供构建脚本识别非零退出码。
func _fail(message: String) -> void:
	push_error(message)
	quit(1)
