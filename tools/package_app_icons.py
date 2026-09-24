#!/usr/bin/env python3
"""将 Godot 直接栅格化的 PNG 封装为原生图标，不修改图像像素。"""

import argparse
from pathlib import Path
import shutil
import struct
import subprocess

ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)


# 读取并校验既有 PNG 的原生尺寸和 RGBA 通道，不进行图像转换。
def read_png(path: Path, expected_size: int) -> bytes:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"不是有效 PNG：{path}")
    width, height, depth, color = struct.unpack(">IIBB", data[16:26])
    if (width, height, depth, color) != (expected_size, expected_size, 8, 6):
        raise ValueError(f"PNG 必须是 {expected_size}×{expected_size}、8 位 RGBA：{path}")
    return data


# 把各尺寸原始 PNG 字节装入 Windows ICO 的目录表和数据段。
def package_ico(staging: Path, destination: Path) -> None:
    images = [(size, read_png(staging / f"icon_{size}.png", size)) for size in ICO_SIZES]
    header = struct.pack("<HHH", 0, 1, len(images))
    entries = bytearray()
    offset = len(header) + 16 * len(images)
    for size, data in images:
        dimension = 0 if size == 256 else size
        entries.extend(struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    destination.write_bytes(header + entries + b"".join(data for _, data in images))


# 使用 macOS 原生打包器生成包含 Retina 尺寸的 ICNS 文件。
def package_icns(staging: Path, destination: Path) -> None:
    iconutil = shutil.which("iconutil")
    if iconutil is None:
        raise RuntimeError("生成 ICNS 需要在 macOS 上运行 iconutil；Windows 可使用 --ico-only。")
    subprocess.run(
        [iconutil, "--convert", "icns", "--output", str(destination), str(staging / "app_icon.iconset")],
        check=True,
    )


# 接收外部中间文件目录，默认将原生图标写入项目独立资源目录。
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("staging_directory", type=Path)
    parser.add_argument("--output-directory", type=Path, default=Path(__file__).resolve().parents[1] / "assets" / "app")
    parser.add_argument("--ico-only", action="store_true", help="只重建 Windows ICO，不调用 macOS iconutil。")
    args = parser.parse_args()
    staging = args.staging_directory.resolve()
    destination = args.output_directory.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    package_ico(staging, destination / "app_icon.ico")
    if not args.ico_only:
        package_icns(staging, destination / "app_icon.icns")
    print(f"原生应用图标已生成：{destination}")


if __name__ == "__main__":
    main()
