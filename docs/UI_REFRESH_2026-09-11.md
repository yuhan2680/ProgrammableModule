# 圆角界面与三关更新 · 2026-09-11

本轮以用户重新设计的桌面工程为基础，未复制旧 Alpha 的底层。用户确认按现有能力重做三关，使用既有的 `main()`、`move`、速度叠加和实际模块占地。

## 外观

- 浅灰背景、白色圆角卡片、蓝色主要操作、柔和阴影。
- 主菜单保留开始、地图编辑器、设置和退出四个入口；选关页保留 JSON 导入。
- 独立装配页使用目录、网格和属性分区，仍从空装配开始，确认和运行使用原有校验。
- 编程页保留编辑模块、运行、暂停/继续、停止、重置、草稿保存、行号、错误定位与组装页签。
- 地图编辑器采用工具栏、画布和可滚动的属性侧栏，保留所有编辑、元数据和试玩操作。
- 中英切换、主音量、草稿恢复、完成记录与编辑器试玩隔离均沿用现有实现。

## 关卡

1. 初次移动：保留起点 (1.5, 7.5) 与终点 (5.5, 1.5)，S 路线改为右 4、上 3、左 4、上 3、右 4。
2. 双驱动长廊：向右 8 格。一个模块 80 tick，横向双模块 40 tick；没有额外的倒计时或关门规则。
3. 窄道转弯：建议安装偏移 (0, 0)、(0.5, 0) 的横向双模块。参考路线为右 1.75、上 6、右 6.25。忽略第二个模块的占地、直接右移 2 格后向上，会被现有碰撞系统阻挡。

第二、三关允许玩家使用一个模块探索，仍按原来的终点条件判断胜负。开始程序只提供局部示例，完整路线可从“关卡说明”查看。

第一关使用原来的 ID，原玩家草稿与进度没有删除；旧程序中的上行距离需按新地图调整。地图文件格式、模块定义数值、Schema 和用户数据目录均未迁移。

## 维护

- 颜色、字体、常见控件状态：`scripts/ui/game_theme.gd`。
- 主菜单与圆角关卡卡片：`scripts/ui/game_shell.gd`。
- 地图与模块 SVG：`assets/tiles/floor.svg`、`assets/modules/movement.svg`。
- 主菜单插画与控件图标：`assets/ui/`，均为项目自行绘制的 SVG。
- 三个关卡继续使用 `data/levels/*.json`，编辑器样例继续放在 `data/maps/`。
- 新增函数均附中文用途注释。新增三关和布局回归不修改底层运行规则。

## 素材许可

界面只是参考 iOS 18 的简洁圆角设计，未使用 Apple 字体、图标或系统素材。

| 字体 | 来源 | 随附许可 |
| --- | --- | --- |
| Noto Sans SC | [Google Fonts](https://github.com/google/fonts/tree/main/ofl/notosanssc) | `assets/fonts/NotoSansSC-OFL.txt` |
| JetBrains Mono | [Google Fonts](https://github.com/google/fonts/tree/main/ofl/jetbrainsmono) | `assets/fonts/JetBrainsMono-OFL.txt` |

两种字体均采用 SIL Open Font License 1.1。SVG 为本轮绘制，不新增第三方运行依赖。

## 验证

运行 `python3 tools/test.py --godot /path/to/Godot`，或使用现有的 `tools/test.ps1`。包装器同时检查退出码、完成标记与引擎错误，不能只看进程是否返回 0。

本轮使用 Godot 4.5.1 Standard / macOS 无界面运行，实际 UI 通过同一工程的 Godot WebGL 导出副本检查。Web 副本仅作视觉验证，不随工程交付，也不用于替代桌面文件系统的地图导入与保存。本轮没有验证原生桌面发布包或 Godot 4.7 运行。

本轮完整验证结果为 964 项全部通过，详见 [验证记录](VALIDATION.md)。
