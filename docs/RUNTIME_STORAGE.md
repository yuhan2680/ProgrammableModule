# 缓存与游戏进度保存位置

正式 macOS / Windows 游戏将玩家作品与运行记录放在同一个可见的 `ProgrammableModule` 目录内，目录名称大小写固定：

| 内容 | macOS | Windows |
| --- | --- | --- |
| 玩家制作、导入及分享的地图 | `~/Documents/ProgrammableModule/saves/` | `%USERPROFILE%\ProgrammableModule\saves\` |
| 代码、装配草稿与恢复备份 | `~/Documents/ProgrammableModule/Cache/` | `%USERPROFILE%\ProgrammableModule\Cache\` |
| 通关状态、提示失败门槛与玩家档案 | `~/Documents/ProgrammableModule/Progress/` | `%USERPROFILE%\ProgrammableModule\Progress\` |

macOS 使用系统 Documents 或沙盒中经原生选择器授权的真实文稿目录；Windows 使用当前用户的 `USERPROFILE`，不转到 Documents，也不硬编码用户名或盘符。其他平台保留 `user://` 下的兼容目录。位置解析及 macOS 授权与 [玩家关卡保存位置](PLAYER_SAVE_LOCATION.md) 共用规则。

## 文件职责

`Cache` 保存 `<关卡ID的SHA-256>.draft.json` 及 `.draft.recovery.*.json`，包含玩家源码和可恢复装配。虽然目录名为 Cache，这些文件仍是玩家作品；普通启动不会清空它们。

`Progress` 保存 `<关卡ID的SHA-256>.progress.json`，包含通关标记和连续失败计数；`player_profile.json` 保存 UID、用户名、统计、彩蛋记录及本机首次运行日期。保存代码不会清除完成状态，删除玩家档案不清除关卡进度；原有「清除预设进度」仍只处理当前教学关卡对应的草稿、恢复备份和进度记录。

设置、背景图片副本及系统授权继续放在 `user://`，迁移检查点的主记录也留在此处，另在 `Progress` 内保留一份防重复导入标记。这些文件不是可以随意清除的临时缓存。开发工程中的 `.godot` 是引擎导入和编辑缓存，不保存玩家的个人通关状态，本次不迁移它。代码/装配草稿与个人进度均不写回 `res://` 或应用安装目录。

## 首次升级迁移

旧版草稿、恢复备份和进度来自 `user://solutions/`，旧档案来自 `user://player_profile.json`。普通导出的旧 `user://` 位置通常为：

- macOS：`~/Library/Application Support/Godot/app_userdata/ProgrammableModule/`。
- Windows：`%APPDATA%\Godot\app_userdata\ProgrammableModule\`。

沙盒版按当前应用可访问的容器解析，不能跨用户或跨容器猜测历史数据。`PlayerRuntimeMigration` 在首次可访问新目录时自动复制已知文件名，保留原始字节和旧原件；坏 JSON 也先原样保留，再交给实际读取模型报告问题。目标已存在的文件优先，不用旧内容覆盖新记录。不扫描未知 JSON 或子目录，不把内置关卡或参考答案当作个人进度。

复制使用同目录临时文件、摘要核对和最终提交；完整迁移后才写入完成检查点。`user://runtime_storage_migration.json` 与 `Progress/.legacy_runtime_migrated.json` 绑定旧源和新目标，任一有效标记阻止重复导入旧源，另一份缺失时只补标记。因此玩家之后清除进度、删除档案或草稿，不会在下次启动从旧备份复活。检查点无效或位置不一致时保留数据并报告问题，不擅自切换到其他位置。

迁移或访问失败时，不创建覆盖历史的新默认档案，也不偷偷回退隐藏目录。主菜单与设置仍可使用；正式游玩、统计等需要记录的入口会重新尝试保存位置和授权。编辑器入口及导入继续遵守玩家地图的目录校验。系统拒绝写入时需恢复目录权限或原位置后重试。

旧地图的手动迁移、一次询问与明确删除规则是另一套流程；自动迁移运行记录不会删除 `levels` 中的地图，也不会改变那份确认状态。

## 模型与测试边界

`PlayerRuntimePaths` 仅授权已确认 `saves` 同级的 `Cache` / `Progress`，不扩大 `PlayerLevelPaths` 的地图权限，也不放宽通用资源路径检查。访问时逐段检查目录及直接文件，拒绝符号链接、目录占位和路径跳转。`GameShell` 在正式入口解析并注入目录；独立存储模型保留可注入 `user://` 的兼容接口，测试必须使用自己的 `user://tests` 或已注册物理测试根。

`GameDraftStore` 将草稿目录和进度目录分离；已有单目录测试可继续注入相同位置。跨目录清除仍先验证完整候选集，再暂存并删除，不能递归清空整个 Cache 或 Progress。恢复失败应报告实际保留位置，不宣称全部成功。

现有 macOS / Windows 导出包审查未发现个人草稿、档案或完成标记。内置 `data/hints` 是教学参考资料，不是玩家进度；应用替换也不会自动删除同一系统用户的 `user://`。如果另一台 Windows 机器已有完成状态，需要检查那台机器的旧用户数据，不能仅凭导出现象认定它被打包。

## 地图编辑器的新入口

没有指定路径时，主菜单与独立编辑器场景均创建新的空白地图；不恢复上次地图，不隐式载入 `movement_lab`。`data/maps/movement_lab.json` 只保留为可手动打开的示例。明确从玩家关卡列表打开地图仍加载该文件；试玩回来保留同一个编辑文档、路径、修改状态和历史。
