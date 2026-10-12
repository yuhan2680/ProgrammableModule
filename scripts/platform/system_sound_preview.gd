class_name SystemSoundPreview
extends Node
## 只读取操作系统当前提示音，解码后交由游戏总线播放；不会改写系统音量或声音方案。

signal preview_status_changed(message: String)

const REQUEST_TIMEOUT_MSEC: int = 8000
const MAX_AUDIO_BYTES: int = 16 * 1024 * 1024
const MAX_OUTPUT_BYTES: int = 65536
const MAX_AUDIO_SECONDS: float = 10.0
const STATUS_LOADING: String = "正在读取系统提示音…"
const STATUS_DISABLED: String = "当前系统未设置提示音。"
const STATUS_UNSUPPORTED: String = "当前平台不支持系统提示音预览。"
const STATUS_FAILED: String = "无法预览当前系统提示音。"
const STATUS_MUTED: String = "主音量或系统提示音已静音。"
# 脚本固定且不拼接声音路径；注册表按原值读取后仅展开 REG_EXPAND_SZ。
const WINDOWS_RESOLVER: String = """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('AppEvents\\Schemes\\Apps\\.Default\\.Default\\.Current')
    if ($null -eq $key) {
        @{state='disabled';path=''} | ConvertTo-Json -Compress
        exit 0
    }
    try {
        $value = $key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            @{state='disabled';path=''} | ConvertTo-Json -Compress
        } elseif ($value -isnot [string]) {
            exit 2
        } else {
            $kind = $key.GetValueKind('')
            if ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
                $value = [Environment]::ExpandEnvironmentVariables($value)
            } elseif ($kind -ne [Microsoft.Win32.RegistryValueKind]::String) {
                exit 2
            }
            @{state='ready';path=$value} | ConvertTo-Json -Compress
        }
    } finally {
        $key.Dispose()
    }
} catch {
    exit 1
}
"""

var settings: GameSettings:
	set(value):
		if settings == value:
			return
		cancel_preview()
		if settings != null and settings.changed.is_connected(_on_settings_changed):
			settings.changed.disconnect(_on_settings_changed)
		settings = value
		if settings != null:
			settings.changed.connect(_on_settings_changed)
# 测试可注入独立缓存目录；只写入本服务创建的唯一临时文件。
var cache_directory: String = OS.get_cache_dir().path_join("programmable_module/system_sound")
var last_error: String = ""
var _player: AudioStreamPlayer
var _status_source: String = ""
var _request_at: int = -1
var _deadline: int = -1
var _playback_deadline: int = -1
var _job: Dictionary = {}
var _job_stage: String = ""
var _stdout: PackedByteArray = PackedByteArray()
var _stderr: PackedByteArray = PackedByteArray()
var _conversion_path: String = ""
var _source_path: String = ""
var _source_signature: String = ""
var _cached_signature: String = ""
var _cached_stream: AudioStreamWAV


## 播放器只走已由设置模型创建的系统提示音总线，不直接调用系统播放接口。
func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "SystemSoundPlayer"
	_player.bus = GameSettings.SYSTEM_SOUND_BUS
	add_child(_player)
	set_process(false)


## 界面完成输入防抖后请求预览；立即终止旧声音和解析，下一帧读取当前系统设置。
func request_preview() -> void:
	cancel_preview()
	last_error = ""
	if not is_inside_tree() or _player == null:
		return
	if not _can_play():
		_set_status(STATUS_MUTED)
		return
	_request_at = Time.get_ticks_msec()
	set_process(true)


## 页面离开、静音和新请求都走同一取消入口，关闭管道并删除未完成的转换文件。
func cancel_preview() -> void:
	_request_at = -1
	_deadline = -1
	_playback_deadline = -1
	_clear_job(true)
	_remove_conversion_file()
	if is_instance_valid(_player):
		_player.stop()
	set_process(false)
	_set_status("")


## 每帧只做非阻塞管道轮询，超时或输出超限立即结束；不启动工作线程。
func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not _can_play():
		cancel_preview()
		_set_status(STATUS_MUTED)
		return
	if _request_at >= 0:
		if now < _request_at:
			return
		_request_at = -1
		_deadline = now + REQUEST_TIMEOUT_MSEC
		_begin_resolution()
	if not _job.is_empty():
		if now >= _deadline:
			_fail("request_timeout")
			return
		if not _conversion_path.is_empty() and _file_size(_conversion_path) > MAX_AUDIO_BYTES:
			_fail("converted_file_too_large")
			return
		_drain_pipes()
		if _stdout.size() + _stderr.size() > MAX_OUTPUT_BYTES:
			_fail("process_output_too_large")
			return
		var pid: int = _job.get("pid", -1)
		if not _is_process_running(pid):
			# 子进程可能在首次读管道之后退出，再收取末尾字节后关闭句柄。
			_drain_pipes()
			var exit_code := _get_process_exit_code(pid)
			var output := _stdout.get_string_from_utf8()
			var stage := _job_stage
			_clear_job(false)
			if _stdout.size() + _stderr.size() > MAX_OUTPUT_BYTES:
				_fail("process_output_too_large")
			elif stage == "resolve":
				_accept_resolution(parse_resolution(_platform_name(), output, exit_code))
			elif exit_code != 0:
				_fail("conversion_failed")
			else:
				_load_preview(_conversion_path)
	if _playback_deadline >= 0 and now >= _playback_deadline:
		_player.stop()
		_playback_deadline = -1
	if _job.is_empty() and _request_at < 0 and (_player == null or not _player.playing):
		set_process(false)


