#requires -Version 7.0
param(
    [string]$GodotPath = 'godot'
)

# 从脚本所在位置定位工程，调用者无需先切换到项目目录。
$ErrorActionPreference = 'Stop'
$projectPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$engine = Get-Command $GodotPath -ErrorAction Stop

# 同时支持控制台版与 GUI 版 Godot，显式等待退出并并行读取两个输出流。
function Invoke-GodotCheck {
    param([string[]]$EngineArguments, [int]$TimeoutMilliseconds = 180000)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $engine.Source
    $startInfo.WorkingDirectory = $projectPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($argument in $EngineArguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            throw ('Godot 检查超时，已停止本次测试进程：' + ($EngineArguments -join ' '))
        }
        $output = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Output = $output }
    }
    finally {
        $process.Dispose()
    }
}

# 首次检出时先生成脚本类与图片缓存；高分屏资源和虚拟机并行运行时预留导入时间。
$importResult = Invoke-GodotCheck -EngineArguments @('--headless', '--editor', '--path', $projectPath, '--import') -TimeoutMilliseconds 180000
if ($importResult.ExitCode -ne 0 -or $importResult.Output -match '(?m)^ERROR:|SCRIPT ERROR:|Parse Error:|Compilation failed|Failed loading resource:') {
    Write-Host $importResult.Output
    throw 'Godot 项目导入失败，测试尚未执行。'
}

# 引擎与 GDScript 运行时错误有时仍返回状态 0，因此同时检查日志和完成标记。
$testResult = Invoke-GodotCheck @('--headless', '--path', $projectPath, '--quit-after', '600', '--script', 'res://tests/headless_runner.gd')
Write-Host $testResult.Output
if ($testResult.ExitCode -ne 0 -or $testResult.Output -match '(?m)^ERROR:|SCRIPT ERROR:|Parse Error:|Compilation failed' -or $testResult.Output -notmatch '回归完成：.+0 项失败。') {
    throw '回归测试失败，请查看上方的断言或脚本错误。'
}

# 加载真正的编辑器场景，验证控件信号、绘图输入、文件往返与试玩隔离。
$smokeResult = Invoke-GodotCheck @('--headless', '--path', $projectPath, '--quit-after', '600', '--script', 'res://tests/editor_smoke.gd')
Write-Host $smokeResult.Output
if ($smokeResult.ExitCode -ne 0 -or $smokeResult.Output -match '(?m)^ERROR:|SCRIPT ERROR:|Parse Error:|Compilation failed' -or $smokeResult.Output -notmatch '编辑器冒烟完成：.+0 项失败。') {
    throw '编辑器冒烟测试失败。'
}

