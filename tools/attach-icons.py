#!/usr/bin/env python3
"""attach-icons.py —— 把 make-icons.py 生成的图标写进 Info.plist 的 CFBundleIcons。

iOS 认的键结构：
    CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles: [Icon-60, Icon-60@2x, Icon-60@3x]
    CFBundleIconFiles（旧路径，兜底）: [Icon-20, Icon-29, …]
注意：没有 Assets.car 时**不要**写 CFBundleIconName，否则系统会去资产目录里找而找不到。
"""
import argparse
import json
import os
import plistlib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, help=".app 目录")
    ap.add_argument("--icons", default=None, help="icons.json（默认在 .app 里）")
    args = ap.parse_args()

    icons_path = args.icons or os.path.join(args.app, "icons.json")
    with open(icons_path, encoding="utf-8") as f:
        icons = json.load(f)

    plist_path = os.path.join(args.app, "Info.plist")
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)

    info["CFBundleIcons"] = {
        "CFBundlePrimaryIcon": {
            "CFBundleIconFiles": icons["CFBundlePrimaryIconFiles"],
            "CFBundleIconName": "",
        }
    }
    info["CFBundleIconFiles"] = icons["CFBundleIconFiles"]
    info.pop("CFBundleIconName", None)

    with open(plist_path, "wb") as f:
        plistlib.dump(info, f)

    print(f"Info.plist: CFBundleIcons 已写入（{len(icons['CFBundleIconFiles'])} 组）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
