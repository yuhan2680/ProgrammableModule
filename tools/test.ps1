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
    param([string[]]$EngineArguments)
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
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            throw 'Godot 检查超时，已停止本次测试进程。'
        }
        $output = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Output = $output }
    }
    finally {
        $process.Dispose()
    }
}

# 首次检出时先生成 Godot 全局脚本类缓存与图片导入资源。
$importResult = Invoke-GodotCheck @('--headless', '--editor', '--path', $projectPath, '--import')
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
    @{ Script = 'res://tests/startup_runner.gd'; Marker = '启动加载回归完成：.+0 项失败。'; Label = '启动加载回归' },
    @{ Script = 'res://tests/menu_background_settings_runner.gd'; Marker = '菜单背景设置回归完成：.+0 项失败。'; Label = '菜单背景设置回归' },
    @{ Script = 'res://tests/menu_background_ui_runner.gd'; Marker = '菜单背景界面回归完成：.+0 项失败。'; Label = '菜单背景界面回归' },
    @{ Script = 'res://tests/assembly_viewport_runner.gd'; Marker = '装配视图回归完成：.+0 项失败。'; Label = '装配视图回归' },
    @{ Script = 'res://tests/assembly_top_fade_runner.gd'; Marker = '装配顶部渐隐回归完成：.+0 项失败。'; Label = '装配顶部渐隐回归' },
    @{ Script = 'res://tests/radar_event_parser_runner.gd'; Marker = '雷达事件语法回归完成：.+0 项失败。'; Label = '雷达事件语法回归' },
    @{ Script = 'res://tests/radar_event_runtime_runner.gd'; Marker = '雷达事件运行时回归完成：.+0 项失败。'; Label = '雷达事件运行时回归' },
    @{ Script = 'res://tests/radar_event_editor_runner.gd'; Marker = '雷达事件编辑辅助回归完成：.+0 项失败。'; Label = '雷达事件编辑辅助回归' },
    @{ Script = 'res://tests/radar_event_level_runner.gd'; Marker = '第十五关回归完成：.+0 项失败。'; Label = '第十五关回归' },
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
    @{ Script = 'res://tests/window_resolution_ui_runner.gd'; Marker = '窗口分辨率界面回归完成：.+0 项失败。'; Label = '窗口分辨率界面回归' },
    @{ Script = 'res://tests/settings_runner.gd'; Marker = '设置回归完成：.+0 项失败。'; Label = '设置回归' },
    @{ Script = 'res://tests/settings_open_layout_runner.gd'; Marker = '设置开放布局回归完成：.+0 项失败。'; Label = '设置开放布局回归' },
    @{ Script = 'res://tests/about_game_runner.gd'; Marker = '关于游戏回归完成：.+0 项失败。'; Label = '关于游戏回归' },
    @{ Script = 'res://tests/hong_kong_locale_runner.gd'; Marker = '香港繁体回归完成：.+0 项失败。'; Label = '香港繁体回归' },
    @{ Script = 'res://tests/progress_reset_runner.gd'; Marker = '进度清除回归完成：.+0 项失败。'; Label = '进度清除回归' },
    @{ Script = 'res://tests/user_level_reset_runner.gd'; Marker = '用户关卡清除回归完成：.+0 项失败。'; Label = '用户关卡清除回归' },
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
    @{ Script = 'res://tests/full_size_preview_runner.gd'; Marker = '全尺寸预览回归完成：.+0 项失败。'; Label = '全尺寸预览回归' },
    @{ Script = 'res://tests/full_preview_feedback_runner.gd'; Marker = '全尺寸结果药丸回归完成：.+0 项失败。'; Label = '全尺寸结果反馈回归' },
    @{ Script = 'res://tests/layout_runner.gd'; Marker = '布局回归完成：.+0 项失败。'; Label = '布局回归' }
)
foreach ($check in $gameChecks) {
    # 交互回归等待真实动画与弹窗时长，限制帧率并留足帧预算，避免 headless 提前退出。
    $timingArguments = if ($check.Script -in @('res://tests/window_resolution_ui_runner.gd', 'res://tests/startup_runner.gd', 'res://tests/about_game_runner.gd', 'res://tests/settings_open_layout_runner.gd', 'res://tests/menu_background_ui_runner.gd', 'res://tests/assembly_viewport_runner.gd', 'res://tests/editor_time_limit_runner.gd', 'res://tests/editor_enemy_canvas_runner.gd', 'res://tests/editor_enemy_ui_runner.gd', 'res://tests/editor_exit_dialog_runner.gd', 'res://tests/map_editor_endpoints_runner.gd', 'res://tests/map_editor_rectangle_runner.gd', 'res://tests/map_editor_viewport_runner.gd', 'res://tests/map_editor_toolbar_runner.gd', 'res://tests/code_color_ui_runner.gd', 'res://tests/code_color_editor_runner.gd', 'res://tests/code_hint_ui_runner.gd', 'res://tests/functions_ui_runner.gd', 'res://tests/inline_completion_runner.gd', 'res://tests/game_ui_smoke.gd', 'res://tests/layout_runner.gd', 'res://tests/glass_tooltip_runner.gd', 'res://tests/full_size_preview_runner.gd', 'res://tests/full_preview_feedback_runner.gd')) { @('--max-fps', '120', '--quit-after', '7200') } elseif ($check.Script -eq 'res://tests/level_search_runner.gd') { @('--max-fps', '120', '--quit-after', '2400') } else { @('--quit-after', '600') }
    $result = Invoke-GodotCheck (@('--headless', '--path', $projectPath) + $timingArguments + @('--script', $check.Script))
    Write-Host $result.Output
    if ($result.ExitCode -ne 0 -or $result.Output -match '(?m)^ERROR:|SCRIPT ERROR:|Parse Error:|Compilation failed' -or $result.Output -notmatch $check.Marker) {
        throw ($check.Label + '失败。')
    }
}
