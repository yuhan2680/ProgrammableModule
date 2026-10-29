class_name GuideMarkdown
extends RefCounted
## 自定义引导与编辑器预览共用的小型 Markdown 排版器；用户文本绝不交给 BBCode 或资源解析器。

const BODY_SIZE := 16
const HEADING_SIZES := [25, 21, 18]
static var _bold_font: Font
static var _italic_font: Font
static var _bold_italic_font: Font
static var _web_url_pattern: RegEx
const MAX_INLINE_DEPTH := 8


## 以受控字体栈排版纯文本和网页链接；图片与外部资源不会被加载。
static func render(label: RichTextLabel, text: String) -> void:
	label.set_meta("ui_scaled_markdown_source", text)
	label.set_meta("ui_scaled_markdown_factor", GameTheme.font_scale(label))
	label.bbcode_enabled = false
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.add_theme_font_override("normal_font", GameTheme.body_font())
	label.add_theme_font_override("bold_font", _heading_font())
	label.add_theme_font_override("italics_font", _slanted_font(false))
	label.add_theme_font_override("bold_italics_font", _slanted_font(true))
	label.add_theme_font_override("mono_font", GameTheme.code_font())
	GameTheme.font_size(label, "normal_font_size", BODY_SIZE)
	label.add_theme_color_override("default_color", GameTheme.TEXT)
	label.clear()
	var lines := text.replace("\r\n", "\n").replace("\r", "\n").split("\n", true)
	for index in range(lines.size()):
		var line: String = lines[index]
		var heading := _heading_level(line)
		if heading > 0:
			label.push_font(_heading_font())
			label.push_font_size(roundi(HEADING_SIZES[heading - 1] * GameTheme.font_scale(label)))
			_append_inline(label, line.substr(heading + 1), true)
			label.pop()
			label.pop()
		else:
			if line.begins_with("- [ ] ") or line.begins_with("* [ ] "):
				label.add_text("☐ ")
				line = line.substr(6)
			elif line.begins_with("- [x] ") or line.begins_with("- [X] ") or line.begins_with("* [x] ") or line.begins_with("* [X] "):
				label.add_text("☑ ")
				line = line.substr(6)
			elif line.begins_with("- ") or line.begins_with("* "):
				label.add_text("• ")
				line = line.substr(2)
			_append_inline(label, line)
		if index < lines.size() - 1:
			label.add_text("\n")


## 仅行首一至三个井号加空格才是标题，代码中的井号及未完成语法保持原文。
static func _heading_level(line: String) -> int:
	for level in range(3, 0, -1):
		if line.begins_with("#".repeat(level) + " "):
			return level
	return 0


