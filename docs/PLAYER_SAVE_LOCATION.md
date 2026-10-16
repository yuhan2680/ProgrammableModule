# 玩家关卡保存位置

正式入口在读取玩家关卡前解析位置。macOS 非沙盒使用系统 Documents 目录中的 `ProgrammableModule/saves`；Windows 使用系统 `USERPROFILE` 中的 `ProgrammableModule/saves`，不硬编码盘符或用户名。其他平台暂时沿用 `user://levels`。仅玩家地图改变位置，设置、统计、程序与装配草稿仍在原有 `user://` 中。

macOS 旧位置通常为 `~/Library/Application Support/Godot/app_userdata/ProgrammableModule/levels/`，属于应用数据而非缓存。旧数据只在明确放弃或全部迁移完成后清理。沙盒版本的旧 `user://` 位于自身容器，迁移只能读取当前应用有权访问的旧目录，不能跨容器猜测玩家数据。

Windows 旧位置通常为 `%APPDATA%\Godot\app_userdata\ProgrammableModule\levels\`，例如 `C:\Users\用户名\AppData\Roaming\Godot\app_userdata\ProgrammableModule\levels\`；新位置为 `%USERPROFILE%\ProgrammableModule\saves\`。打开或写入当前用户有权限的普通目录一般不会弹出 macOS 式的逐文件夹授权窗口，迁移放弃询问仍由系统原生确认框显示。

## 路径边界

`PlayerLevelPaths` 仅为玩家地图提供绝对路径授权。`DataValidation.is_resource_path` 不变。正式写入只接受系统指定位置或 macOS 原生选择器已授予访问权且以 `ProgrammableModule/saves` 结尾的位置；目录逐层检查，拒绝符号链接、文件占位、路径跳转和相似前缀。导入来源与「另存为」输出不成为普通保存目标。

`PlayerLevelStore`、`LevelCatalog`、`PlayerLevelLibrary` 保留独立模型的 `user://levels` 默认，实际游戏由 `GameShell` 注入同一平台目录。测试显式注入独占 `user://tests` 或已注册的该目录物理路径，不能接触真实 Documents 或 USERPROFILE。启动器默认传空字符串，由 Shell 解析；注入隔离设置而未指定关卡目录的回归使用同一测试命名空间。

## macOS 授权与导出

非沙盒程序通过正常文件访问让 macOS 决定是否显示文稿授权提示，不存在强制弹出该提示的 Documents 专用 API。原生选择器等情形可能已有用户授权，不保证一定出现弹窗。

沙盒中的系统 Documents API 指向容器，不能当作真实用户文稿目录。检测 `OS.is_sandboxed()` 后，首次启动要求通过原生 `FileDialog` 选择用户的文稿目录；游戏在其下使用 `ProgrammableModule/saves`。Godot 保存 security-scoped bookmark，并在重启时恢复访问。独立 `user://player_saves_location.json` 仅保存路径，恢复仍核验 `OS.get_granted_permissions()` 和实际访问结果。删除玩家档案不移除这份位置记录。

macOS 预设保留 App Sandbox 和 `files_user_selected=2`，追加 `com.apple.security.files.bookmarks.app-scope` entitlement，并配置五语 Documents 用途说明。当前预设关闭代码签名，不能将配置存在当作实际沙盒权限验证；发布签名版本必须核验生成的 entitlement，并人工验证「选择文稿 → 保存 → 退出 → 重启读取」。本次自动测试不修改 TCC 或真实系统授权。

取消授权、权限被撤销或写入失败时显示原因并提供重试。地图编辑、导入与单条迁移入口可以再次请求授权；玩家文件管理页在未授权新根时仍允许只读查看旧关卡；教学关卡仍可继续游玩。任何失败都不静默切换回隐藏目录。

## 一次升级询问与旧目录退役

`PlayerLegacyUpgrade` 状态独立于玩家档案，保存于 `user://player_saves_upgrade`。首次发现旧目录有未迁移 JSON 时，通过原生对话框提供操作：macOS 为「忽略 / 前往迁移 / 删除」，Windows 仅为「前往迁移 / 删除」。正文只显示实际文件数量、前往关卡列表的说明与不可撤销的删除提示，不再展示目录路径。提示标记先持久化，之后不重复弹出。系统返回取消、迟到回调均不视为删除同意；默认按钮在 macOS 为忽略，在 Windows 为前往迁移。原生接口不可用时使用对应按钮数量的后备窗口，支持 Esc 或关闭取消。

旧目录不存在或没有 JSON 时不提示，直接停用旧目录。选择「前往迁移」打开玩家关卡列表；尚未迁移的条目显示 `#ff2c2c` 的「目录错误」，右键仅提供「迁移到正确的目录」和「打开旧关卡所在文件夹」。普通编辑、改名、删除菜单不适用于这些条目。

所有旧关卡均成功迁移后，依据已迁移源摘要验证并清理旧 JSON 副本；只有明确选择「删除」才能清理未迁移 JSON。清理意图冻结文件名与摘要，部分失败可重试，后续新增或改变的文件不能被旧授权快照误删。完成后持久化退役标记，不再扫描旧目录或重新显示旧图。只删除直接 JSON 及空的 levels 目录；其他文件和子目录不递归删除，设置、统计与 solutions 永不属于清理范围。状态文件首次创建后不覆盖，失败不假报已退役。

## 逐条迁移复制

`PlayerLevelMigration.pending_files` 只读枚举未迁移文件；`migrate_file` 在用户点选后重新验证列表文件名和摘要，仅复制当前直接 JSON。包含坏 JSON、未完成草稿、BOM 与空文件，原始字节、地图 ID 和扩展字段均保留。复制过程中不删除源文件。同名同内容复用；同名不同内容使用确定的 `_legacy_<摘要>` 后缀，不覆盖已有文件。复制不重写 ID，两份不同地图恰好同 ID 时仍由既有目录规则诊断。

迁移计划先写检查点，再复制到独立临时文件，回读摘要且确认源未变化后提交。已提交的文件不会因中断或新目录删除而重新出现。`user://player_saves_migration.json` 与恢复槽都绑定源、目标及单调序号；更新一槽时保留另一槽，避免 Windows Godot 的覆盖重命名先删除目标带来的检查点丢失。读取选择最新有效槽，绑定冲突或同序号不同内容明确失败。所有迁移错误保留原始地图与可恢复记录。

## 验证

新增路径、迁移、位置恢复、旧图聚合、原生询问、退役与 Shell 接线回归覆盖 macOS/Windows 路径推导、保存/导入/改名/删除、异常草稿、链接拒绝、同名冲突、Windows 提交中断、一次提醒/取消/明确放弃、全部完成后清理、已迁移文件删除不复活。完整 `tools/test.ps1` 继续验证既有地图编辑、游玩、草稿与多语言行为。真实签名版 macOS 权限与 Windows 桌面系统窗口仍需在对应发布环境人工验证。
