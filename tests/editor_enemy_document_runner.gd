extends SceneTree
## 敌人编辑文档的配置、放置、撤销和序列化回归；测试文件只写独立用户子目录。

var _checks := 0
var _failures := 0
var _content := ContentRegistry.new()
var _temporary := ""


## 等待注册类可用后开始纯数据回归。
func _initialize() -> void:
	_run.call_deferred()


## 按数据生命周期检查成功及失败路径，不实例化任何编辑器界面。
func _run() -> void:
	_temporary = "user://tests/enemy_document_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(_content.load_directories().is_ok(), "真实模块内容可加载")
	_test_defaults_and_settings()
	_test_validation()
	_test_placement_and_history()
	_test_footprints()
	_test_serialization()
	_cleanup(_temporary)
	print("地图敌人文档回归完成：%d 项检查，%d 项失败。" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


## 建立已保存的全地板夹具，并保留其他作者元数据以检查扩展往返。
func _model() -> MapEditorDocument:
	var document := MapDocument.new()
	document.width = 16
	document.height = 12
	for y in document.height:
		for x in document.width:
			document.set_tile(Vector2i(x, y), "floor")
	document.player_spawn = {"position": {"x": 1.5, "y": 1.5}, "modules": [{"id": "drive", "module_id": "movement", "offset": {"x": 0, "y": 0}}]}
	document.properties = {"level": {"module_limit": 3, "player_max_health": 7.0}, "editor": {"other_tool": {"keep": 42}}, "custom": [1, 2, 3]}
	var model := MapEditorDocument.new()
	model.replace_document(document)
	return model


## 返回可独立修改的双模块模板，空槽不进入持久化清单。
func _config() -> Dictionary:
	return {"module_limit": 4, "module_health": 2.8, "module_ids": ["movement", "melee"]}


## 旧地图读默认值不变脏；开关仅更新规则，并完整支持历史操作。
func _test_defaults_and_settings() -> void:
	var model := _model()
	_check(not model.get_enemies_enabled(), "空地图无显式flag时编辑器默认关闭")
	var config := model.get_enemy_template(_content)
	_check(config.module_limit == 1 and config.module_health == 1 and config.module_ids == ["movement"], "默认一模块一耐久并选择真实移动能力")
	config.module_ids.clear()
	_check(model.get_enemy_template(_content).module_ids == ["movement"] and not model.is_dirty(), "读取和修改返回副本均不改变文档")
	_check(model.set_enemies_enabled(true).is_ok() and model.get_enemies_enabled(), "开关启用可作为一次文档修改")
	_check(model.document.properties.level.player_max_health == 7 and model.document.properties.editor.other_tool.keep == 42, "开关保留关卡和编辑器扩展")
	_check(model.undo() and not model.get_enemies_enabled() and not model.is_dirty(), "撤销开关恢复保存点")
	_check(model.redo() and model.get_enemies_enabled(), "重做开关恢复启用")
	var history := model._undo_stack.size()
	model.set_enemies_enabled(true)
	_check(history == model._undo_stack.size(), "相同开关不增加撤销")
	_check(model.set_enemy_template(_config(), _content).is_ok(), "数量是上限，组合可少于上限")
	_check(model.get_enemy_template(_content).module_ids == ["movement", "melee"], "组合保存选择顺序")
	model.document.properties.editor.enemy_template["author_note"] = {"keep": true}
	_check(model.set_enemy_template({"module_limit": 2, "module_health": 3.0, "module_ids": ["melee"]}, _content).is_ok(), "允许没有移动能力的静止敌人组合")
	_check(model.document.properties.editor.enemy_template.author_note.keep, "模板修改保留未知扩展")
	model.document.properties.level = "bad"
	var before := model.document.to_dict()
	_check(not model.set_enemies_enabled(false).is_ok() and before == model.document.to_dict(), "不覆盖损坏的level数据")
	model.document.properties.editor = "bad"
	before = model.document.to_dict()
	_check(not model.set_enemy_template(_config(), _content).is_ok() and before == model.document.to_dict(), "不覆盖损坏的editor数据")


## 配置边界在模型、JSON保存和直接构造入口采用同一明确类型校验。
func _test_validation() -> void:
	var model := _model()
	var before := model.document.to_dict()
	for value: Variant in [0, 257, 1.5, true, "3", INF]:
		var config := _config()
		config.module_limit = value
		_check(not model.set_enemy_template(config, _content).is_ok(), "拒绝非法敌人数上限 " + str(value))
	for value: Variant in [0, -1, 0.001, 1000001, false, "1", INF, NAN]:
		var config := _config()
		config.module_health = value
		_check(not model.set_enemy_template(config, _content).is_ok(), "拒绝非法敌人耐久 " + str(value))
	for value: Variant in [[], ["missing"], [null], [true], "movement", ["movement", "melee", "movement", "melee", "movement"]]:
		var config := _config()
		config.module_ids = value
		_check(not model.set_enemy_template(config, _content).is_ok(), "拒绝空、未知或超限组合 " + str(value))
	_check(before == model.document.to_dict() and not model.is_dirty() and not model.can_undo(), "全部失败路径不改写数据或撤销栈")
	for value: Variant in [1, "true", null]:
		var document := _model().document
		document.properties.level.enemies_enabled = value
		_check(not MapCodec.validate(document, _content, false).is_ok(), "地图JSON拒绝非bool启用值 " + str(value))
	var document := _model().document
	document.properties.editor.enemy_template = {"module_limit": 2, "module_health": 2.0, "module_ids": ["missing"]}
	_check(not MapCodec.validate(document, _content, false).is_ok(), "保存校验也拒绝坏模板引用")
	document.properties.editor.enemy_template = _config()
	_check(MapCodec.validate(document, _content, false).is_ok(), "有效模板通过地图格式校验")
	var config := _config()
	config.module_limit = 256
	config.module_health = 1000000
	_check(MapValidation.check_enemy_template(config, _content).is_ok(), "敌人数与耐久最大边界可用")
	config.module_health = 0.01
	_check(MapValidation.check_enemy_template(config, _content).is_ok(), "耐久最小边界可用")
	_check(not MapEditorEnemyTemplate.build_entry(config, Vector2(2.1, 2), _content).is_ok(), "非半格落点不可生成敌人")
	_check(not MapEditorEnemyTemplate.build_entry(config, Vector2(INF, 2), _content).is_ok(), "非有限落点不可生成敌人")


## 原子放置一次只产生一个敌人和一个历史项，模板与敌人的耐久互不共享。
func _test_placement_and_history() -> void:
	var model := _model()
	_check(not model.place_enemy(Vector2(5, 5), _content).is_ok() and not model.is_dirty(), "关闭开关不能放置且不改变保存点")
	model.set_enemies_enabled(true)
	model.set_enemy_template(_config(), _content)
	model.document.objects.append({"id": "enemy_1", "type": "annotation", "position": {"x": 0.0, "y": 0.0}})
	var history := model._undo_stack.size()
	var placed := model.place_enemy(Vector2(5, 5), _content)
	if not _check(placed.is_ok(), "首个有效敌人可放置"):
		return
	_check(model.document.enemies.size() == 1 and model._undo_stack.size() == history + 1, "单次放置原子记录历史")
	var enemy: Dictionary = model.document.enemies[0]
	_check(enemy.id == "enemy_2", "敌人ID避开对象ID")
	_check(enemy.behavior == "auto_chase_attack" and enemy.position == {"x": 5.0, "y": 5.0}, "自动行为及点击中心正确")
	_check(enemy.modules[0].offset == {"x": 0.0, "y": 0.0} and enemy.modules[1].offset == {"x": 0.5, "y": 0.0}, "真实半格模块依序共边")
	_check(enemy.properties.module_health == {"module_1": 2.8, "module_2": 2.8}, "每个实例均得到独立耐久覆盖")
	_check(model.undo() and model.document.enemies.is_empty(), "一次撤销移除完整组合")
	_check(model.redo() and model.document.enemies[0] == enemy, "一次重做恢复完整组合与ID")
	var second := model.place_enemy(Vector2(5, 7), _content)
	_check(second.is_ok() and second.value.id == "enemy_3", "重复放置生成唯一敌人ID")
	var changed := _config()
	changed.module_health = 9.0
	changed.module_ids = ["shooting"]
	model.set_enemy_template(changed, _content)
	_check(model.document.enemies[0] == enemy, "修改模板不改已放置敌人")
	placed.value.modules[0].offset.x = 100
	placed.value.properties.module_health.module_1 = 123
	_check(model.document.enemies[0] == enemy, "返回敌人副本不暴露文档的可变引用")
	_check(_content.get_module("movement").properties.get("max_health", 1.0) == 1.0 and model.document.properties.level.player_max_health == 7.0, "敌人耐久不污染共享定义或玩家耐久")
	var preserved := model.document.enemies.duplicate(true)
	model.set_enemies_enabled(false)
	_check(not model.get_enemies_enabled() and model.document.enemies == preserved, "关闭保留位置、模块和耐久")
	_check(not model.place_enemy(Vector2(5, 9), _content).is_ok() and model.document.enemies == preserved, "关闭后实际放置仍被拒绝")
	_check(model.undo() and model.get_enemies_enabled() and model.document.enemies == preserved, "撤销关闭恢复运行开关而无需重建敌人")
	model.document.properties.level.erase("enemies_enabled")
	_check(model.get_enemies_enabled(), "含旧敌人的地图无flag时编辑器默认开启")


## 无效落点包括首件、后续模块悬空与整机重叠；正好共边仍允许放置。
func _test_footprints() -> void:
	var model := _model()
	model.set_enemies_enabled(true)
	model.set_enemy_template(_config(), _content)
	var before := model.document.to_dict()
	for point: Vector2 in [Vector2.ZERO, Vector2(15.5, 5), Vector2(16, 5), Vector2(1.5, 1.5)]:
		_check(not model.place_enemy(point, _content).is_ok(), "拒绝越界/玩家占地 " + str(point))
	_check(model.document.to_dict() == before, "越界拒绝不改文档")
	model.document.set_tile(Vector2i(6, 5), "")
	_check(not model.place_enemy(Vector2(5.5, 5.5), _content).is_ok(), "首件在地板但第二件进入void时拒绝")
	model.document.set_tile(Vector2i(6, 5), "iron_fence")
	_check(not model.place_enemy(Vector2(5.5, 5.5), _content).is_ok(), "铁栅栏不是可通行地板")
	model.document.set_tile(Vector2i(6, 5), "floor")
	_check(model.place_enemy(Vector2(5, 5), _content).is_ok(), "恢复支撑后可放置")
	before = model.document.to_dict()
	_check(not model.place_enemy(Vector2(5.5, 5), _content).is_ok() and before == model.document.to_dict(), "不可与另一敌人的任一模块重叠")
	_check(model.place_enemy(Vector2(6, 5), _content).is_ok(), "整机之间正好共边允许")
	model.document.objects.append({"id": "rock", "type": "destructible", "size": 1.0, "position": {"x": 10.0, "y": 5.0}, "properties": {"max_health": 1.0}})
	_check(not model.place_enemy(Vector2(9.5, 5), _content).is_ok(), "后续模块不得与障碍物重叠")
	model.document.objects.append({"id": "gate", "type": "timed_gate", "size": 1.0, "position": {"x": 10.0, "y": 8.0}, "properties": {"close_after_ticks": 10}})
	_check(not model.place_enemy(Vector2(10, 8), _content).is_ok(), "闸门占地预留，防止初始敌人被关闭夹住")
	var wide := ModuleDefinition.new()
	wide.id = "wide_drive"
	wide.behavior = "MovementModule"
	wide.size = Vector2(1.5, 1.0)
	wide.properties = {"move_speed": 1.0}
	_content.modules[wide.id] = wide
	var config := {"module_limit": 3, "module_health": 2.0, "module_ids": ["wide_drive", "movement", "wide_drive"]}
	var built := MapEditorEnemyTemplate.build_entry(config, Vector2(5, 10), _content)
	_check(built.is_ok() and built.value.modules[1].offset.x == 1.0 and built.value.modules[2].offset.x == 2.0, "异形模块按真实宽度共边而非固定半格偏移")
	_check(MapEditorEnemyTemplate.validate_placement(built.value, model.document, _content).is_ok(), "异形真实占地可放置")
	model.document.set_tile(Vector2i(7, 10), "")
	_check(not MapEditorEnemyTemplate.validate_placement(built.value, model.document, _content).is_ok(), "异形末件部分悬空也会拒绝")
	_content.modules.erase(wide.id)


## 地图写盘、加载、开关关闭和保存点重做均保留完整敌人与编辑模板。
func _test_serialization() -> void:
	var model := _model()
	model.set_enemies_enabled(true)
	model.set_enemy_template(_config(), _content)
	model.place_enemy(Vector2(6, 6), _content)
	model.set_enemies_enabled(false)
	DirAccess.make_dir_recursive_absolute(_temporary)
	var path := _temporary.path_join("enemies.json")
	var saved := MapCodec.save_file(model.document, path, _content, false)
	if not _check(saved.is_ok(), "关闭敌人的文档和模板仍可保存"):
		return
	model.mark_saved(path)
	var loaded := MapCodec.load_file(path, _content, false)
	if not _check(loaded.is_ok(), "保存的敌人文档可以重新载入"):
		return
	var restored := MapEditorDocument.new()
	restored.replace_document(loaded.value, path)
	_check(not restored.get_enemies_enabled() and restored.document.enemies.size() == 1, "重载保留关闭开关和已放置敌人")
	var config := restored.get_enemy_template(_content)
	_check(int(config.module_limit) == 4 and is_equal_approx(float(config.module_health), 2.8) and config.module_ids == ["movement", "melee"], "模板数量耐久与选择顺序完整往返")
	_check(restored.document.properties.custom.size() == 3 and restored.document.properties.custom[0] == 1 and restored.document.properties.custom[2] == 3 and restored.document.properties.editor.other_tool.keep == 42, "其他元数据往返不丢失")
	_check(not restored.is_dirty(), "加载后无隐式修改")
	restored.set_enemy_template(_config(), _content)
	_check(not restored.is_dirty() and not restored.can_undo(), "重载后提交等值整数不改变JSON数值表示或历史")
	restored.set_enemies_enabled(true)
	_check(restored.undo() and not restored.is_dirty(), "撤销回保存的禁用状态恢复clean")
	_check(restored.redo() and restored.is_dirty(), "重做回启用状态仍正常追踪dirty")


## 清理本测试创建的文件，不接触玩家的地图与设置。
func _cleanup(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var folder := DirAccess.open(path)
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


## 聚合失败但继续检查，输出可用于测试脚本的确定性退出码。
func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
