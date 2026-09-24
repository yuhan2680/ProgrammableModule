class_name ProgramLexer
extends RefCounted
## 逐字符词法分析器。换行是独立 token，不通过拆分代码行猜测语法。

enum Kind { IDENTIFIER, NUMBER, LEFT_PAREN, RIGHT_PAREN, LEFT_BRACE, RIGHT_BRACE, COMMA, PLUS, MINUS, DOT, SEMICOLON, LESS, LESS_EQUAL, GREATER, GREATER_EQUAL, EQUAL, NOT_EQUAL, NEWLINE, END, ASSIGN, RANGE, ARROW }

const MAX_SOURCE_BYTES: int = 64 * 1024
const MAX_TOKENS: int = 4096


class Token extends RefCounted:
	var kind: Kind = Kind.END
	var lexeme: String = ""
	var line: int = 1
	var column: int = 1


var _source: String = ""
var _index: int = 0
var _line: int = 1
var _column: int = 1
var _tokens: Array[Token] = []
var _error: String = ""


## 检查源代码大小后创建独立词法分析状态；成功值为 Token 数组。
static func tokenize(source: String) -> DataResult:
	if source.to_utf8_buffer().size() > MAX_SOURCE_BYTES:
		return DataResult.failure("第 1 行，第 1 列：源代码不能超过 64 KiB。")
	var lexer := ProgramLexer.new()
	lexer._source = source
	return lexer._scan()


## 扫描所有字符并保留注释末尾的换行，保证语句分隔信息不会丢失。
func _scan() -> DataResult:
	while _index < _source.length() and _error.is_empty():
		var character := _source[_index]
		if character == " " or character == "\t":
			_advance()
		elif character == "\r" or character == "\n":
			_scan_newline()
		elif character == "/" and _peek_next() == "/":
			# 注释只吃到行尾，换行交回主扫描循环处理。
			while _index < _source.length() and _source[_index] not in ["\r", "\n"]:
				_advance()
		elif _is_identifier_start(character):
			_scan_identifier()
		elif _is_digit(character) or (character == "." and _is_digit(_peek_next())):
			_scan_number()
		else:
			_scan_symbol(character)
	if not _error.is_empty():
		return DataResult.failure(_error)
	_emit(Kind.END, "", _line, _column)
	if not _error.is_empty():
		return DataResult.failure(_error)
	return DataResult.success(_tokens)


## 将 LF、CRLF 与单独 CR 都转换为一个换行 token，并准确更新行列。
func _scan_newline() -> void:
	var start_line := _line
	var start_column := _column
	var first := _source[_index]
	_index += 1
	if first == "\r" and _index < _source.length() and _source[_index] == "\n":
		_index += 1
	_line += 1
	_column = 1
	_emit(Kind.NEWLINE, "\n", start_line, start_column)


## 读取标识符；关键字是否解锁由解析器判断，词法层不执行玩法规则。
func _scan_identifier() -> void:
	var start_index := _index
	var start_column := _column
	while _index < _source.length() and (_is_identifier_start(_source[_index]) or _is_digit(_source[_index])):
		_advance()
	_emit(Kind.IDENTIFIER, _source.substr(start_index, _index - start_index), _line, start_column)


## 读取十进制字面量；符号作为独立 token，使负数与未来运算符语法易于区分。
func _scan_number() -> void:
	var start_index := _index
	var start_column := _column
	while _index < _source.length() and _is_digit(_source[_index]):
		_advance()
	if _index < _source.length() and _source[_index] == "." and _peek_next() != ".":
		_advance()
		while _index < _source.length() and _is_digit(_source[_index]):
			_advance()
	var literal := _source.substr(start_index, _index - start_index)
	if not is_finite(literal.to_float()):
		_error = _format_error(_line, start_column, "数字字面量超出有限数值范围。")
		return
	_emit(Kind.NUMBER, literal, _line, start_column)


## 点后紧跟数字时已按小数字面量扫描；此处的点用于命名调用，解锁由解析器判断。
func _scan_symbol(character: String) -> void:
	# 箭头必须连续出现，不能把减号和比较符拼成事件绑定或普通算术。
	if character == "-" and _peek_next() == ">":
		_emit(Kind.ARROW, "->", _line, _column)
		_advance()
		_advance()
		return
	if character == "." and _peek_next() == ".":
		_emit(Kind.RANGE, "..", _line, _column)
		_advance()
		_advance()
		return
	# 双字符比较符必须整体消费，单独的赋值和逻辑非仍不属于本关语法。
	if character in ["<", ">", "=", "!"]:
		var comparison := character + ("=" if _peek_next() == "=" else "")
		var comparisons := {"<": Kind.LESS, "<=": Kind.LESS_EQUAL, ">": Kind.GREATER, ">=": Kind.GREATER_EQUAL, "==": Kind.EQUAL, "!=": Kind.NOT_EQUAL}
		if comparisons.has(comparison):
			_emit(comparisons[comparison], comparison, _line, _column)
			for unused in comparison.length():
				_advance()
			return
	var symbols := {
		"(": Kind.LEFT_PAREN, ")": Kind.RIGHT_PAREN,
		"{": Kind.LEFT_BRACE, "}": Kind.RIGHT_BRACE,
		",": Kind.COMMA, "+": Kind.PLUS, "-": Kind.MINUS,
		".": Kind.DOT, ";": Kind.SEMICOLON, "=": Kind.ASSIGN,
	}
	if not symbols.has(character):
		_error = _format_error(_line, _column, "不支持的字符“%s”。第一关仅支持 main 与 move 调用。" % character)
		return
	_emit(symbols[character], character, _line, _column)
	_advance()


## 添加带位置的 token，并在达到上限时停止解析以防止过大程序阻塞界面。
func _emit(kind: Kind, lexeme: String, line: int, column: int) -> void:
	if _tokens.size() >= MAX_TOKENS:
		_error = _format_error(line, column, "源代码不能超过 %d 个 token。" % MAX_TOKENS)
		return
	var token := Token.new()
	token.kind = kind
	token.lexeme = lexeme
	token.line = line
	token.column = column
	_tokens.append(token)


## 前进一个非换行字符；制表符按一个源码字符计列。
func _advance() -> void:
	_index += 1
	_column += 1


## 安全查看下一字符，不读取字符串边界之外的数据。
func _peek_next() -> String:
	return _source[_index + 1] if _index + 1 < _source.length() else ""


## 判断指令与模块实例标识符允许的 ASCII 起始字符。
static func _is_identifier_start(character: String) -> bool:
	return (character >= "a" and character <= "z") or (character >= "A" and character <= "Z") or character == "_"


## 判断十进制数字字符；空字符串不会被视为数字。
static func _is_digit(character: String) -> bool:
	return character >= "0" and character <= "9"


## 统一词法错误的位置格式，方便编辑器提取源码高亮行。
static func _format_error(line: int, column: int, reason: String) -> String:
	return "第 %d 行，第 %d 列：%s" % [line, column, reason]
