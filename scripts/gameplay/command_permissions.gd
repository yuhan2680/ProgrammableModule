class_name CommandPermissions
extends RefCounted
## 固定指令权限只描述解释器已有能力；资料 JSON 不注册语法，也不执行脚本。

const COMMAND_IDS := ["main", "move", "attack", "shoot", "tick", "named_calls", "named_move", "named_attack", "named_shoot", "loop", "if_else", "ready", "simultaneously", "distance", "named_distance", "functions", "constants", "variables", "scan", "named_scan", "radar_angle", "radar_position", "radar_distance", "radar_event", "random", "random_int", "for_range"]
const DEPENDENCIES := {
	"named_move": ["named_calls"], "named_attack": ["named_calls"], "named_shoot": ["named_calls"],
	"ready": ["if_else", "named_calls"], "named_distance": ["named_calls"], "named_scan": ["named_calls"],
	"radar_angle": ["variables", "scan"], "radar_position": ["variables", "scan"], "radar_distance": ["variables", "scan"],
	"radar_event": ["named_calls", "variables", "scan"],
}
const FLAG_COMMANDS := {
	"allow_tick": ["tick"], "allow_named_calls": ["named_calls"], "allow_loops": ["loop"],
	"allow_conditionals": ["if_else", "ready"], "allow_simultaneous": ["simultaneously"],
	"allow_distance": ["distance", "named_distance"], "allow_functions": ["functions"],
	"allow_variables": ["constants", "variables"], "allow_radar": ["scan", "named_scan", "radar_angle", "radar_position", "radar_distance", "radar_event"],
	"allow_radar_events": ["radar_event"], "allow_random": ["random", "random_int"], "allow_for": ["for_range"],
}


## JSON 数组必须引用固定的已有指令；重复、未知或缺失主入口均不能静默修正。
static func validate(value: Variant, require_dependencies: bool = true) -> DataResult:
	if not value is Array or value.size() > COMMAND_IDS.size():
		return DataResult.failure("启用的指令必须为最多 27 个指令 ID 的数组。")
	var ids := PackedStringArray()
	for identity in value:
		if not identity is String or identity not in COMMAND_IDS:
			return DataResult.failure("启用的指令引用了无效或未知指令。")
		if identity in ids:
			return DataResult.failure("启用的指令中存在重复 ID：%s。" % identity)
		ids.append(identity)
	if "main" not in ids:
		return DataResult.failure("main() 是必要的程序入口，不能限制使用。")
	if require_dependencies:
		for identity in ids:
			for required: String in DEPENDENCIES.get(identity, []):
				if required not in ids:
					return DataResult.failure("指令 %s 需要同时启用 %s。" % [identity, required])
	return DataResult.success(ordered(ids))


## 旧地图只投影原有布尔开关；模块可用性由装配和资料目录另行判断，读取不写盘。
static func project_legacy(metadata: Dictionary) -> PackedStringArray:
	var ids := PackedStringArray(["main", "move", "attack", "shoot"])
	for identity: String in COMMAND_IDS:
		var available := false
		match identity:
			"tick": available = metadata.get("allow_tick", false) == true
			"named_calls", "named_move", "named_attack", "named_shoot": available = metadata.get("allow_named_calls", false) == true
			"loop": available = metadata.get("allow_loops", false) == true
			"if_else": available = metadata.get("allow_conditionals", false) == true
			"ready": available = metadata.get("allow_conditionals", false) == true and metadata.get("allow_named_calls", false) == true
			"simultaneously": available = metadata.get("allow_simultaneous", false) == true
			"distance": available = metadata.get("allow_distance", false) == true
			"named_distance": available = metadata.get("allow_distance", false) == true and metadata.get("allow_named_calls", false) == true
			"functions": available = metadata.get("allow_functions", false) == true
			"constants", "variables": available = metadata.get("allow_variables", false) == true
			"scan": available = metadata.get("allow_radar", false) == true
			"named_scan": available = metadata.get("allow_radar", false) == true and metadata.get("allow_named_calls", false) == true
			"radar_angle", "radar_position", "radar_distance": available = metadata.get("allow_radar", false) == true and metadata.get("allow_variables", false) == true
			"radar_event": available = metadata.get("allow_radar_events", false) == true and metadata.get("allow_radar", false) == true and metadata.get("allow_named_calls", false) == true and metadata.get("allow_variables", false) == true
			"random", "random_int": available = metadata.get("allow_random", false) == true
			"for_range": available = metadata.get("allow_for", false) == true
		if available and identity not in ids:
			ids.append(identity)
	return ordered(ids)


## 显式新策略严格读取；没有该字段时保持旧开关的真实权限，绝不补写默认数组。
static func read(metadata: Dictionary) -> DataResult:
	return validate(metadata.enabled_commands) if metadata.has("enabled_commands") else DataResult.success(project_legacy(metadata))


## 用户显式开启指令时同一事务补齐前提，不改写任何旧地图默认策略。
static func normalize_enabled(value: Variant) -> DataResult:
	var checked := validate(Array(value) if value is PackedStringArray else value, false)
	if not checked.is_ok():
		return checked
	var ids: PackedStringArray = checked.value.duplicate()
	var changed := true
	while changed:
		changed = false
		for identity in ids.duplicate():
			for required: String in DEPENDENCIES.get(identity, []):
				if required not in ids:
					ids.append(required)
					changed = true
	return DataResult.success(ordered(ids))


## 单个开关返回完整的新策略；关闭前提会同一事务关闭依赖项，主入口始终保留。
static func toggle(value: PackedStringArray, identity: String, enabled: bool) -> DataResult:
	if identity not in COMMAND_IDS:
		return DataResult.failure("无法更改未知指令：%s。" % identity)
	if identity == "main" and not enabled:
		return DataResult.failure("main() 是必要的程序入口，不能限制使用。")
	var ids := value.duplicate()
	if enabled:
		if identity not in ids:
			ids.append(identity)
		return normalize_enabled(ids)
	var index := ids.find(identity)
	if index >= 0:
		ids.remove_at(index)
	var changed := true
	while changed:
		changed = false
		for command in ids.duplicate():
			var missing := false
			for required: String in DEPENDENCIES.get(command, []):
				missing = missing or required not in ids
			if missing:
				ids.remove_at(ids.find(command))
				changed = true
	return DataResult.success(ordered(ids))


## 旧解析器的能力布尔值只由显式启用家族派生；具体调用形态仍由新策略逐项限制。
static func legacy_flags(ids: PackedStringArray) -> Dictionary:
	var flags := {}
	for flag: String in FLAG_COMMANDS:
		var enabled := false
		for identity: String in FLAG_COMMANDS[flag]:
			enabled = enabled or identity in ids
		flags[flag] = enabled
	return flags


## 稳定目录顺序只用于快照与序列化，不修改调用方的数组或原始元数据。
static func ordered(ids: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	for identity: String in COMMAND_IDS:
		if identity in ids:
			result.append(identity)
	return result