## 成对粗斜体允许组合嵌套，代码内不再解析；所有正文仍只通过 add_text 写入。
static func _append_inline(label: RichTextLabel, text: String, bold: bool = false, italic: bool = false, depth: int = 0) -> void:
	if depth >= MAX_INLINE_DEPTH:
		_add_portable_text(label, text)
		return
	var offset := 0
	while offset < text.length():
		var character := text.substr(offset, 1)
		if character == "\\" and offset + 1 < text.length() and text.substr(offset + 1, 1) in ["*", "_", "+", "~", "`", "\\", "[", "]", "(", ")"]:
			_add_portable_text(label, text.substr(offset + 1, 1))
			offset += 2
			continue
		if character == "`":
			var closing := text.find("`", offset + 1)
			if closing <= offset + 1:
				_add_portable_text(label, text.substr(offset))
				return
			label.push_font(GameTheme.code_font())
			_add_portable_text(label, text.substr(offset + 1, closing - offset - 1))
			label.pop()
			offset = closing + 1
			continue
		if character == "[" and (offset == 0 or text.substr(offset - 1, 1) != "!"):
			var link := _inline_link(text, offset)
			if not link.is_empty():
				label.push_meta(link.url)
				label.push_color(GameTheme.ACCENT)
				_append_inline(label, link.caption, bold, italic, depth + 1)
				label.pop()
				label.pop()
				offset = link.end
				continue
		if character in ["+", "~"] and text.substr(offset, 2) == character.repeat(2):
			var closing := _find_decoration_end(text, offset, character.repeat(2))
			if closing > offset + 2:
				if character == "+":
					label.push_underline()
				else:
					label.push_strikethrough()
				_append_inline(label, text.substr(offset + 2, closing - offset - 2), bold, italic, depth + 1)
				label.pop()
				offset = closing + 2
				continue
		if character in ["*", "_"]:
			var width := _marker_width(text, offset)
			if width <= 3 and _can_open(text, offset, width):
				var closing := _find_emphasis_end(text, offset, width)
				# 三星也能分两次结束：先关闭内部粗体或斜体，再关闭外部强调。
				if closing < 0 and width == 3:
					for split_width in [1, 2]:
						closing = _find_emphasis_end(text, offset, split_width)
						if closing >= 0:
							width = split_width
							break
				if closing < 0:
					# 书写中的未闭合标记保留原文，不吞掉后面的文字。
					_add_portable_text(label, text.substr(offset))
					return
				var inner_bold := bold or width >= 2
				var inner_italic := italic or width != 2
				label.push_font(_slanted_font(inner_bold) if inner_italic else _heading_font())
				_append_inline(label, text.substr(offset + width, closing - offset - width), inner_bold, inner_italic, depth + 1)
				label.pop()
				offset = closing + width
				continue
			_add_portable_text(label, text.substr(offset, width))
			offset += width
			continue
		var start := offset
		offset += 1
		while offset < text.length() and text.substr(offset, 1) not in ["*", "_", "+", "~", "`", "\\", "["]:
			offset += 1
		_add_portable_text(label, text.substr(start, offset - start))


## 下划线与删除线只识别成对的纯文本标记，跳过转义、行内代码与链接目标。
static func _find_decoration_end(text: String, start: int, marker: String) -> int:
	var offset := start + marker.length()
	while offset < text.length():
		if text.substr(offset, 1) == "\\":
			offset += 2
			continue
		if text.substr(offset, 1) == "`":
			var closing := text.find("`", offset + 1)
			if closing >= 0:
				offset = closing + 1
				continue
		if text.substr(offset, 1) == "[":
			var link := _inline_link(text, offset)
			if not link.is_empty():
				offset = link.end
				continue
		if text.substr(offset, marker.length()) == marker:
			return offset
		offset += 1
	return -1


## 显示旧引导时隐藏平台私用字形，但链接仍按未改写的原网址校验，避免改变跳转目标。
static func _add_portable_text(label: RichTextLabel, text: String) -> void:
	label.add_text(DataValidation.filter_guide_text(text))


## 同类标记用小栈匹配，支持粗体内斜体及共享的三星结尾，跳过代码和转义字符。
static func _find_emphasis_end(text: String, start: int, width: int) -> int:
	var character := text.substr(start, 1)
	var markers: Array[int] = [width]
	var offset := start + width
	while offset < text.length():
		if text.substr(offset, 1) == "\\":
			offset += 2
			continue
		if text.substr(offset, 1) == "`":
			var code_end := text.find("`", offset + 1)
			if code_end >= 0:
				offset = code_end + 1
				continue
		# 链接目标中的星号或下划线属于网址，不能参与外层粗斜体配对。
		if text.substr(offset, 1) == "[":
			var link := _inline_link(text, offset)
			if not link.is_empty():
				offset = link.end
				continue
		if text.substr(offset, 1) != character:
			offset += 1
			continue
		var length := _marker_width(text, offset)
		var remaining := length
		var consumed := 0
		if length <= 3 and _can_close(text, offset, length):
			while remaining > 0 and (remaining == markers.back() or remaining == 3 or (consumed > 0 and remaining >= markers.back())):
				var matched: int = markers.pop_back()
				if markers.is_empty():
					return offset + consumed
				consumed += matched
				remaining -= matched
		if length <= 3 and remaining > 0 and _can_open(text, offset, length):
			markers.append(remaining)
		offset += length
	return -1


## 单星为斜体、双星为粗体、三星为粗斜体；更长未支持的标记整体作为原文。
static func _marker_width(text: String, offset: int) -> int:
	var width := 1
	while offset + width < text.length() and text.substr(offset + width, 1) == text.substr(offset, 1):
		width += 1
	return width


