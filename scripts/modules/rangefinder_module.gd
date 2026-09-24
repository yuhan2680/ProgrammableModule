class_name RangefinderModule
extends ModuleBehavior
## 测距模块只提供查询能力；实际射线交点由纯数据世界计算，不自行推进时间。


## 能力跟随实际部件的可用状态；返回新字典，不暴露静态配置供外部修改。
func get_rangefinder_profile(module: ModuleInstance) -> Dictionary:
	return {"origin": "module_center"} if module.available else {}
