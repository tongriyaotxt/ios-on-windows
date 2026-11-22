#!/usr/bin/env python3
"""make-icons.py —— 只用标准库生成 iOS App 图标全套尺寸，并给出 Info.plist 需要的键值。

为什么自己写：`actool` 是 macOS 二进制，而 App Store 校验里「缺图标」是硬错误（ITMS-90022）。
iOS 除了 Assets.car 之外，仍然支持 CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles
的「散装 PNG」路径：文件放在 .app 根目录，名字写进 Info.plist 即可。本地安装、ad-hoc、OTA 都认。

用法：
    python tools/make-icons.py --out AppCore.app --color 0A84FF --label A
输出：Icon-20.png … Icon-1024.png + icons.json（供构建脚本写进 Info.plist）
"""
import argparse
import json
import os
import struct
import sys
import zlib

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


# iOS 需要的尺寸（文件名 -> 像素），沿用 Apple 的 Icon-<pt>[@2x|@3x] 命名
SIZES = [
    ("Icon-20", 20), ("Icon-20@2x", 40), ("Icon-20@3x", 60),
    ("Icon-29", 29), ("Icon-29@2x", 58), ("Icon-29@3x", 87),
    ("Icon-40", 40), ("Icon-40@2x", 80), ("Icon-40@3x", 120),
    ("Icon-60@2x", 120), ("Icon-60@3x", 180),
    ("Icon-76", 76), ("Icon-76@2x", 152),
    ("Icon-83.5@2x", 167),
    ("Icon-1024", 1024),
]


def png_bytes(width: int, height: int, rgb: tuple, label: str = "") -> bytes:
    """极简 PNG 编码器：RGBA，圆角方块 + 中间一条对比色横杠（仅作视觉标识）。"""
    r, g, b = rgb
    rows = []
    cx, cy = width / 2, height / 2
    radius = min(width, height) * 0.42
    bar_h = max(2, height // 12)
    bar_w = max(4, int(width * 0.5))
    for y in range(height):
        row = bytearray([0])  # filter type 0
        for x in range(width):
            # 圆角判断（简单距离场）
            dx = abs(x - cx) - (radius - width * 0.08)
            dy = abs(y - cy) - (radius - height * 0.08)
            inside = (dx if dx > 0 else 0) ** 2 + (dy if dy > 0 else 0) ** 2 <= (width * 0.08) ** 2
            if not inside and (abs(x - cx) > radius * 0.92 or abs(y - cy) > radius * 0.92):
                row += bytes((0, 0, 0, 0))
                continue
            in_bar = abs(y - cy) <= bar_h / 2 and abs(x - cx) <= bar_w / 2
            if in_bar:
                row += bytes((255, 255, 255, 255))
            else:
                # 轻微渐变，避免纯色看起来像坏图
                k = 1.0 - (y / max(1, height)) * 0.25
                row += bytes((int(r * k), int(g * k), int(b * k), 255))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
            chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help=".app 目录")
    ap.add_argument("--color", default="0A84FF", help="主色，RRGGBB")
    ap.add_argument("--label", default="", help="保留字段（当前不使用字体）")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    rgb = tuple(int(args.color[i:i + 2], 16) for i in (0, 2, 4))

    written = []
    seen = set()
    for name, px in SIZES:
        if px in seen:      # 同尺寸只写一次（iOS 允许一个文件服务多个槽位）
            continue
        seen.add(px)
        path = os.path.join(args.out, f"{name}.png")
        with open(path, "wb") as f:
            f.write(png_bytes(px, px, rgb, args.label))
        written.append({"name": f"{name}.png", "pixels": px})

    # Info.plist 里 CFBundleIconFiles 用的是不带 @2x/@3x 的「基名」
    icon_files = sorted({n.split("@")[0] for n, _ in SIZES})
    manifest = {
        "files": written,
        "CFBundleIconFiles": icon_files,
        "CFBundlePrimaryIconFiles": ["Icon-60", "Icon-60@2x", "Icon-60@3x"],
        "CFBundleIconName": None,          # 没有 Assets.car 时不要写这个键
    }
    with open(os.path.join(args.out, "icons.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    total = sum(os.path.getsize(os.path.join(args.out, w["name"])) for w in written)
    print(f"icons: {len(written)} files, {total/1024:.1f} KB -> {args.out}")
    print(f"  CFBundleIconFiles = {icon_files}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
