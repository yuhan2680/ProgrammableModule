class_name WorkbenchProgramGuide
extends RefCounted
## 系统程序说明仅生成展示页；用户地图的引导、语言和存档数据保持独立。


## 沿用工作台原有能力优先级，选取当前关卡对应的简短程序规则。
static func entry_text(level: LevelDefinition) -> String:
	var text := "main() 执行一次；tick() 每 0.1 秒调用一次。" if level.allow_tick else "程序从 main() 开始，依次执行每条指令。"
	if level.allow_loops:
		text = "loop { ... } 按顺序重复块内指令，直到关卡结束。"
	if level.allow_conditionals:
		text = "if / else 根据射击是否就绪，选择不同动作。"
	if level.allow_simultaneous:
		text = "同步启动多个动作，全部完成后继续执行。"
	if level.allow_distance:
		text = "distance(角度) 测量前方距离，边探路边移动。"
	if level.allow_radar and level.goal_type == "destroy_enemy":
		text = "反复扫描敌人，在射击冷却期间追近，再重新瞄准。"
	if level.allow_functions:
		text = "把检测与闪避写进 function，再从 main() 调用。"
	if level.allow_for:
		text = "for 按步长遍历角度，用一组指令检查不同方向。"
	if level.id == "level_013":
		text = "用 scan() 锁定目标，再将 Angle() 交给射击模块。"
	if level.id == "level_014":
		text = "移动中反复 scan()，发现敌人后用 Angle() 瞄准射击。"
	if level.allow_radar_events:
		text = "使用 onDetected 绑定目标变量，再从 main() 中判断并射击。"
	if level.id == "level_016":
		text = "distance(角度) 测量前方距离，边探路边移动。"
	return text


## 返回独立的系统末页；显示方负责翻译，不能把系统页写回地图引导。
static func page(level: LevelDefinition) -> Dictionary:
	return {"speaker": "程序", "text": entry_text(level), "format": "plain"}
