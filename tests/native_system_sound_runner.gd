extends SceneTree
## 默认只使用隔离文件、零值样本和假进程；--native-probe 才读取宿主系统声音且不播放。

class FakePreview:
	extends SystemSoundPreview
	var fixture_directory: String
	var spawned: int = 0
	var killed: Array[int] = []
	var active: bool = false
	var captured: AudioStreamWAV
	var capture_count: int = 0

	## 假进程沿用 macOS 两阶段管道协议，完全不调用操作系统工具。
	func _platform_name() -> String:
		return "macOS"

	## 返回隔离文件句柄模拟 stdout，并将已知零值 WAV 写入转换输出。
	func _spawn_process(executable: String, arguments: PackedStringArray) -> Dictionary:
		spawned += 1
		active = true
		var output := fixture_directory.path_join("resolver.txt")
		if executable == "/usr/bin/afconvert":
			DirAccess.copy_absolute(fixture_directory.path_join("silent.wav"), arguments[arguments.size() - 1])
			output = fixture_directory.path_join("empty.txt")
		return {"pid": spawned, "stdio": FileAccess.open(output, FileAccess.READ), "stderr": FileAccess.open(fixture_directory.path_join("empty.txt"), FileAccess.READ)}

	## 由用例决定进程何时完成，避免真实等待及跨平台时序差异。
	func _is_process_running(_pid: int) -> bool:
		return active

	## 假进程正常完成，映射内容和 WAV 仍走正式校验逻辑。
	func _get_process_exit_code(_pid: int) -> int:
		return 0

	## 记录取消是否确实终止了当前任务。
	func _kill_process(pid: int) -> void:
		killed.append(pid)
		active = false

	## 零值样本可验证真实播放器停止和总线路由，绝不读取真实操作系统音频。
	func _play_stream(stream: AudioStreamWAV) -> void:
		captured = stream
		capture_count += 1
		super._play_stream(stream)

	## 推进一个假进程结束，让正式服务消费输出并开始下一阶段。
	func finish_job() -> void:
		active = false
		_process(0.0)


class SilentNativePreview:
	extends SystemSoundPreview
	var captured: AudioStreamWAV

	## 原生探针只捕获解码结果，禁止触发播放器。
	func _play_stream(stream: AudioStreamWAV) -> void:
		captured = stream
		_set_status("")


var _failures: int = 0
var _checks: int = 0
var _directory: String


## 延后启动，保证场景树可安全接收被测节点。
func _initialize() -> void:
	_run.call_deferred()