# 新增的语言与游戏测试单独运行，任一进程缺少完成标记也视为失败。
$gameChecks = @(
    @{ Script = 'res://tests/player_runtime_storage_runner.gd'; Marker = '缓存与进度存储回归完成：.+0 项失败。'; Label = '缓存与进度目录及升级迁移回归' },
    @{ Script = 'res://tests/player_runtime_shell_runner.gd'; Marker = '玩家运行数据外壳回归完成：.+0 项失败。'; Label = '缓存进度启动接线与恢复门禁回归' },
    @{ Script = 'res://tests/player_legacy_library_runner.gd'; Marker = '旧玩家关卡聚合回归完成：.+0 项失败。'; Label = '未迁移旧关卡列表与操作边界回归' },
    @{ Script = 'res://tests/player_legacy_list_ui_runner.gd'; Marker = '旧目录关卡列表界面回归完成：.+0 项失败。'; Label = '旧目录状态颜色与独立迁移菜单回归' },
    @{ Script = 'res://tests/player_legacy_upgrade_runner.gd'; Marker = '旧玩家关卡升级生命周期回归完成：.+0 项失败。'; Label = '一次升级提醒与旧目录退役回归' },
    @{ Script = 'res://tests/player_legacy_upgrade_dialog_runner.gd'; Marker = '旧关卡升级提示界面回归完成：.+0 项失败。'; Label = '旧关卡原生迁移询问回归' },
    @{ Script = 'res://tests/player_level_paths_runner.gd'; Marker = '玩家关卡外部路径回归完成：.+0 项失败。'; Label = '玩家关卡可见保存目录边界回归' },
    @{ Script = 'res://tests/player_level_migration_runner.gd'; Marker = '玩家关卡旧目录迁移回归完成：.+0 项失败。'; Label = '旧玩家地图无损迁移回归' },
    @{ Script = 'res://tests/player_save_location_runner.gd'; Marker = '玩家关卡保存位置回归完成：.+0 项失败。'; Label = '玩家关卡平台位置与授权恢复回归' },
    @{ Script = 'res://tests/player_saves_shell_runner.gd'; Marker = '玩家关卡保存入口回归完成：.+0 项失败。'; Label = '玩家关卡保存目录与游戏入口接线回归' },
    @{ Script = 'res://tests/map_editor_responsive_runner.gd'; Marker = '地图属性响应式回归完成：.+0 项失败。'; Label = '五语地图属性自适应排版回归' },
    @{ Script = 'res://tests/japanese_locale_runner.gd'; Marker = 'JAPANESE_LOCALE_TESTS .+ checks, 0 failures'; Label = '日语本土化与显示语言回归' },
    @{ Script = 'res://tests/statistics_about_ui_runner.gd'; Marker = 'STATISTICS_ABOUT_UI_TESTS .+ checks, 0 failures'; Label = '首次运行日期与统计说明弹窗回归' },
    @{ Script = 'res://tests/level_code_policy_editor_runner.gd'; Marker = 'LEVEL_CODE_POLICY_EDITOR_TESTS .+ checks, 0 failures'; Label = '玩家地图代码规则与粘贴锁定回归' },
    @{ Script = 'res://tests/code_paste_policy_runner.gd'; Marker = '逐关粘贴限制回归完成：.+0 项失败。'; Label = '逐关代码粘贴与拖放限制回归' },
    @{ Script = 'res://tests/custom_code_hint_runner.gd'; Marker = '玩家地图自动提示回归完成：.+0 项失败。'; Label = '玩家关卡自动推导提示回归' },
    @{ Script = 'res://tests/workbench_code_layout_runner.gd'; Marker = '代码布局与字号回归完成：.+0 项失败。'; Label = '代码卡片布局与字号缩放' },
    @{ Script = 'res://tests/workbench_navigation_guide_runner.gd'; Marker = '编程导航与系统说明回归完成：.+0 项失败。'; Label = '编程与组装导航及说明末页' },
    @{ Script = 'res://tests/curtain_preview_runner.gd'; Marker = '地图窗帘覆盖回归完成：.+0 项失败。'; Label = '地图覆盖拖动预览' },
    @{ Script = 'res://tests/clear_progress_native_runner.gd'; Marker = '预设进度原生确认回归完成：.+0 项失败。'; Label = '预设进度原生确认与取消保护回归' },
    @{ Script = 'res://tests/player_profile_runner.gd'; Marker = '玩家档案回归完成：.+0 项失败。'; Label = '玩家档案持久化与重置回归' },
    @{ Script = 'res://tests/player_activity_runner.gd'; Marker = '玩家活动统计回归完成：.+0 项失败。'; Label = '前台游戏时间与彩蛋最高分回归' },
    @{ Script = 'res://tests/player_attempt_tracker_runner.gd'; Marker = '玩家耗时回归完成：.+0 项失败。'; Label = '活动墙钟计时回归' },
    @{ Script = 'res://tests/tutorial_completion_progress_runner.gd'; Marker = 'TUTORIAL_COMPLETION_PROGRESS_TESTS .+ checks, 0 failures'; Label = '教学完成进度与满进度样式回归' },
    @{ Script = 'res://tests/player_profile_ui_runner.gd'; Marker = 'PLAYER_PROFILE_UI_TESTS .+ checks, 0 failures'; Label = '玩家档案界面与系统确认回归' },
    @{ Script = 'res://tests/player_profile_shell_layout_runner.gd'; Marker = 'PLAYER_PROFILE_SHELL_LAYOUT_TESTS .+ checks, 0 failures'; Label = '玩家档案实际页面与高分屏布局回归' },
    @{ Script = 'res://tests/player_stats_integration_runner.gd'; Marker = '玩家统计集成回归完成：.+0 项失败。'; Label = '正式关卡统计与试玩隔离回归' },
    @{ Script = 'res://tests/menu_page_transition_runner.gd'; Marker = '主菜单页面转场回归完成：.+0 项失败。'; Label = '主菜单白卡扩展与页面渐入回归' },
	@{ Script = 'res://tests/editor_native_exit_runner.gd'; Marker = 'EDITOR_NATIVE_EXIT_TESTS .+ checks, 0 failures'; Label = '原生地图退出与保存保护回归' },
    @{ Script = 'res://tests/editor_footer_runner.gd'; Marker = 'EDITOR_FOOTER_TESTS .+ checks, 0 failures'; Label = '编辑器底部双按钮与按需反馈回归' },
    @{ Script = 'res://tests/editor_timed_gate_runner.gd'; Marker = 'EDITOR_TIMED_GATE_TESTS .+ checks, 0 failures'; Label = '限时闸门编辑与固定属性卡回归' },
    @{ Script = 'res://tests/command_permissions_runner.gd'; Marker = 'COMMAND_PERMISSIONS_TESTS .+ checks, 0 failures'; Label = '关卡指令权限模型回归' },
    @{ Script = 'res://tests/command_policy_parser_runner.gd'; Marker = 'COMMAND_POLICY_PARSER_TESTS .+ checks, 0 failures'; Label = '指令白名单解析回归' },
    @{ Script = 'res://tests/command_restriction_ui_runner.gd'; Marker = 'COMMAND_RESTRICTION_UI_TESTS .+ checks, 0 failures'; Label = '指令管理界面与执行集成回归' },
    @{ Script = 'res://tests/player_level_library_runner.gd'; Marker = '玩家文件列表模型回归完成：.+0 项失败。'; Label = '玩家文件列表模型回归' },
    @{ Script = 'res://tests/player_level_list_ui_runner.gd'; Marker = '玩家关卡列表界面回归完成：.+0 项失败。'; Label = '玩家关卡列表界面回归' },
    @{ Script = 'res://tests/player_level_import_runner.gd'; Marker = '玩家关卡导入模型回归完成：.+0 项失败。'; Label = '玩家关卡导入模型回归' },
    @{ Script = 'res://tests/player_level_rename_runner.gd'; Marker = '玩家关卡重命名模型回归完成：.+0 项失败。'; Label = '玩家关卡重命名模型回归' },
    @{ Script = 'res://tests/player_level_import_ui_runner.gd'; Marker = '玩家关卡导入界面回归完成：.+0 项失败。'; Label = '玩家关卡导入界面回归' },
    @{ Script = 'res://tests/player_level_management_runner.gd'; Marker = '玩家关卡管理界面回归完成：.+0 项失败。'; Label = '玩家关卡管理界面回归' },
    @{ Script = 'res://tests/map_properties_focus_runner.gd'; Marker = '地图属性失焦回归完成：.+0 项失败。'; Label = '地图属性失焦回归' },
    @{ Script = 'res://tests/module_restriction_model_runner.gd'; Marker = '模块限制模型回归完成：.+0 项失败。'; Label = '模块限制模型回归' },
    @{ Script = 'res://tests/module_restriction_ui_runner.gd'; Marker = '模块限制界面回归完成：.+0 项失败。'; Label = '模块限制界面回归' },
    @{ Script = 'res://tests/map_guide_model_runner.gd'; Marker = '地图分页引导模型回归完成：.+0 项失败。'; Label = '地图分页引导模型回归' },
    @{ Script = 'res://tests/map_guide_editor_runner.gd'; Marker = '关卡引导编辑界面回归完成：.+0 项失败。'; Label = '关卡引导编辑界面回归' },
    @{ Script = 'res://tests/player_guide_runtime_runner.gd'; Marker = '玩家关卡引导运行时回归完成：.+0 项失败。'; Label = '玩家关卡引导运行时回归' },
    @{ Script = 'res://tests/map_creator_model_runner.gd'; Marker = '地图创作者模型回归完成：.+0 项失败。'; Label = '地图创作者模型回归' },
    @{ Script = 'res://tests/map_subtitle_runner.gd'; Marker = '地图副标题模型回归完成：.+0 项失败。'; Label = '地图副标题模型回归' },
    @{ Script = 'res://tests/editor_subtitle_runner.gd'; Marker = '副标题编辑界面回归完成：.+0 项失败。'; Label = '副标题编辑界面回归' },
    @{ Script = 'res://tests/editor_creator_runner.gd'; Marker = '创作者编辑界面回归完成：.+0 项失败。'; Label = '创作者编辑界面回归' },
    @{ Script = 'res://tests/player_level_delete_runner.gd'; Marker = '玩家关卡删除模型回归完成：.+0 项失败。'; Label = '玩家关卡删除模型回归' },
    @{ Script = 'res://tests/player_level_card_runner.gd'; Marker = '玩家关卡署名与删除界面回归完成：.+0 项失败。'; Label = '玩家关卡署名与删除界面回归' },
    @{ Script = 'res://tests/player_level_store_runner.gd'; Marker = '玩家关卡保存模型回归完成：.+0 项失败。'; Label = '玩家关卡保存模型回归' },
    @{ Script = 'res://tests/player_level_save_runner.gd'; Marker = '玩家关卡保存集成回归完成：.+0 项失败。'; Label = '玩家关卡保存集成回归' },
    @{ Script = 'res://tests/startup_runner.gd'; Marker = '启动加载回归完成：.+0 项失败。'; Label = '启动加载回归' },
    @{ Script = 'res://tests/menu_background_settings_runner.gd'; Marker = '菜单背景设置回归完成：.+0 项失败。'; Label = '菜单背景设置回归' },
    @{ Script = 'res://tests/menu_background_ui_runner.gd'; Marker = '菜单背景界面回归完成：.+0 项失败。'; Label = '菜单背景界面回归' },
    @{ Script = 'res://tests/assembly_viewport_runner.gd'; Marker = '装配视图回归完成：.+0 项失败。'; Label = '装配视图回归' },
    @{ Script = 'res://tests/assembly_top_fade_runner.gd'; Marker = '装配顶部渐隐回归完成：.+0 项失败。'; Label = '装配顶部渐隐回归' },
    @{ Script = 'res://tests/scroll_content_fade_runner.gd'; Marker = '滚动内容渐隐回归完成：.+0 项失败。'; Label = '滚动内容渐隐回归' },
    @{ Script = 'res://tests/radar_event_parser_runner.gd'; Marker = '雷达事件语法回归完成：.+0 项失败。'; Label = '雷达事件语法回归' },
    @{ Script = 'res://tests/radar_event_runtime_runner.gd'; Marker = '雷达事件运行时回归完成：.+0 项失败。'; Label = '雷达事件运行时回归' },
    @{ Script = 'res://tests/radar_event_editor_runner.gd'; Marker = '雷达事件编辑辅助回归完成：.+0 项失败。'; Label = '雷达事件编辑辅助回归' },
    @{ Script = 'res://tests/radar_event_level_runner.gd'; Marker = '第十五关回归完成：.+0 项失败。'; Label = '第十五关回归' },
    @{ Script = 'res://tests/escape_level_runner.gd'; Marker = '第十六关逃脱回归完成：.+0 项失败。'; Label = '第十六关逃脱回归' },
    @{ Script = 'res://tests/escape_ui_runner.gd'; Marker = '第十六关界面回归完成：.+0 项失败。'; Label = '第十六关界面回归' },
	@{ Script = 'res://tests/player_health_runner.gd'; Marker = '玩家耐久回归完成：.+0 项失败。'; Label = '玩家耐久回归' },
    @{ Script = 'res://tests/editor_time_limit_runner.gd'; Marker = '地图限时回归完成：.+0 项失败。'; Label = '地图限时回归' },
    @{ Script = 'res://tests/editor_enemy_document_runner.gd'; Marker = '地图敌人文档回归完成：.+0 项失败。'; Label = '地图敌人文档回归' },
    @{ Script = 'res://tests/editor_enemy_runtime_runner.gd'; Marker = '编辑器敌人运行回归完成：.+0 项失败。'; Label = '编辑器敌人运行回归' },
    @{ Script = 'res://tests/editor_enemy_canvas_runner.gd'; Marker = '地图敌人画布回归完成：.+0 项失败。'; Label = '地图敌人画布回归' },
    @{ Script = 'res://tests/editor_enemy_ui_runner.gd'; Marker = '敌人编辑界面回归完成：.+0 项失败。'; Label = '敌人编辑界面回归' },
    @{ Script = 'res://tests/editor_exit_dialog_runner.gd'; Marker = '地图退出确认回归完成：.+0 项失败。'; Label = '地图退出确认回归' },
    @{ Script = 'res://tests/map_editor_endpoints_runner.gd'; Marker = '地图起终点回归完成：.+0 项失败。'; Label = '地图起终点回归' },
    @{ Script = 'res://tests/map_editor_rectangle_runner.gd'; Marker = '地图框选回归完成：.+0 项失败。'; Label = '地图框选回归' },
    @{ Script = 'res://tests/map_editor_viewport_runner.gd'; Marker = '地图编辑器视口回归完成：.+0 项失败。'; Label = '地图编辑器视口回归' },
    @{ Script = 'res://tests/map_editor_edge_fade_runner.gd'; Marker = '地图编辑器边缘渐隐回归完成：.+0 项失败。'; Label = '地图编辑器边缘渐隐回归' },
    @{ Script = 'res://tests/map_editor_toolbar_runner.gd'; Marker = '地图编辑器工具栏回归完成：.+0 项失败。'; Label = '地图编辑器工具栏回归' },
    @{ Script = 'res://tests/for_language_runner.gd'; Marker = '有限 for 循环语言回归完成：.+0 项失败。'; Label = '有限 for 循环语言回归' },
    @{ Script = 'res://tests/eight_direction_world_runner.gd'; Marker = '八方向分波世界回归完成：.+0 项失败。'; Label = '八方向分波世界回归' },
    @{ Script = 'res://tests/corridor_level_runner.gd'; Marker = '第十四关回归完成：.+0 项失败。'; Label = '第十四关回归' },
    @{ Script = 'res://tests/ambush_level_runner.gd'; Marker = '第十三关回归完成：.+0 项失败。'; Label = '第十三关回归' },
    @{ Script = 'res://tests/eight_direction_level_runner.gd'; Marker = '第十二关回归完成：.+0 项失败。'; Label = '第十二关回归' },

    @{ Script = 'res://tests/random_language_runner.gd'; Marker = '随机语言回归完成：.+0 项失败。'; Label = '随机语言回归' },
    @{ Script = 'res://tests/random_level_runner.gd'; Marker = '随机关卡回归完成：.+0 项失败。'; Label = '随机关卡回归' },
    @{ Script = 'res://tests/radar_pursuit_level_runner.gd'; Marker = '第十关追猎回归完成：.+0 项失败。'; Label = '第十关追猎回归' },
    @{ Script = 'res://tests/code_color_ui_runner.gd'; Marker = '代码颜色界面回归完成：.+0 项失败。'; Label = '代码颜色界面回归' },
    @{ Script = 'res://tests/code_color_editor_runner.gd'; Marker = '代码配色编辑器回归完成：.+0 项失败。'; Label = '代码配色编辑器回归' },
    @{ Script = 'res://tests/code_color_settings_runner.gd'; Marker = '代码颜色设置回归完成：.+0 项失败。'; Label = '代码颜色设置回归' },
    @{ Script = 'res://tests/player_radar_level_runner.gd'; Marker = '玩家雷达教学回归完成：.+0 项失败。'; Label = '玩家雷达教学回归' },
    @{ Script = 'res://tests/radar_language_runner.gd'; Marker = '玩家雷达语言回归完成：.+0 项失败。'; Label = '玩家雷达语言回归' },
    @{ Script = 'res://tests/player_radar_world_runner.gd'; Marker = '玩家雷达底层回归完成：.+0 项失败。'; Label = '玩家雷达底层回归' },
    @{ Script = 'res://tests/variables_language_runner.gd'; Marker = '常变量语言回归完成：.+0 项失败。'; Label = '常变量语言回归' },
    @{ Script = 'res://tests/code_hint_runner.gd'; Marker = '代码提示回归完成：.+0 项失败。'; Label = '代码提示回归' },
    @{ Script = 'res://tests/hint_attempt_runner.gd'; Marker = '提示次数回归完成：.+0 项失败。'; Label = '提示次数回归' },
    @{ Script = 'res://tests/code_hint_ui_runner.gd'; Marker = '代码提示界面回归完成：.+0 项失败。'; Label = '代码提示界面回归' },
    @{ Script = 'res://tests/language_runner.gd'; Marker = '语言回归完成：.+0 项失败。'; Label = '语言回归' },
    @{ Script = 'res://tests/gameplay_runner.gd'; Marker = '游戏回归完成：.+0 项失败。'; Label = '游戏回归' },
    @{ Script = 'res://tests/program_completion_runner.gd'; Marker = '补全候选回归完成：.+0 项失败。'; Label = '补全候选回归' },
    @{ Script = 'res://tests/inline_completion_runner.gd'; Marker = '行内补全回归完成：.+0 项失败。'; Label = '行内补全回归' },
    @{ Script = 'res://tests/window_resolution_settings_runner.gd'; Marker = '窗口分辨率设置回归完成：.+0 项失败。'; Label = '窗口分辨率设置回归' },
    @{ Script = 'res://tests/ui_scale_runner.gd'; Marker = '界面缩放回归完成：.+0 项失败。'; Label = '界面缩放回归' },
    @{ Script = 'res://tests/font_raster_scale_runner.gd'; Marker = 'FONT_RASTER_SCALE_TESTS .+ checks, 0 failures'; Label = '字体渲染采样回归' },
    @{ Script = 'res://tests/settings_option_glass_runner.gd'; Marker = 'SETTINGS_OPTION_GLASS_TESTS:? .+ checks, 0 failures'; Label = '设置选择菜单玻璃回归' },
    @{ Script = 'res://tests/settings_option_checkmark_runner.gd'; Marker = 'SETTINGS_OPTION_CHECKMARK_TESTS: .+ checks, 0 failures'; Label = '设置选择菜单勾选回归' },
    @{ Script = 'res://tests/settings_option_scrollbar_runner.gd'; Marker = 'SETTINGS_OPTION_SCROLLBAR_TESTS: .+ checks, 0 failures'; Label = '设置选择菜单滚动条回归' },
    @{ Script = 'res://tests/windows_menu_card_runner.gd'; Marker = 'Windows 主菜单白卡回归完成：.+0 项失败。'; Label = 'Windows 主菜单白卡回归' },
    @{ Script = 'res://tests/level_page_scale_runner.gd'; Marker = 'LEVEL_PAGE_SCALE_TESTS .+ checks, 0 failures'; Label = '高分辨率选关比例回归' },
    @{ Script = 'res://tests/map_editor_scale_runner.gd'; Marker = 'MAP_EDITOR_SCALE_TESTS .+ checks, 0 failures'; Label = '高分辨率地图编辑器比例回归' },
    @{ Script = 'res://tests/settings_dialog_scale_runner.gd'; Marker = '设置独立浮层比例回归完成：.+0 项失败。'; Label = '设置独立浮层比例回归' },
    @{ Script = 'res://tests/window_resolution_ui_runner.gd'; Marker = '窗口分辨率界面回归完成：.+0 项失败。'; Label = '窗口分辨率界面回归' },
    @{ Script = 'res://tests/system_sound_runner.gd'; Marker = '系统提示音回归完成：.+0 项失败。'; Label = '系统提示音回归' },
    @{ Script = 'res://tests/settings_audio_glass_runner.gd'; Marker = '音量玻璃回归完成：.+0 项失败。'; Label = '设置音量玻璃回归' },
    @{ Script = 'res://tests/settings_switch_glass_runner.gd'; Marker = '玻璃开关回归完成：.+0 项失败。'; Label = '胶囊开关玻璃回归' },
    @{ Script = 'res://tests/native_system_sound_runner.gd'; Marker = '原生提示音回归完成：.+0 项失败。'; Label = '原生提示音回归' },
    @{ Script = 'res://tests/settings_runner.gd'; Marker = '设置回归完成：.+0 项失败。'; Label = '设置回归' },
    @{ Script = 'res://tests/settings_open_layout_runner.gd'; Marker = '设置开放布局回归完成：.+0 项失败。'; Label = '设置开放布局回归' },
    @{ Script = 'res://tests/shark_cave_runner.gd'; Marker = '鲨鱼洞穴模型回归完成：.+0 项失败。'; Label = '鲨鱼洞穴模型回归' },
    @{ Script = 'res://tests/shark_cave_scenery_runner.gd'; Marker = '鲨鱼前景景物回归完成：.+0 项失败。'; Label = '鲨鱼前景景物回归' },
    @{ Script = 'res://tests/shark_easter_egg_runner.gd'; Marker = '鲨鱼彩蛋集成回归完成：.+0 项失败。'; Label = '鲨鱼彩蛋集成回归' },
    @{ Script = 'res://tests/about_game_runner.gd'; Marker = '关于游戏回归完成：.+0 项失败。'; Label = '关于游戏回归' },
    @{ Script = 'res://tests/hong_kong_locale_runner.gd'; Marker = '香港繁体回归完成：.+0 项失败。'; Label = '香港繁体回归' },
    @{ Script = 'res://tests/spanish_locale_runner.gd'; Marker = '西班牙语回归完成：.+0 项失败。'; Label = '西班牙语回归' },
    @{ Script = 'res://tests/progress_reset_runner.gd'; Marker = '进度清除回归完成：.+0 项失败。'; Label = '进度清除回归' },
    @{ Script = 'res://tests/user_level_reset_runner.gd'; Marker = '用户关卡清除回归完成：.+0 项失败。'; Label = '用户关卡清除回归' },
    @{ Script = 'res://tests/command_book_motion_runner.gd'; Marker = 'COMMAND_BOOK_MOTION_TESTS: .+ checks, 0 failures'; Label = '书本入口矢量开合与锚定窗口动画回归' },
    @{ Script = 'res://tests/command_catalog_runner.gd'; Marker = '指令资料回归完成：.+0 项失败。'; Label = '指令资料回归' },
    @{ Script = 'res://tests/game_ui_smoke.gd'; Marker = '游戏界面冒烟完成：.+0 项失败。'; Label = '游戏界面冒烟' },
    @{ Script = 'res://tests/campaign_runner.gd'; Marker = '关卡与战斗回归完成：.+0 项失败。'; Label = '关卡与战斗回归' },
    @{ Script = 'res://tests/projectile_collision_runner.gd'; Marker = '弹道碰撞回归完成：.+0 项失败。'; Label = '弹道碰撞回归' },
    @{ Script = 'res://tests/shooting_level_runner.gd'; Marker = '第四关回归完成：.+0 项失败。'; Label = '第四关回归' },
    @{ Script = 'res://tests/prison_world_runner.gd'; Marker = '监狱底层回归完成：.+0 项失败。'; Label = '监狱底层回归' },
    @{ Script = 'res://tests/prison_level_runner.gd'; Marker = '第五关回归完成：.+0 项失败。'; Label = '第五关回归' },
    @{ Script = 'res://tests/staircase_level_runner.gd'; Marker = '第六关回归完成：.+0 项失败。'; Label = '第六关回归' },
    @{ Script = 'res://tests/pursuit_world_runner.gd'; Marker = '追击底层回归完成：.+0 项失败。'; Label = '追击底层回归' },
    @{ Script = 'res://tests/pursuit_level_runner.gd'; Marker = '第七关回归完成：.+0 项失败。'; Label = '第七关回归' },
    @{ Script = 'res://tests/simultaneous_language_runner.gd'; Marker = '并行语言回归完成：.+0 项失败。'; Label = '并行语言回归' },
    @{ Script = 'res://tests/simultaneous_world_runner.gd'; Marker = '并行动作底层回归完成：.+0 项失败。'; Label = '并行世界回归' },
    @{ Script = 'res://tests/simultaneous_level_runner.gd'; Marker = '第八关回归完成：.+0 项失败。'; Label = '第八关回归' },
    @{ Script = 'res://tests/rangefinder_language_runner.gd'; Marker = '测距语言回归完成：.+0 项失败。'; Label = '测距语言回归' },
    @{ Script = 'res://tests/rangefinder_world_runner.gd'; Marker = '测距底层回归完成：.+0 项失败。'; Label = '测距底层回归' },
    @{ Script = 'res://tests/rangefinder_level_runner.gd'; Marker = '第九关回归完成：.+0 项失败。'; Label = '第九关回归' },
    @{ Script = 'res://tests/functions_language_runner.gd'; Marker = '函数语言回归完成：.+0 项失败。'; Label = '函数语言回归' },
    @{ Script = 'res://tests/dodge_level_runner.gd'; Marker = '第十一关回归完成：.+0 项失败。'; Label = '第十一关回归' },
    @{ Script = 'res://tests/radar_lunge_world_runner.gd'; Marker = '雷达突袭底层回归完成：.+0 项失败。'; Label = '雷达突袭底层回归' },
    @{ Script = 'res://tests/functions_ui_runner.gd'; Marker = '函数教学界面回归完成：.+0 项失败。'; Label = '函数教学界面回归' },
    @{ Script = 'res://tests/level_search_runner.gd'; Marker = '关卡搜索回归完成：.+0 项失败。'; Label = '关卡搜索回归' },
    @{ Script = 'res://tests/glass_tooltip_runner.gd'; Marker = '玻璃提示回归完成：.+0 项失败。'; Label = '玻璃提示回归' },
    @{ Script = 'res://tests/command_tooltip_wrap_runner.gd'; Marker = 'COMMAND_TOOLTIP_WRAP_TESTS \d+ checks, 0 failures'; Label = '长指令悬停换行回归' },
    @{ Script = 'res://tests/wave_status_layout_runner.gd'; Marker = '分波状态布局回归完成：.+0 项失败。'; Label = '分波状态文字与地图留白回归' },
    @{ Script = 'res://tests/full_size_preview_runner.gd'; Marker = '全尺寸预览回归完成：.+0 项失败。'; Label = '全尺寸预览回归' },
    @{ Script = 'res://tests/full_preview_feedback_runner.gd'; Marker = '全尺寸结果药丸回归完成：.+0 项失败。'; Label = '全尺寸结果反馈回归' },
    @{ Script = 'res://tests/layout_runner.gd'; Marker = '布局回归完成：.+0 项失败。'; Label = '布局回归' }
)
foreach ($check in $gameChecks) {
    # 交互回归等待真实动画与弹窗时长，限制帧率并留足帧预算，避免 headless 提前退出。
    $timingArguments = if ($check.Script -eq 'res://tests/shark_easter_egg_runner.gd') { @('--max-fps', '120', '--quit-after', '24000') } elseif ($check.Script -in @('res://tests/map_editor_responsive_runner.gd', 'res://tests/japanese_locale_runner.gd', 'res://tests/statistics_about_ui_runner.gd', 'res://tests/command_tooltip_wrap_runner.gd', 'res://tests/wave_status_layout_runner.gd', 'res://tests/settings_switch_glass_runner.gd')) { @('--max-fps', '120', '--quit-after', '14400') } elseif ($check.Script -in @('res://tests/tutorial_completion_progress_runner.gd', 'res://tests/command_book_motion_runner.gd', 'res://tests/workbench_code_layout_runner.gd', 'res://tests/workbench_navigation_guide_runner.gd', 'res://tests/curtain_preview_runner.gd', 'res://tests/player_activity_runner.gd', 'res://tests/player_profile_ui_runner.gd', 'res://tests/player_profile_shell_layout_runner.gd', 'res://tests/player_stats_integration_runner.gd', 'res://tests/menu_page_transition_runner.gd', 'res://tests/player_level_save_runner.gd', 'res://tests/player_level_list_ui_runner.gd', 'res://tests/player_level_import_ui_runner.gd', 'res://tests/player_level_management_runner.gd', 'res://tests/map_properties_focus_runner.gd', 'res://tests/module_restriction_ui_runner.gd', 'res://tests/map_guide_editor_runner.gd', 'res://tests/player_guide_runtime_runner.gd', 'res://tests/editor_creator_runner.gd', 'res://tests/editor_subtitle_runner.gd', 'res://tests/player_level_card_runner.gd', 'res://tests/player_level_save_runner.gd', 'res://tests/system_sound_runner.gd', 'res://tests/settings_audio_glass_runner.gd', 'res://tests/native_system_sound_runner.gd', 'res://tests/escape_ui_runner.gd', 'res://tests/window_resolution_ui_runner.gd', 'res://tests/ui_scale_runner.gd', 'res://tests/font_raster_scale_runner.gd', 'res://tests/settings_option_glass_runner.gd', 'res://tests/settings_option_checkmark_runner.gd', 'res://tests/command_restriction_ui_runner.gd', 'res://tests/windows_menu_card_runner.gd', 'res://tests/level_page_scale_runner.gd', 'res://tests/map_editor_scale_runner.gd', 'res://tests/settings_dialog_scale_runner.gd', 'res://tests/startup_runner.gd', 'res://tests/about_game_runner.gd', 'res://tests/settings_open_layout_runner.gd', 'res://tests/menu_background_ui_runner.gd', 'res://tests/assembly_viewport_runner.gd', 'res://tests/editor_time_limit_runner.gd', 'res://tests/editor_timed_gate_runner.gd', 'res://tests/editor_footer_runner.gd', 'res://tests/editor_enemy_canvas_runner.gd', 'res://tests/editor_enemy_ui_runner.gd', 'res://tests/editor_exit_dialog_runner.gd', 'res://tests/editor_native_exit_runner.gd', 'res://tests/map_editor_endpoints_runner.gd', 'res://tests/map_editor_rectangle_runner.gd', 'res://tests/map_editor_viewport_runner.gd', 'res://tests/map_editor_edge_fade_runner.gd', 'res://tests/scroll_content_fade_runner.gd', 'res://tests/map_editor_toolbar_runner.gd', 'res://tests/code_color_ui_runner.gd', 'res://tests/code_color_editor_runner.gd', 'res://tests/code_hint_ui_runner.gd', 'res://tests/functions_ui_runner.gd', 'res://tests/inline_completion_runner.gd', 'res://tests/game_ui_smoke.gd', 'res://tests/layout_runner.gd', 'res://tests/glass_tooltip_runner.gd', 'res://tests/full_size_preview_runner.gd', 'res://tests/full_preview_feedback_runner.gd')) { @('--max-fps', '120', '--quit-after', '7200') } elseif ($check.Script -eq 'res://tests/settings_option_scrollbar_runner.gd') { @('--max-fps', '120', '--quit-after', '6000') } elseif ($check.Script -eq 'res://tests/level_search_runner.gd') { @('--max-fps', '120', '--quit-after', '2400') } else { @('--quit-after', '600') }
    # 引擎冷启动、字体缓存和虚拟机负载可能超过一分钟；仍检查退出码、错误及完成标记。
    $timeoutMilliseconds = 180000
    $result = Invoke-GodotCheck -EngineArguments (@('--headless', '--path', $projectPath) + $timingArguments + @('--script', $check.Script)) -TimeoutMilliseconds $timeoutMilliseconds
    Write-Host $result.Output
    if ($result.ExitCode -ne 0 -or $result.Output -match '(?m)^ERROR:|SCRIPT ERROR:|Parse Error:|Compilation failed' -or $result.Output -notmatch $check.Marker) {
        throw ($check.Label + '失败。')
    }
}
