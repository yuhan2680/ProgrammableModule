extends SceneTree
## 指令资料的数据层回归；只读生产 JSON，新增、损坏与删除用例仅写独占 user://tests。

var _test_root: String
var _checks := 0
var _failures := 0


## 等待场景树初始化后执行，便于通过标准测试脚本汇总退出结果。
func _initialize() -> void:
	_run.call_deferred()


## 验证真实资料、动态发现、错误隔离、本土化及真实关卡解锁，不调用游戏执行器。
func _run() -> void:
	_test_root = "user://tests/command_catalog_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_test_builtin_entries()
	_test_reload_and_duplicates()
	_test_invalid_files_and_limits()
	_test_localized_fallback()
	_test_level_availability()
	_test_sections()
	_test_global_search()
	_test_dynamic_sections_and_search()
	_remove_test_tree(_test_root)
	print("指令资料回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## 内置资料覆盖当前实现的语法及三个具体具名调用，中英说明齐全，模板只是可阅读文本。
func _test_builtin_entries() -> void:
	var catalog := CommandCatalog.new()
	_ok(catalog.load_directory(), "默认目录完整加载")
	_check(_ids(catalog) == ["main", "move", "attack", "shoot", "tick", "named_calls", "named_move", "named_attack", "named_shoot", "loop", "if_else", "ready", "simultaneously", "distance", "named_distance", "functions", "constants", "variables", "scan", "named_scan", "radar_angle", "radar_position", "radar_distance", "radar_event", "random", "random_int", "for_range"], "二十七项真实资料按显式顺序列出")
	for entry in catalog.entries:
		_check(not CommandCatalog.localized(entry, "title", "zh_CN").is_empty(), "每项有简体中文标题")
		_check(not CommandCatalog.localized(entry, "title", "en").is_empty(), "每项有英文标题")
		_check(not CommandCatalog.localized(entry, "description", "zh_CN").is_empty() and not CommandCatalog.localized(entry, "description", "en").is_empty(), "每项有中英文说明")
		_check(not entry.syntax.is_empty() and entry.category in ["structure", "action", "query"], "语法模板和分类由 JSON 提供")
		_check(entry.source_path.begins_with("res://data/commands/"), "条目携带实际来源路径供诊断")


## 扫描按文件名稳定解决重复 ID；新增与删除 JSON 在下次加载自动反映，不依赖硬编码清单。
func _test_reload_and_duplicates() -> void:
	var path := _test_root.path_join("reload")
	_write_json(path.path_join("20_beta.json"), _entry("beta", 20))
	_write_json(path.path_join("10_alpha.json"), _entry("alpha", 10))
	_write_json(path.path_join("21_alpha_duplicate.json"), _entry("alpha", -500))
	_write_text(path.path_join("ignored.txt"), "not JSON")
	_write_json(path.path_join("nested/hidden.json"), _entry("nested", 0))
	var catalog := CommandCatalog.new()
	var loaded := catalog.load_directory(path)
	_check(not loaded.is_ok() and loaded.errors.size() == 1, "重复 ID 有明确逐文件错误")
	_check(_ids(catalog) == ["alpha", "beta"] and catalog.entries[0].order == 10, "重复 ID 保留按文件名先读取的有效版本")
	_check(loaded.value.size() == 2, "带错误的 DataResult 仍返回有效资料供界面展示")
	loaded.value[0].title.zh_CN = "外部修改"
	_check(catalog.entries[0].title.zh_CN == "标题 alpha", "返回的快照与目录数据互不污染")
	DirAccess.remove_absolute(path.path_join("21_alpha_duplicate.json"))
	_write_json(path.path_join("90_new.JSON"), _entry("new_command", 5))
	_ok(catalog.load_directory(path), "新增大小写扩展名 JSON 后自动重载并清除旧错误")
	_check(_ids(catalog) == ["new_command", "alpha", "beta"], "新增资料不修改 UI 也能被发现并按 order 插入")
	DirAccess.remove_absolute(path.path_join("10_alpha.json"))
	_ok(catalog.load_directory(path), "删除资料后重载成功")
	_check(_ids(catalog) == ["new_command", "beta"], "删除的资料不会在旧缓存继续出现")
	_write_json(path.path_join("00_zeta.json"), _entry("zeta", 20))
	_ok(catalog.load_directory(path), "同顺序值的资料可以加载")
	_check(_ids(catalog) == ["new_command", "beta", "zeta"], "相同 order 使用稳定 ID 顺序")
	var marker := _test_root.path_join("should_not_execute.txt")
	var text_only := _entry("text_only", 30)
	text_only.syntax = "FileAccess.open(\"%s\", FileAccess.WRITE)" % marker
	_write_json(path.path_join("99_text_only.json"), text_only)
	_ok(catalog.load_directory(path), "类似脚本的 syntax 仍只作为文档纯文本读取")
	_check(not FileAccess.file_exists(marker), "加载指令资料绝不执行 JSON 中的示例")


## 坏 JSON、错误类型、未知权限、超长内容与无效目录单独报告，不遮蔽同目录的有效项。
func _test_invalid_files_and_limits() -> void:
	var path := _test_root.path_join("invalid")
	_write_json(path.path_join("00_valid.json"), _entry("valid", 0))
	var changes := [
		{"id": ""}, {"format_version": 2}, {"order": true}, {"order": 0.5},
		{"category": "../unsafe"}, {"title": {}}, {"title": {"en": 2}}, {"title": {"en": "   "}},
		{"description": {"en": "x".repeat(4097)}}, {"syntax": "x".repeat(2049)},
		{"category_title": {"bad/locale": "Invalid key"}}, {"requirements": []},
		{"requirements": {"allow_loop": true}}, {"requirements": {"allow_tick": 1}},
		{"requirements": {"allow_random": 1}}, {"requirements": {"allow_for": 1}},
		{"requirements": {"module_behavior": ""}}, {"script": "res://should_not_load.gd"},
	]
	for index in changes.size():
		var bad := _entry("bad_%02d" % index, index)
		bad.merge(changes[index], true)
		_write_json(path.path_join("bad_%02d.json" % index), bad)
	_write_text(path.path_join("broken.json"), "{ invalid JSON")
	_write_text(path.path_join("array.json"), "[]")
	_write_text(path.path_join("oversized.json"), " ".repeat(CommandCatalog.MAX_FILE_BYTES + 1))
	var catalog := CommandCatalog.new()
	var loaded := catalog.load_directory(path)
	_check(not loaded.is_ok() and catalog.errors.size() == changes.size() + 3, "逐文件报告全部错误，不在首个错误处中止")
	_check(_ids(catalog) == ["valid"] and loaded.value.size() == 1, "所有坏文件之间仍保留有效资料")
	var errors_before := catalog.errors.duplicate()
	_check(catalog.sections(null) == catalog.sections(null), "坏文件不影响有效资料分组的稳定性")
	_check(catalog.search("标题 valid", null).size() == 1, "坏文件不遮蔽有效条目的全局搜索结果")
	_check(catalog.errors == errors_before, "分组与搜索不清除原始加载错误")
	for message in catalog.errors:
		_check(message.contains(path), "每条错误携带可定位的文件路径")
	for unsafe_path in ["user://../commands", "/tmp/commands", "res://", "user://bad\\commands"]:
		_check(not catalog.load_directory(unsafe_path).is_ok(), "无效目录不能加载：" + unsafe_path)
		_check(catalog.entries.is_empty(), "失败重载不能留下来自上个目录的旧条目")
	_check(not catalog.load_directory(_test_root.path_join("missing")).is_ok(), "缺失目录有明确错误而不是静默空菜单")


## 不依赖全局翻译服务；区域语言、缺少当前语种及单语扩展资料均有稳定回退。
func _test_localized_fallback() -> void:
	var entry := _entry("localized", 0)
	_check(CommandCatalog.localized(entry, "title", "zh-CN") == "标题 localized", "连字符中文区域键能匹配")
	_check(CommandCatalog.localized(entry, "title", "en_US") == "Title localized", "区域英文回退至通用英文")
	_check(CommandCatalog.localized(entry, "title", "zh_TW") == "标题 localized", "同中文语种回退至已有中文")
	_check(CommandCatalog.localized(entry, "title", "fr") == "标题 localized", "未知语种优先回退简体中文")
	entry.title = {"en_GB": "British English", "zh_CN": "中文"}
	_check(CommandCatalog.localized(entry, "title", "en-US") == "British English", "当前语种存在区域版本时先使用同语种")
	entry.title = {"en": "English only"}
	_check(CommandCatalog.localized(entry, "title", "zh_CN") == "English only", "单语英语资料仍可阅读")
	entry.title = {"ja": "日本語", "de": "Deutsch"}
	_check(CommandCatalog.localized(entry, "title", "fr") == "Deutsch", "没有中英文时使用按键排序的首个已有语种")
	_check(CommandCatalog.localized(entry, "missing", "en").is_empty(), "缺失字段安全返回空文本")
	_check(CommandCatalog.localized({"title": 42}, "title", "en").is_empty(), "非本土化对象不被强制转换成文案")


## 使用真实九关验证权限递进；自定义模块通过行为匹配，不按模块 ID 或关卡数字硬编码。
func _test_level_availability() -> void:
	var commands := CommandCatalog.new()
	_ok(commands.load_directory(), "解锁测试加载真实资料")
	var registry := ContentRegistry.new()
	_ok(registry.load_directories(), "解锁测试加载真实模块行为")
	var levels := LevelCatalog.new()
	levels.user_directory = _test_root.path_join("no_imports")
	_ok(levels.refresh(registry), "解锁测试加载全部真实关卡")
	_check(levels.levels.size() == 15, "解锁依据来自全部真实关卡")
	var first_available := {"main": 1, "move": 1, "attack": 3, "shoot": 4, "tick": 4, "named_calls": 5, "named_move": 5, "named_attack": 5, "named_shoot": 5, "loop": 6, "if_else": 7, "ready": 7, "simultaneously": 8, "distance": 9, "named_distance": 9, "functions": 11, "constants": 10, "variables": 10, "scan": 10, "named_scan": 10, "radar_angle": 10, "radar_position": 10, "radar_distance": 10, "radar_event": 15, "random": 10, "random_int": 10, "for_range": 12}
	for index in levels.levels.size():
		for entry in commands.entries:
			var expected: bool = levels.levels[index].order >= first_available[entry.id]
			if levels.levels[index].id == "level_010" and entry.id in ["attack", "named_attack", "distance", "named_distance"]:
				expected = false
			_check(CommandCatalog.is_available(entry, levels.levels[index], registry) == expected, "真实关卡 %d 的 %s 可用标记符合已实现权限" % [index + 1, entry.id])
	var by_id: Dictionary = {}
	for entry in commands.entries:
		by_id[entry.id] = entry
	var custom := LevelDefinition.new()
	custom.id = "level_007"
	custom.allowed_modules = PackedStringArray(["custom_gun"])
	var gun := ModuleDefinition.new()
	gun.id = "custom_gun"
	gun.behavior = "ShootingModule"
	registry.modules[gun.id] = gun
	_check(CommandCatalog.is_available(by_id.shoot, custom, registry), "自定义模块 ID 通过真实行为解锁射击")
	_check(not CommandCatalog.is_available(by_id.move, custom, registry), "没有允许移动模块时不误报可移动")
	_check(not CommandCatalog.is_available(by_id.ready, custom, registry), "关卡 ID 为第七关也不能绕过关闭的条件权限")
	custom.allow_conditionals = true
	_check(not CommandCatalog.is_available(by_id.ready, custom, registry), "冷却查询还需要具名调用权限")
	custom.allow_named_calls = true
	_check(CommandCatalog.is_available(by_id.ready, custom, registry), "具名、条件与射击能力同时满足后查询可用")
	custom.allowed_modules = PackedStringArray(["movement"])
	_check(CommandCatalog.is_available(by_id.if_else, custom, registry), "条件结构由独立权限开放；具体 ready 与 distance 查询另查模块能力")
	_check(not CommandCatalog.is_available(by_id.shoot, custom, null), "缺少注册表不能伪造模块能力")
	custom.id = "level_008"
	_check(not CommandCatalog.is_available(by_id.simultaneously, custom, registry), "第八关 ID 不会绕过默认关闭的并发权限")
	custom.allow_simultaneous = true
	_check(CommandCatalog.is_available(by_id.simultaneously, custom, registry), "并发资料由显式权限解锁，不依赖关卡编号或特定模块 ID")
	custom.id = "level_011"
	_check(not CommandCatalog.is_available(by_id.functions, custom, registry), "函数教程按独立开关锁定，不由关卡 ID 推测")
	_check(not CommandCatalog.is_available(by_id.variables, custom, registry), "函数关编号不会隐式启用变量资料")
	custom.allow_variables = true
	_check(CommandCatalog.is_available(by_id.constants, custom, registry) and CommandCatalog.is_available(by_id.variables, custom, registry), "常变量资料独立于函数、测距和条件权限")
	custom.allow_functions = true
	_check(CommandCatalog.is_available(by_id.functions, custom, registry), "函数说明只要求真实的函数解锁权限")
	_check(_entry_ids(_section_entries(commands.sections(registry), "radar", "module")) == ["scan", "named_scan", "radar_angle", "radar_position", "radar_distance", "radar_event"], "雷达目录包含扫描及目标快照资料")
	_check(not CommandCatalog.is_available(by_id.scan, custom, registry), "仅关卡编号和变量权限不能解锁雷达扫描")
	custom.allow_radar = true
	_check(not CommandCatalog.is_available(by_id.scan, custom, registry), "扫描开关还要求关卡允许真实雷达能力")
	custom.allowed_modules.append("radar")
	_check(CommandCatalog.is_available(by_id.scan, custom, registry), "雷达能力与独立开关同时启用后扫描可读")
	custom.allow_named_calls = false
	_check(not CommandCatalog.is_available(by_id.named_scan, custom, registry), "具名雷达资料单独检查命名权限")
	_check(CommandCatalog.is_available(by_id.radar_angle, custom, registry), "扫描结果成员不依赖具名模块调用权限")
	custom.allow_variables = false
	_check(not CommandCatalog.is_available(by_id.radar_position, custom, registry), "保存并读取目标位置的教学独立要求变量权限")
	_check(not CommandCatalog.is_available(by_id.random, custom, registry), "雷达与变量权限不能隐式解锁随机数")
	custom.allow_random = true
	custom.allowed_modules.clear()
	_check(CommandCatalog.is_available(by_id.random, custom, null) and CommandCatalog.is_available(by_id.random_int, custom, null), "随机函数仅依赖独立开关，不需要模块或注册表")
	custom.allow_random = false
	_check(not CommandCatalog.is_available(by_id.random_int, custom, registry), "关闭随机权限后区间整数资料也重新锁定")
	_check(not CommandCatalog.is_available(by_id.for_range, custom, registry), "其它语言功能不隐式解锁 for")
	custom.allow_for = true
	_check(CommandCatalog.is_available(by_id.for_range, custom, null), "for 资料仅要求独立权限，没有模块或常变量前置条件")
	_check(not CommandCatalog.is_available(by_id.main, null, registry), "没有当前关卡时不推断其可用性")
	_check(not CommandCatalog.is_available({"requirements": {"typo": true}}, custom, registry), "未知要求不能误标为已解锁")
	_check(CommandCatalog.is_available({"requirements": {"allow_tick": false}}, custom, registry), "false 要求不额外限制该关卡")


## 全部已加载模块都有独立目录，同一行为共用资料但不共享可改写的返回字典。
func _test_sections() -> void:
	GameI18n.install()
	var catalog := CommandCatalog.new()
	_ok(catalog.load_directory(), "分组测试加载真实资料")
	var registry := ContentRegistry.new()
	_ok(registry.load_directories(), "分组测试加载真实模块")
	var before := catalog.entries.duplicate(true)
	var groups := catalog.sections(registry, "zh_CN")
	_check(_entry_ids(groups) == ["general", "melee", "movement", "radar", "rangefinder", "shooting"], "基础在首位，模块按真实 ID 稳定排序")
	_check(_entry_ids(_section_entries(groups, "general")) == ["main", "tick", "named_calls", "loop", "if_else", "simultaneously", "functions", "constants", "variables", "random", "random_int", "for_range"], "程序结构和通用具名调用在编程基础")
	_check(_find_section(groups, "general").title == "编程基础", "编程基础有中文本土化名称")
	_check(_entry_ids(_section_entries(groups, "movement", "module")) == ["move", "named_move"], "移动目录包含广播和具名移动")
	_check(_entry_ids(_section_entries(groups, "melee", "module")) == ["attack", "named_attack"], "近战目录包含广播和具名攻击")
	_check(_entry_ids(_section_entries(groups, "shooting", "module")) == ["shoot", "named_shoot", "ready"], "射击目录包含广播、具名射击与查询")
	_check(_entry_ids(_section_entries(groups, "rangefinder", "module")) == ["distance", "named_distance"], "测距目录包含普通与具名查询")
	for module_id: String in registry.modules:
		var section := _find_section(groups, module_id, "module")
		_check(section.get("title") == registry.get_module(module_id).display_name, "模块目录读取真实模块名称")
		_check(section.get("texture") == registry.get_module(module_id).texture, "模块目录读取真实 SVG 路径")
	var empty := ModuleDefinition.new()
	empty.id = "unused"
	empty.display_name = "尚无资料的模块"
	empty.behavior = "FutureModule"
	registry.modules[empty.id] = empty
	var twin := ModuleDefinition.new()
	twin.id = "general"
	twin.display_name = "另一种驱动"
	twin.behavior = "MovementModule"
	registry.modules[twin.id] = twin
	groups = catalog.sections(registry)
	_check(groups.size() == registry.modules.size() + 1, "暂无资料和名为 general 的模块都没有被漏掉")
	_check(_section_entries(groups, "unused", "module").is_empty(), "暂无资料的已加载模块仍显示空目录")
	_check(_entry_ids(_section_entries(groups, "general", "module")) == ["move", "named_move"], "同一移动行为的自定义模块自动获得全部移动资料")
	_check(_entry_ids(_section_entries(groups, "general", "general")) == ["main", "tick", "named_calls", "loop", "if_else", "simultaneously", "functions", "constants", "variables", "random", "random_int", "for_range"], "kind 区分基础目录与同 ID 的真实模块")
	_section_entries(groups, "general", "module")[0].description.zh_CN = "只改这个快照"
	_check(_section_entries(groups, "movement", "module")[0].description.zh_CN != "只改这个快照", "同一指令在两个模块分组中的副本互相隔离")
	_check(catalog.entries == before, "修改分组快照不改变原始指令资料")
	var without_registry := catalog.sections(null)
	_check(without_registry.size() == 1 and _section_entries(without_registry, "general").size() == catalog.entries.size(), "缺少注册表时未匹配行为的资料仍可阅读")
	var global_locale := TranslationServer.get_locale()
	var english := catalog.sections(registry, "en_US")
	_check(_find_section(english, "general").title == "Programming Basics", "指定区域英文可读取基础目录名")
	_check(_find_section(english, "movement", "module").title == "Movement Module", "模块目录使用游戏原有英文翻译")
	_check(_find_section(english, "general", "module").title == "另一种驱动", "自定义名称没有翻译时保留作者原文")
	_check(TranslationServer.get_locale() == global_locale, "读取另一语言的目录不会切换全局语言")
	_check(registry.get_module("movement").display_name == "移动模块", "本土化目录不改写模块原始名称")


## 搜索跨全部目录与完整说明，不依赖当前展开项，并保留可定位的模块归属。
func _test_global_search() -> void:
	var catalog := CommandCatalog.new()
	_ok(catalog.load_directory(), "搜索测试加载真实资料")
	var registry := ContentRegistry.new()
	_ok(registry.load_directories(), "搜索测试加载真实模块")
	var before := catalog.entries.duplicate(true)
	var moves := catalog.search("  移动 \n", registry, "zh_CN")
	_check("move" in _entry_ids(moves) and "named_move" in _entry_ids(moves), "移动关键词匹配移动指令标题")
	_check("named_calls" in _entry_ids(moves), "通用具名调用仅在完整说明出现移动仍能搜到")
	_check(_entry_ids(catalog.search("路径", registry)) == ["move", "distance"], "只在描述中出现的路径关键词可以命中")
	_check(_entry_ids(catalog.search("  NaMeD MeLeE AtTaCk  ", registry, "en")) == ["named_attack"], "英文标题搜索忽略首尾空白和大小写")
	_check(_entry_ids(catalog.search("  MODULE.MOVE(  ", registry, "en")) == ["named_calls", "named_move"], "语法模板也参与全局搜索且忽略大小写")
	_check(_entry_ids(catalog.search("同一模块", registry, "zh_CN")) == ["simultaneously"], "新增并发资料可按中文功能描述跨目录检索")
	_check(_entry_ids(catalog.search("projectile speed", registry, "en")) == ["simultaneously"], "新增并发资料可按英文功能描述检索")
	_check(_entry_ids(catalog.search("randomInt(", registry)) == ["random_int"], "区间随机函数按准确语法可以检索")
	_check(_entry_ids(catalog.search("随机", registry)) == ["random", "random_int"], "两个随机函数都能按中文检索")
	_check(catalog.search("randomInt(", registry)[0].section_id == "general", "无模块随机函数列入编程基础目录")
	_check(catalog.search("肯定不存在的搜索词", registry).is_empty(), "未匹配关键词返回空结果")
	_check(catalog.search("移动", registry, "en").is_empty(), "英文搜索只匹配正在展示的语言，不混入隐藏中文")
	_check(catalog.search(" \t ", registry).size() == catalog.entries.size(), "纯空白查询返回所有目录中的条目")
	var move := catalog.search("路径", registry)[0]
	_check(move.section_id == "movement" and move.section_kind == "module" and move.section_title == "移动模块", "搜索条目明确保留实际模块归属")
	_check(move.section_texture == registry.get_module("movement").texture, "搜索条目保留所属模块 SVG 路径")
	move.title.zh_CN = "改动搜索结果"
	_check(catalog.entries == before, "搜索结果为深拷贝，外部改动不污染原始资料")
	for entry in catalog.entries:
		_check(not entry.has("section_title") and not entry.has("section_id"), "搜索归属字段不会写入原始条目")


## 新 JSON 与新模块在重新扫描后自动参与分组和搜索，坏资料不会使结果次序漂移。
func _test_dynamic_sections_and_search() -> void:
	var path := _test_root.path_join("dynamic_commands")
	var first := _entry("description_match", 10)
	first.description.zh_CN = "控制机器人移动一段距离"
	first.category = "action"
	first.requirements = {"module_behavior": "MovementModule"}
	_write_json(path.path_join("10_description.json"), first)
	var catalog := CommandCatalog.new()
	_ok(catalog.load_directory(path), "动态分组加载只含描述关键词的资料")
	var registry := ContentRegistry.new()
	_ok(registry.load_directories(), "动态分组加载生产模块")
	_check(_entry_ids(catalog.search("移动", null)) == ["description_match"], "标题、语法及基础目录名均不含移动时仍按描述命中")
	var module_path := _test_root.path_join("dynamic_modules")
	var custom: Dictionary = registry.get_module("movement").raw.duplicate(true)
	custom.id = "whale_drive"
	custom.name = "蓝鲸推进器"
	_write_json(module_path.path_join("whale.json"), custom)
	_ok(registry.load_directories(PackedStringArray(["res://data/modules", module_path])), "新增模块 JSON 通过正式注册表加载")
	var groups := catalog.sections(registry)
	_check(_entry_ids(_section_entries(groups, "whale_drive", "module")) == ["description_match"], "新增模块按行为自动出现对应资料")
	var module_matches := catalog.search("  蓝鲸推进器  ", registry)
	_check(module_matches.size() == 1 and module_matches[0].section_id == "whale_drive", "模块名称命中本模块的所有指令而不串到同能力模块")
	_check(_entry_ids(catalog.search("移动", registry)) == ["description_match", "description_match"], "同能力的两个模块都显示搜索结果并各自带归属")
	var second := _entry("added_later", 20)
	second.category = "query"
	second.requirements = {"module_behavior": "MovementModule"}
	_write_json(path.path_join("20_added.json"), second)
	_write_text(path.path_join("30_bad.json"), "{ broken")
	_check(not catalog.load_directory(path).is_ok(), "新增 JSON 和损坏 JSON 一起扫描时报告错误")
	_check(_entry_ids(_section_entries(catalog.sections(registry), "whale_drive", "module")) == ["description_match", "added_later"], "新增有效 JSON 自动扩充新旧模块的目录")
	var found := catalog.search("蓝鲸推进器", registry)
	_check(_entry_ids(found) == ["description_match", "added_later"], "模块名称能搜到其全部最新指令")
	_check(found == catalog.search("蓝鲸推进器", registry), "坏资料存在时重复搜索的有效结果保持稳定")
	DirAccess.remove_absolute(path.path_join("10_description.json"))
	DirAccess.remove_absolute(path.path_join("30_bad.json"))
	_ok(catalog.load_directory(path), "删除坏资料和旧条目后正常重载")
	_check(_entry_ids(catalog.search("蓝鲸推进器", registry)) == ["added_later"], "删除资料后的分组与搜索不会保留旧缓存")
	registry.modules.erase("whale_drive")
	_check(catalog.search("蓝鲸推进器", registry).is_empty(), "移除模块后其目录归属及模块名搜索立即消失")


## 根据目录类型和真实 ID 查找，避免合法模块 general 与基础目录重名时混淆。
func _find_section(groups: Array[Dictionary], id: String, kind: String = "general") -> Dictionary:
	for section in groups:
		if section.id == id and section.kind == kind:
			return section
	return {}


## 读取目录中的资料列表，缺失目录返回空数组便于断言有效集合。
func _section_entries(groups: Array[Dictionary], id: String, kind: String = "general") -> Array:
	return _find_section(groups, id, kind).get("entries", [])


## 提取任意资料或目录快照的 ID，保持原顺序以检查分组与搜索稳定性。
func _entry_ids(values: Array) -> Array[String]:
	var ids: Array[String] = []
	for value: Dictionary in values:
		ids.append(value.id)
	return ids


## 创建格式完整的独立资料，用于动态添加及坏字段测试。
func _entry(id: String, order: int) -> Dictionary:
	return {
		"format_version": 1, "id": id, "order": order, "category": "structure",
		"category_title": {"zh_CN": "程序结构", "en": "Program Structure"},
		"title": {"zh_CN": "标题 " + id, "en": "Title " + id},
		"description": {"zh_CN": "只读说明", "en": "Read-only reference"},
		"syntax": "example(...)" , "requirements": {},
	}


## 将条目 ID 转为普通数组，便于检查排序和动态增删后的可见集合。
func _ids(catalog: CommandCatalog) -> Array[String]:
	var ids: Array[String] = []
	for entry in catalog.entries:
		ids.append(entry.id)
	return ids


## 测试 JSON 只写到当前独占目录，不修改生产指令资料。
func _write_json(path: String, data: Dictionary) -> void:
	_write_text(path, JSON.stringify(data, "\t") + "\n")


## 保存任意测试文本，允许构造语法损坏和超限文件。
func _write_text(path: String, source: String) -> void:
	if not _check(path.begins_with(_test_root + "/"), "写入范围限制在独占测试目录"):
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if _check(file != null, "独占测试文件可以写入"):
		file.store_string(source)
		file.close()


## 仅清理独占测试树，链接自身可删除但不递归进入任何链接目标。
func _remove_test_tree(path: String) -> void:
	if _test_root.is_empty() or not (path == _test_root or path.begins_with(_test_root + "/")):
		return
	var folder := DirAccess.open(path)
	if folder == null:
		return
	folder.include_hidden = true
	folder.list_dir_begin()
	var filename := folder.get_next()
	while not filename.is_empty():
		var child := path.path_join(filename)
		if folder.is_link(filename) or not folder.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_remove_test_tree(child)
		filename = folder.get_next()
	folder.list_dir_end()
	DirAccess.remove_absolute(path)


## 成功断言带回底层错误，便于定位资料文件及字段。
func _ok(result: DataResult, message: String) -> void:
	_check(result != null and result.is_ok(), message + ("；" + "; ".join(result.errors) if result != null else "；缺少结果"))


## 累计独立检查，最后向完整测试脚本返回明确的失败状态。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