## 服务释放时不允许外部进程或声音继续存活，并断开设置对象的引用回调。
func _exit_tree() -> void:
	cancel_preview()
	if settings != null and settings.changed.is_connected(_on_settings_changed):
		settings.changed.disconnect(_on_settings_changed)
	_cached_stream = null


## 语言变化时重新发送当前状态，不重新解析或重放声音。
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		preview_status_changed.emit(_status_source)


## 音量通过总线即时变化；调到零则撤销仍在排队或解析的声音。
func _on_settings_changed() -> void:
	if not _can_play():
		cancel_preview()


## 空设置不访问用户存档；主音量与提示音任一为零都禁止启动播放。
func _can_play() -> bool:
	return settings != null and settings.volume > 0.0 and settings.system_sound_volume > 0.0


## 每次实际预览都重新读取当前映射，避免用户在系统设置中换音后仍播放旧选择。
func _begin_resolution() -> void:
	_set_status(STATUS_LOADING)
	match _platform_name():
		"macOS":
			_start_job("/usr/bin/defaults", PackedStringArray(["read", "-g", "com.apple.sound.beep.sound"]), "resolve")
		"Windows":
			var windows_root := OS.get_environment("SystemRoot")
			if windows_root.is_empty() or not windows_root.is_absolute_path():
				_fail("windows_directory_missing")
				return
			var executable := windows_root.path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
			# UTF-16LE 编码命令避免 Windows 命令行的引号和反斜杠规则改变固定脚本。
			var encoded := Marshalls.raw_to_base64(WINDOWS_RESOLVER.to_utf16_buffer())
			_start_job(executable, PackedStringArray(["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]), "resolve")
		_:
			last_error = "unsupported_platform"
			_set_status(STATUS_UNSUPPORTED)


## 纯解析入口供各平台样例测试；失败、无声音和可播放路径保持不同状态。
static func parse_resolution(platform: String, output: String, exit_code: int) -> Dictionary:
	if exit_code != 0 or output.to_utf8_buffer().size() > MAX_OUTPUT_BYTES:
		return {"state": "error", "error": "resolver_failed"}
	if platform == "macOS":
		var path := output.strip_edges()
		if path.is_empty():
			return {"state": "disabled", "path": ""}
		if not path.begins_with("/") or path.contains("\n") or path.contains("\r"):
			return {"state": "error", "error": "invalid_sound_path"}
		return {"state": "ready", "path": path}
	if platform == "Windows":
		var parser := JSON.new()
		if parser.parse(output.trim_prefix("\uFEFF").strip_edges()) != OK or not parser.data is Dictionary:
			return {"state": "error", "error": "invalid_resolver_response"}
		var result: Dictionary = parser.data
		var state: Variant = result.get("state")
		var path: Variant = result.get("path")
		if not path is String:
			return {"state": "error", "error": "invalid_sound_path"}
		if state == "disabled" and path.is_empty():
			return {"state": "disabled", "path": ""}
		# 拒绝相对路径与控制字符；不对注册表路径做脚本或 shell 求值。
		if state != "ready" or not _is_windows_file_path(path) or path.contains("\n") or path.contains("\r"):
			return {"state": "error", "error": "invalid_sound_path"}
		return {"state": "ready", "path": path}
	return {"state": "error", "error": "unsupported_platform"}


## 注册表只能指向 Windows 文件路径，不允许 Godot 资源 URI 或设备管道被当作声音打开。
static func _is_windows_file_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("//"):
		var server := normalized.get_slice("/", 2)
		return not server.is_empty() and not server in [".", "?"] and not normalized.get_slice("/", 3).is_empty()
	return normalized.length() >= 3 and normalized[0].to_upper() >= "A" and normalized[0].to_upper() <= "Z" and normalized.substr(1, 2) == ":/"


## 在读取音频前检查文件大小，缓存只匹配当前路径、修改时间和长度。
func _accept_resolution(result: Dictionary) -> void:
	if result.get("state") == "disabled":
		_set_status(STATUS_DISABLED)
		return
	if result.get("state") != "ready":
		_fail(str(result.get("error", "resolver_failed")))
		return
	_source_path = result["path"]
	var size := _file_size(_source_path)
	if size <= 0 or size > MAX_AUDIO_BYTES:
		_fail("source_unreadable_or_too_large")
		return
	_source_signature = "%s|%d|%d" % [_source_path, FileAccess.get_modified_time(_source_path), size]
	if _cached_stream != null and _cached_signature == _source_signature:
		_play_stream(_cached_stream)
		return
	if _platform_name() == "macOS":
		if DirAccess.make_dir_recursive_absolute(cache_directory) != OK:
			_fail("cache_directory_unavailable")
			return
		_conversion_path = cache_directory.path_join("preview_%d_%d_%d.wav" % [OS.get_process_id(), get_instance_id(), Time.get_ticks_usec()])
		_start_job("/usr/bin/afconvert", PackedStringArray(["-f", "WAVE", "-d", "LEI16@44100", "-c", "2", _source_path, _conversion_path]), "convert")
	else:
		_load_preview(_source_path)


## 外部 WAV 仅接受有界的 PCM/浮点样本，解码前核对 RIFF 块与音频时长。
static func inspect_wav(data: PackedByteArray) -> Dictionary:
	if data.size() < 44 or data.size() > MAX_AUDIO_BYTES:
		return {"valid": false, "error": "wav_size_invalid"}
	if data.slice(0, 4).get_string_from_ascii() != "RIFF" or data.slice(8, 12).get_string_from_ascii() != "WAVE":
		return {"valid": false, "error": "wav_header_invalid"}
	var end := int(data.decode_u32(4)) + 8
	if end > data.size() or end < 44:
		return {"valid": false, "error": "wav_size_invalid"}
	var offset: int = 12
	var frame_bytes: int = 0
	var rate: int = 0
	var audio_bytes: int = -1
	var format_offset: int = -1
	var data_offset: int = -1
	var chunks: int = 0
	while offset + 8 <= end and chunks < 512:
		var chunk := data.slice(offset, offset + 4).get_string_from_ascii()
		var length := int(data.decode_u32(offset + 4))
		var start := offset + 8
		if start + length > end:
			return {"valid": false, "error": "wav_chunk_invalid"}
		if chunk == "fmt ":
			if length < 16 or format_offset >= 0:
				return {"valid": false, "error": "wav_format_invalid"}
			format_offset = start
			var format := data.decode_u16(start)
			var channels := data.decode_u16(start + 2)
			rate = data.decode_u32(start + 4)
			frame_bytes = data.decode_u16(start + 12)
			var bits := data.decode_u16(start + 14)
			if channels < 1 or channels > 2 or rate < 1000 or rate > 192000 or frame_bytes * 8 != channels * bits:
				return {"valid": false, "error": "wav_format_invalid"}
			if (format != 1 or not bits in [8, 16, 24, 32]) and (format != 3 or not bits in [32, 64]):
				return {"valid": false, "error": "wav_encoding_unsupported"}
		elif chunk == "data":
			if format_offset < 0 or data_offset >= 0:
				return {"valid": false, "error": "wav_audio_invalid"}
			data_offset = start
			audio_bytes = length
		offset = start + length + (length % 2)
		chunks += 1
	if frame_bytes <= 0 or rate <= 0 or audio_bytes <= 0 or audio_bytes % frame_bytes != 0 or offset != end:
		return {"valid": false, "error": "wav_audio_invalid"}
	var duration := float(audio_bytes) / float(rate * frame_bytes)
	if duration > MAX_AUDIO_SECONDS:
		return {"valid": false, "error": "audio_too_long"}
	return {"valid": true, "duration": duration, "format_offset": format_offset, "data_offset": data_offset, "data_bytes": audio_bytes}


## 只向引擎传递已校验的格式和样本；预览不需要元数据，防止畸形标签声明额外的大分配。
static func _minimal_wav(data: PackedByteArray, inspection: Dictionary) -> PackedByteArray:
	var audio_bytes: int = inspection["data_bytes"]
	var format_offset: int = inspection["format_offset"]
	var data_offset: int = inspection["data_offset"]
	var result := PackedByteArray()
	result.append_array("RIFF".to_ascii_buffer())
	result.resize(8)
	result.encode_u32(4, 36 + audio_bytes + audio_bytes % 2)
	result.append_array("WAVEfmt ".to_ascii_buffer())
	result.resize(20)
	result.encode_u32(16, 16)
	result.append_array(data.slice(format_offset, format_offset + 16))
	result.append_array("data".to_ascii_buffer())
	result.resize(44)
	result.encode_u32(40, audio_bytes)
	result.append_array(data.slice(data_offset, data_offset + audio_bytes))
	if audio_bytes % 2 != 0:
		result.append(0)
	return result


## 在解码前完成大小和格式检查；成功后内存缓存波形并删除转换副本。
func _load_preview(path: String) -> void:
	var size := _file_size(path)
	if size <= 0 or size > MAX_AUDIO_BYTES:
		_fail("audio_unreadable_or_too_large")
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("audio_unreadable")
		return
	var bytes := file.get_buffer(mini(file.get_length(), MAX_AUDIO_BYTES + 1))
	file.close()
	var inspection := inspect_wav(bytes)
	if not inspection.get("valid", false):
		_fail(str(inspection.get("error", "wav_invalid")))
		return
	var stream := AudioStreamWAV.load_from_buffer(_minimal_wav(bytes, inspection))
	_remove_conversion_file()
	if stream == null or stream.get_length() <= 0.0 or stream.get_length() > MAX_AUDIO_SECONDS:
		_fail("audio_decode_failed")
		return
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	_cached_signature = _source_signature
	_cached_stream = stream
	_play_stream(stream)


## 可由无声测试覆写此单一入口；正式播放只通过游戏内音量总线。
func _play_stream(stream: AudioStreamWAV) -> void:
	if not _can_play() or not is_inside_tree():
		return
	if AudioServer.get_bus_index(GameSettings.SYSTEM_SOUND_BUS) < 0:
		_fail("system_sound_bus_missing")
		return
	_player.stream = stream
	_player.bus = GameSettings.SYSTEM_SOUND_BUS
	_player.play()
	_playback_deadline = Time.get_ticks_msec() + int(MAX_AUDIO_SECONDS * 1000.0)
	_set_status("")


## 单次只维护一个子进程，非阻塞标志是防止设置页停顿的必要条件。
func _start_job(executable: String, arguments: PackedStringArray, stage: String) -> void:
	_stdout.clear()
	_stderr.clear()
	_job_stage = stage
	_job = _spawn_process(executable, arguments)
	if _job.is_empty() or int(_job.get("pid", -1)) <= 0:
		_fail("process_start_failed")


## 每帧限制读取量，stdout 与 stderr 都消费以避免子进程因管道写满而卡住。
func _drain_pipes() -> void:
	var output: FileAccess = _job.get("stdio")
	var errors: FileAccess = _job.get("stderr")
	if output != null:
		_stdout.append_array(output.get_buffer(8192))
	if errors != null:
		_stderr.append_array(errors.get_buffer(8192))


## 取消时先终止子进程再关闭管道，正常结束则只释放本服务持有的句柄。
func _clear_job(terminate: bool) -> void:
	var pid: int = _job.get("pid", -1)
	if terminate and pid > 0 and _is_process_running(pid):
		_kill_process(pid)
	for key in ["stdio", "stderr"]:
		var pipe: FileAccess = _job.get(key)
		if pipe != null:
			pipe.close()
	_job.clear()
	_job_stage = ""


## 转换文件名由本服务唯一生成，绝不删除用户所配置的声音源文件。
func _remove_conversion_file() -> void:
	if not _conversion_path.is_empty():
		if FileAccess.file_exists(_conversion_path):
			DirAccess.remove_absolute(_conversion_path)
		_conversion_path = ""


## 失败统一显示可翻译文案，诊断码仅保存在属性中供测试或开发排查。
func _fail(reason: String) -> void:
	cancel_preview()
	last_error = reason
	_set_status(STATUS_FAILED)


## 无变化时不重复发送状态，避免连续拖动产生无意义的界面刷新。
func _set_status(source: String) -> void:
	if _status_source == source:
		return
	_status_source = source
	preview_status_changed.emit(source)


## 获取文件尺寸而不把整个文件载入内存，不存在或无法打开时返回负数。
func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return size


## 平台判断独立成小入口，便于在宿主机上验证另一平台的映射流程。
func _platform_name() -> String:
	return OS.get_name()


## 进程创建独立成可覆写入口，测试可注入假进程而不启动本机工具。
func _spawn_process(executable: String, arguments: PackedStringArray) -> Dictionary:
	return OS.execute_with_pipe(executable, arguments, false)


## 进程状态可由测试覆写，正式路径使用 Godot 自带子进程追踪。
func _is_process_running(pid: int) -> bool:
	return OS.is_process_running(pid)


## 只在已完成的进程上读取退出码，避免将仍在运行误判为成功。
func _get_process_exit_code(pid: int) -> int:
	return OS.get_process_exit_code(pid)


## 结束超时或过期进程，避免离开设置页后仍有转换任务运行。
func _kill_process(pid: int) -> void:
	OS.kill(pid)
