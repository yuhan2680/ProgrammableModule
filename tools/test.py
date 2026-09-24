#!/usr/bin/env python3
"""macOS/Linux/Windows 的回归入口；与 test.ps1 一样检查完成标记及引擎错误。"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


# 用途：在独立进程中运行每套测试，脚本异常即使退出码为零也不能被误报为通过。
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default=os.environ.get('GODOT_BIN'))
    args = parser.parse_args()
    engine = args.godot or shutil.which('godot') or shutil.which('godot4')
    if not engine:
        parser.error('请用 --godot 指定 Godot 4.5+ 的可执行文件。')
    project = Path(__file__).resolve().parents[1]
    stages = [('import', ['--editor', '--import'], None)]
    for filename, marker in [
        ('startup_runner', r'启动加载回归完成：.+0 项失败。'),
        ('radar_event_parser_runner', r'雷达事件语法回归完成：.+0 项失败。'),
        ('radar_event_runtime_runner', r'雷达事件运行时回归完成：.+0 项失败。'),
        ('radar_event_editor_runner', r'雷达事件编辑辅助回归完成：.+0 项失败。'),
        ('radar_event_level_runner', r'第十五关回归完成：.+0 项失败。'),
        ('for_language_runner', r'有限 for 循环语言回归完成：.+0 项失败。'),
        ('eight_direction_world_runner', r'八方向分波世界回归完成：.+0 项失败。'),
        ('ambush_level_runner', r'第十三关回归完成：.+0 项失败。'),
        ('eight_direction_level_runner', r'第十二关回归完成：.+0 项失败。'),

        ('random_language_runner', r'随机语言回归完成：.+0 项失败。'),
        ('random_level_runner', r'随机关卡回归完成：.+0 项失败。'),
        ('radar_pursuit_level_runner', r'第十关追猎回归完成：.+0 项失败。'),
        ('code_color_ui_runner', r'代码颜色界面回归完成：.+0 项失败。'),
        ('code_color_editor_runner', r'代码配色编辑器回归完成：.+0 项失败。'),
        ('code_color_settings_runner', r'代码颜色设置回归完成：.+0 项失败。'),
        ('player_radar_level_runner', r'玩家雷达教学回归完成：.+0 项失败。'),
        ('radar_language_runner', r'玩家雷达语言回归完成：.+0 项失败。'),
        ('player_radar_world_runner', r'玩家雷达底层回归完成：.+0 项失败。'),
        ('variables_language_runner', r'常变量语言回归完成：.+0 项失败。'),
        ('code_hint_runner', r'代码提示回归完成：.+0 项失败。'),
        ('hint_attempt_runner', r'提示次数回归完成：.+0 项失败。'),
        ('code_hint_ui_runner', r'代码提示界面回归完成：.+0 项失败。'),
        ('headless_runner', r'回归完成：.+0 项失败。'),
        ('editor_smoke', r'编辑器冒烟完成：.+0 项失败。'),
        ('language_runner', r'语言回归完成：.+0 项失败。'),
        ('gameplay_runner', r'游戏回归完成：.+0 项失败。'),
        ('settings_runner', r'设置回归完成：.+0 项失败。'),
        ('progress_reset_runner', r'进度清除回归完成：.+0 项失败。'),
        ('user_level_reset_runner', r'用户关卡清除回归完成：.+0 项失败。'),
        ('command_catalog_runner', r'指令资料回归完成：.+0 项失败。'),
        ('game_ui_smoke', r'游戏界面冒烟完成：.+0 项失败。'),
        ('campaign_runner', r'关卡与战斗回归完成：.+0 项失败。'),
        ('projectile_collision_runner', r'弹道碰撞回归完成：.+0 项失败。'),
        ('shooting_level_runner', r'第四关回归完成：.+0 项失败。'),
        ('prison_world_runner', r'监狱底层回归完成：.+0 项失败。'),
        ('prison_level_runner', r'第五关回归完成：.+0 项失败。'),
        ('staircase_level_runner', r'第六关回归完成：.+0 项失败。'),
        ('pursuit_world_runner', r'追击底层回归完成：.+0 项失败。'),
        ('pursuit_level_runner', r'第七关回归完成：.+0 项失败。'),
        ('functions_language_runner', r'函数语言回归完成：.+0 项失败。'),
        ('dodge_level_runner', r'第十一关回归完成：.+0 项失败。'),
        ('radar_lunge_world_runner', r'雷达突袭底层回归完成：.+0 项失败。'),
        ('functions_ui_runner', r'函数教学界面回归完成：.+0 项失败。'),
        ('level_search_runner', r'关卡搜索回归完成：.+0 项失败。'),
        ('layout_runner', r'布局回归完成：.+0 项失败。'),
    ]:
        # 交互回归等待真实动画与弹窗时长，限制帧率并留足帧预算，避免 headless 提前退出。
        if filename in ('startup_runner', 'code_color_ui_runner', 'code_color_editor_runner', 'code_hint_ui_runner', 'level_search_runner', 'game_ui_smoke', 'functions_ui_runner'):
            timing = ['--max-fps', '120', '--quit-after', '2400' if filename == 'level_search_runner' else '7200']
        else:
            timing = ['--quit-after', '600']
        stages.append((filename, [*timing, '--script', f'res://tests/{filename}.gd'], marker))
    with tempfile.TemporaryDirectory(prefix='module_ui_tests_') as directory:
        for name, options, marker in stages:
            command = [engine, '--headless', '--path', str(project), '--log-file', str(Path(directory)/f'{name}.log'), *options]
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            except (OSError, subprocess.TimeoutExpired) as error:
                print(f'{name}: {error}', file=sys.stderr)
                return 1
            output = result.stdout + result.stderr
            found = re.search(marker, output) if marker else None
            if result.returncode or re.search(r'(?m)^ERROR:|SCRIPT ERROR:|Parse Error:|Compilation failed|Failed loading resource:', output) or (marker and not found):
                print(f'{name}: FAILED\n{output}', file=sys.stderr)
                return 1
            print(f'{name}: {found.group(0) if found else "OK"}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
