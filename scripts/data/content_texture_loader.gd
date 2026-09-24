class_name ContentTextureLoader
extends RefCounted
## 注册表与地图画布共用图片读取规则，兼容原始用户图片和导出包资源。


## 校验路径并返回可用贴图；原图优先读取以立即反映内容包的图片修改。
static func load_texture(path: String) -> DataResult:
	if not DataValidation.is_resource_path(path):
		return DataResult.failure("texture 必须为安全的 res:// 或 user:// 资源路径")
	if not path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp", "svg"]:
		return DataResult.failure("texture 仅支持 png、jpg、jpeg、webp、svg 图片")
	if FileAccess.file_exists(path):
		return _decode_raw(path)
	if ResourceLoader.exists(path, "Texture2D"):
		var imported := ResourceLoader.load(path, "Texture2D")
		if imported is Texture2D:
			return DataResult.success(imported)
	return DataResult.failure("贴图不存在或不可读取：%s" % path)


## 从原始字节按格式解码，避免依赖 user:// 图片不存在的导入缓存。
static func _decode_raw(path: String) -> DataResult:
	var decoded := Image.new()
	var bytes := FileAccess.get_file_as_bytes(path)
	var decode_error := ERR_FILE_UNRECOGNIZED
	match path.get_extension().to_lower():
		"png":
			decode_error = decoded.load_png_from_buffer(bytes)
		"jpg", "jpeg":
			decode_error = decoded.load_jpg_from_buffer(bytes)
		"webp":
			decode_error = decoded.load_webp_from_buffer(bytes)
		"svg":
			decode_error = decoded.load_svg_from_buffer(bytes)
	if decode_error != OK or decoded.is_empty():
		return DataResult.failure("无法解码贴图：%s" % path)
	return DataResult.success(ImageTexture.create_from_image(decoded))