## 分开执行确定性回归与显式原生探针，最后清理本次独占目录。
func _run() -> void:
	_directory = ProjectSettings.globalize_path("user://tests/native_system_sound_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(_directory)
	if "--native-probe" in OS.get_cmdline_user_args():
		await _native_probe()
	else:
		_test_mapping_parsers()
		_test_wav_bounds()
		await _test_lifecycle()
	# AudioServer 在混音线程释放已停止的播放实例，退出测试前留出实际混音周期。
	await create_timer(0.1).timeout
	_cleanup_directory(_directory)
	print("原生提示音回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 注册表样例包含中文、空格、展开后的绝对路径和禁用状态，不依赖 Windows 宿主。
func _test_mapping_parsers() -> void:
	var path := "C:\\Windows\\Media\\提示 音.wav"
	var resolved := SystemSoundPreview.parse_resolution("Windows", JSON.stringify({"state": "ready", "path": path}), 0)
	_check(resolved.get("path") == path and resolved.get("state") == "ready", "Windows Unicode path survives JSON parsing")
	_check(SystemSoundPreview.parse_resolution("Windows", '{"state":"disabled","path":""}', 0).get("state") == "disabled", "Disabled Windows mapping stays silent")
	_check(SystemSoundPreview.parse_resolution("Windows", '{"state":"ready","path":23}', 0).get("state") == "error", "Non-string Windows mapping is rejected")
	_check(SystemSoundPreview.parse_resolution("Windows", '{broken', 0).get("state") == "error", "Malformed Windows response is rejected")
	_check(SystemSoundPreview.parse_resolution("Windows", '{"state":"ready","path":"res://fake.wav"}', 0).get("state") == "error", "Game resource URI is not an OS sound path")
	_check(SystemSoundPreview.parse_resolution("macOS", "/System/Library/Sounds/Tink.aiff\n", 0).get("state") == "ready", "macOS output newline is accepted")
	_check(SystemSoundPreview.parse_resolution("macOS", "\n", 0).get("state") == "disabled", "Empty macOS mapping stays silent")
	_check(SystemSoundPreview.parse_resolution("macOS", "", 1).get("state") == "error", "Missing macOS preference is not replaced by a guessed sound")


## 在进入引擎解码器前验证格式、截断、大小与时长限制。
func _test_wav_bounds() -> void:
	var valid := _silent_wav(0.05)
	var inspection := SystemSoundPreview.inspect_wav(valid)
	_check(inspection.get("valid", false) and is_equal_approx(inspection.get("duration", 0.0), 0.05), "Valid PCM duration is inspected")
	_check(not SystemSoundPreview.inspect_wav(valid.slice(0, valid.size() - 2)).get("valid", true), "Truncated WAV is rejected")
	var unsupported := valid.duplicate()
	unsupported.encode_u16(20, 17)
	_check(not SystemSoundPreview.inspect_wav(unsupported).get("valid", true), "Unsupported WAV codec is rejected before decode")
	_check(SystemSoundPreview.inspect_wav(_silent_wav(10.1)).get("error") == "audio_too_long", "Sounds longer than ten seconds are rejected")
	var oversized := PackedByteArray()
	oversized.resize(SystemSoundPreview.MAX_AUDIO_BYTES + 1)
	_check(not SystemSoundPreview.inspect_wav(oversized).get("valid", true), "Files over 16 MiB are rejected")


## 使用假进程验证替换、缓存、静音、超时、错误与退出都不会留下旧声音或任务。
func _test_lifecycle() -> void:
	_write_bytes(_directory.path_join("silent.wav"), _silent_wav(0.5))
	_write_bytes(_directory.path_join("empty.txt"), PackedByteArray())
	_write_bytes(_directory.path_join("resolver.txt"), (_directory.path_join("silent.wav") + "\n").to_utf8_buffer())
	var model := GameSettings.new("user://tests/" + _directory.get_file() + "/settings.json")
	model.load_settings()
	var preview := FakePreview.new()
	preview.settings = model
	preview.fixture_directory = _directory
	preview.cache_directory = _directory.path_join("cache with spaces 中文")
	root.add_child(preview)
	preview.request_preview()
	preview._process(0.0)
	preview.request_preview()
	_check(preview.killed.size() == 1 and preview.capture_count == 0, "Replacing a lookup kills the old process without playing")
	preview._process(0.0)
	preview.finish_job()
	preview.finish_job()
	_check(preview.capture_count == 1 and preview.last_error.is_empty(), "Two-stage native protocol produces one decoded preview")
	_check(preview._player.bus == GameSettings.SYSTEM_SOUND_BUS, "Preview player uses the system sound bus")
	_check(preview._conversion_path.is_empty() and DirAccess.get_files_at(preview.cache_directory).is_empty(), "Successful conversion removes its temporary file")
	# 让真实播放器经过混音周期后再取消，避免以同帧模拟代替用户实际交互。
	await create_timer(0.08).timeout
	_check(preview._player.playing, "Silent fixture enters real playback before cancellation")
	var cached := preview.captured
	var previous_spawns := preview.spawned
	preview.request_preview()
	_check(not preview._player.playing, "New preview stops previous playback immediately")
	preview._process(0.0)
	preview.finish_job()
	_check(preview.spawned == previous_spawns + 1 and preview.captured == cached and preview.capture_count == 2, "Cache reuses decoded samples but resolves current preference again")
	await create_timer(0.08).timeout
	preview.request_preview()
	preview._process(0.0)
	model.system_sound_volume = 0.0
	model.changed.emit()
	_check(preview._job.is_empty() and not preview._player.playing and preview._request_at < 0, "Muting cancels pending lookup and playback")
	model.system_sound_volume = 1.0
	preview.request_preview()
	preview._process(0.0)
	preview._deadline = Time.get_ticks_msec() - 1
	preview._process(0.0)
	_check(preview.last_error == "request_timeout" and preview._job.is_empty(), "Timed-out lookup is killed and reports a diagnostic")
	_write_bytes(_directory.path_join("resolver.txt"), "not an absolute path".to_utf8_buffer())
	preview.request_preview()
	preview._process(0.0)
	preview.finish_job()
	_check(preview.last_error == "invalid_sound_path" and preview.capture_count == 2, "Invalid mapping does not replay cached audio")
	_write_bytes(_directory.path_join("resolver.txt"), (_directory.path_join("silent.wav") + "\n").to_utf8_buffer())
	preview._cached_signature = ""
	preview.request_preview()
	preview._process(0.0)
	preview.finish_job()
	var conversion := preview._conversion_path
	_check(FileAccess.file_exists(conversion), "Pending conversion fixture exists before cancellation")
	root.remove_child(preview)
	_check(preview._job.is_empty() and not FileAccess.file_exists(conversion) and not model.changed.is_connected(preview._on_settings_changed), "Leaving tree kills conversion, removes output and disconnects settings")
	preview.free()


## 显式探针读取 macOS 当前配置并转换，但只捕获流，不播放也不修改系统偏好。
func _native_probe() -> void:
	if OS.get_name() != "macOS":
		print("Native probe skipped: this probe requires macOS.")
		return
	var preview := SilentNativePreview.new()
	preview.settings = GameSettings.new("user://tests/" + _directory.get_file() + "/settings.json")
	preview.cache_directory = _directory.path_join("native cache 中文")
	root.add_child(preview)
	preview.request_preview()
	var deadline := Time.get_ticks_msec() + 10000
	while preview.captured == null and preview.last_error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(preview.captured != null, "Actual macOS default sound resolves and decodes without playback: " + preview.last_error)
	if preview.captured != null:
		print("Native source: %s; duration: %.3f s; PCM bytes: %d." % [preview._source_path, preview.captured.get_length(), preview.captured.data.size()])
		_check(not preview._player.playing, "Native probe never starts audio playback")
	preview.queue_free()


## 生成短小的零值 PCM16 样本，仅作为解码和播放器控制的无声夹具。
func _silent_wav(seconds: float) -> PackedByteArray:
	var sample_rate: int = 8000
	var audio_bytes := int(sample_rate * seconds) * 2
	var data := PackedByteArray()
	data.resize(44 + audio_bytes)
	for item in [{"offset": 0, "text": "RIFF"}, {"offset": 8, "text": "WAVEfmt "}, {"offset": 36, "text": "data"}]:
		var text_bytes: PackedByteArray = item["text"].to_ascii_buffer()
		for index in text_bytes.size():
			data[item["offset"] + index] = text_bytes[index]
	data.encode_u32(4, 36 + audio_bytes)
	data.encode_u32(16, 16)
	data.encode_u16(20, 1)
	data.encode_u16(22, 1)
	data.encode_u32(24, sample_rate)
	data.encode_u32(28, sample_rate * 2)
	data.encode_u16(32, 2)
	data.encode_u16(34, 16)
	data.encode_u32(40, audio_bytes)
	return data


## 仅向本次独占测试目录写入已知夹具。
func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


## 累计可定位的断言错误，避免脚本异常被误报为通过。
func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)


## 只递归删除本次创建的隔离目录，不接触玩家设置或系统声音。
func _cleanup_directory(path: String) -> void:
	for child in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(child))
	for child in DirAccess.get_directories_at(path):
		_cleanup_directory(path.path_join(child))
	DirAccess.remove_absolute(path)
