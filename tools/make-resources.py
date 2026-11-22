#!/usr/bin/env python3
"""make-resources.py —— 生成 `_CodeSignature/CodeResources`（资源信封）。

codesign 会把 bundle 里每个非代码文件记一笔哈希，安装/启动时用来确认「资源没被改」。
缺这个文件时，部分 iOS 版本会判 bundle 不完整（`code object is not signed at all`）。

这里生成 v2 结构的简化版：
    files2[相对路径] = {hash2: <SHA-1>}
规则：跳过可执行体本身、`Frameworks/` 下的嵌套代码（它们各自有签名）、`_CodeSignature/`。

用法：
    python tools/make-resources.py --app build/xc/AppCore.work/AppCore.app
"""
import argparse
import hashlib
import os
import plistlib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    args = ap.parse_args()

    app = args.app
    exe = None
    plist_path = os.path.join(app, "Info.plist")
    if os.path.exists(plist_path):
        with open(plist_path, "rb") as f:
            exe = plistlib.load(f).get("CFBundleExecutable")

    files2 = {}
    for root, dirs, names in os.walk(app):
        dirs[:] = [d for d in dirs if d not in ("_CodeSignature", "Frameworks")]
        for n in names:
            full = os.path.join(root, n)
            rel = os.path.relpath(full, app).replace(os.sep, "/")
            if rel == exe:
                continue
            with open(full, "rb") as f:
                files2[rel] = {"hash2": hashlib.sha1(f.read()).digest()}

    envelope = {
        "files": {},
        "files2": files2,
        "rules": {
            "^": True,
            "^.*\\.lproj/": True,
            "^.*\\.lproj/locversion.plist$": True,
        },
        "rules2": {
            "^.*": True,
            "^.*\\.lproj/": True,
        },
    }
    out_dir = os.path.join(app, "_CodeSignature")
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "CodeResources"), "wb") as f:
        plistlib.dump(envelope, f)

    print(f"CodeResources: {len(files2)} 个资源 -> {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
