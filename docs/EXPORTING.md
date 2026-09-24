# 应用图标与正式导出

应用图标保存在 `assets/app/`，独立于游戏界面的 `assets/ui/workshop.svg`：

- `app_icon.svg`：现有矢量图标的独立副本。
- `app_icon.png`：1024×1024 通用项目图标，保留透明圆角。
- `app_icon.icns`：macOS 图标，包含 16 至 1024 像素及 Retina 尺寸。
- `app_icon.ico`：Windows 图标，包含 16、24、32、48、64、128、256 像素。

`project.godot` 已配置通用图标及两种原生图标。macOS 导出预设的「应用 → 图标」指向 ICNS；Windows Desktop 预设指向 ICO。macOS 的「液态玻璃图标」是另一种可选格式，本项目使用普通 ICNS 图标。导出前需安装与当前 Godot 版本匹配、对应平台的导出模板。

## 去掉标题中的 DEBUG

Godot 调试构建会自动在窗口标题后添加 `(DEBUG)`。发布时点击「导出项目」，在保存窗口中取消勾选「Export With Debug / 导出时包含调试」。`debug/export_console_wrapper` 只控制控制台包装，不控制标题后缀；无需在游戏脚本中修改标题。

也可以在项目目录使用正式发布命令（先创建输出目录）：

```sh
godot --headless --path . --export-release "macOS" /绝对输出目录/ProgrammableModule.zip
godot --headless --path . --export-release "Windows Desktop" /绝对输出目录/ProgrammableModule.exe
```

`godot` 可替换为本机 Godot 可执行文件路径。编辑器运行仍然属于调试构建。

## 重新生成图标

目前已提供可直接用于导出的文件，不需要每次导出时重新生成。若将来修改了主菜单矢量图标，可在项目目录执行：

```sh
godot --headless --path . --script res://tools/build_app_icons.gd -- /绝对中间文件目录
python3 tools/package_app_icons.py /绝对中间文件目录
```

各尺寸均从原 SVG 直接栅格化；Python 只封装已有 PNG 字节。ICNS 打包使用 macOS 自带 `iconutil`；其他平台可加 `--ico-only` 仅更新 ICO。中间目录应放在项目之外。

官方参考：[macOS 导出](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_macos.html)、[Windows 导出](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_windows.html)、[Godot 4.7 窗口调试标题实现](https://github.com/godotengine/godot/blob/4.7/scene/main/window.cpp#L3091-L3101)。
