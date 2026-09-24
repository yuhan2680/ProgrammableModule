class_name PlayfieldCanvas
extends MapCanvas
## 复用地图绘制并叠加目标标记；目标是关卡数据，不增加新的地块类型。

var level: LevelDefinition


## 在实际地图之上标记起点与目标，显示位置与模拟使用同一地图坐标。
func _draw() -> void:
	super._draw()
	if level == null or document == null:
		return
	var start: Dictionary = level.document.player_spawn.position
	var start_position := Vector2(float(start.x), float(start.y)) * cell_size
	draw_arc(start_position, cell_size * 0.31, 0, TAU, 32, Color("907AC5"), 2.0, true)
	if level.goal_type in ["reach_position", "escape_prison", "escape_alarms"]:
		var center := level.goal_position * cell_size
		draw_circle(center, maxf(7.0, level.goal_radius * cell_size), Color(0.39, 0.88, 0.77, 0.22))
		draw_arc(center, cell_size * 0.36, 0, TAU, 48, GameTheme.SUCCESS, 2.5, true)
		draw_line(center + Vector2(-5, 0), center + Vector2(-1, 4), GameTheme.SUCCESS, 2.0, true)
		draw_line(center + Vector2(-1, 4), center + Vector2(7, -5), GameTheme.SUCCESS, 2.0, true)

	# 缩小大地图时模块只有数像素；额外标记只表示机器中心，不扩大真实碰撞占地。
	if cell_size < 16.0 and world != null and not world.player.is_destroyed():
		var player_center := world.player.position * cell_size
		draw_circle(player_center, 5.5, Color.WHITE)
		draw_arc(player_center, 5.5, 0, TAU, 32, GameTheme.ACCENT, 2.0, true)
		draw_circle(player_center, 2.0, GameTheme.ACCENT)