## 开始标记不能紧接空白，词语内部的下划线保持模块名等普通文本。
static func _can_open(text: String, offset: int, width: int) -> bool:
	if offset + width >= text.length() or text.substr(offset + width, 1).strip_edges().is_empty():
		return false
	return not _intraword_underscore(text, offset, width)


## 结束标记前必须有非空白字符，词内下划线不能意外结束强调范围。
static func _can_close(text: String, offset: int, width: int) -> bool:
	if offset <= 0 or text.substr(offset - 1, 1).strip_edges().is_empty():
		return false
	return not _intraword_underscore(text, offset, width)


## 只限制下划线两侧都属于单词的情况，中文紧邻星号的斜体仍可正常使用。
static func _intraword_underscore(text: String, offset: int, width: int) -> bool:
	return text.substr(offset, 1) == "_" and offset > 0 and offset + width < text.length() and _word_character(text.substr(offset - 1, 1)) and _word_character(text.substr(offset + width, 1))


## 字母、汉字、数字及下划线组成单词，不依赖 ASCII 假设来截断玩家模块名。
static func _word_character(character: String) -> bool:
	return character == "_" or character.is_valid_identifier() or character.is_valid_int()


## 链接只接受完整 HTTP/HTTPS 网址；协议、控制字符与本地资源不会交给系统处理。
static func is_web_url(url: String) -> bool:
	if url.length() > DataValidation.MAX_TEXT_LENGTH:
		return false
	for index in range(url.length()):
		var code := url.unicode_at(index)
		if code <= 32 or (code >= 127 and code <= 159) or DataValidation.is_private_use_character(code):
			return false
	if _web_url_pattern == null:
		_web_url_pattern = RegEx.new()
		_web_url_pattern.compile("(?i)^https?://(?:\\[[0-9a-f:.]+\\]|[\\p{L}\\p{M}\\p{N}._~%-]+)(?::[0-9]{1,5})?(?:[/?#][^\\s\\\\<>\"']*)?$")
	return _web_url_pattern.search(url) != null


## 读取一对标签与网址，支持网址里的配对括号；图片、未闭合和不支持的网址保留原文。
static func _inline_link(text: String, offset: int) -> Dictionary:
	var caption_end := _balanced_end(text, offset, "[", "]")
	if caption_end <= offset + 1 or text.substr(caption_end + 1, 1) != "(":
		return {}
	var url_end := _balanced_end(text, caption_end + 1, "(", ")")
	if url_end < 0:
		return {}
	var url := text.substr(caption_end + 2, url_end - caption_end - 2)
	if not is_web_url(url):
		return {}
	return {"caption": text.substr(offset + 1, caption_end - offset - 1), "url": url, "end": url_end + 1}


## 小型括号扫描不解释任何 HTML 或资源标签，转义括号不能提前结束范围。
static func _balanced_end(text: String, start: int, opening: String, closing: String) -> int:
	var nesting := 0
	var offset := start
	while offset < text.length():
		var character := text.substr(offset, 1)
		if character == "\\":
			offset += 2
			continue
		if character == opening:
			nesting += 1
		elif character == closing:
			nesting -= 1
			if nesting == 0:
				return offset
		offset += 1
	return -1


## 粗体只来自项目自带字体，不允许用户引导指定外部字体路径。
static func _heading_font() -> Font:
	if _bold_font == null:
		var font := FontVariation.new()
		font.base_font = load("res://assets/fonts/NotoSansSC.ttf")
		font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 700.0}
		_bold_font = font
	return _bold_font


## 用项目内置字形轮廓生成中英文斜体，粗斜体继续使用 700 字重，不拉伸渲染后的图片。
static func _slanted_font(bold: bool) -> Font:
	var cached := _bold_italic_font if bold else _italic_font
	if cached == null:
		var font := FontVariation.new()
		font.base_font = load("res://assets/fonts/NotoSansSC.ttf")
		font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 700.0 if bold else 500.0}
		font.variation_transform = Transform2D(Vector2(1.0, 0.20), Vector2(0.0, 1.0), Vector2.ZERO)
		if bold:
			_bold_italic_font = font
		else:
			_italic_font = font
		cached = font
	return cached
