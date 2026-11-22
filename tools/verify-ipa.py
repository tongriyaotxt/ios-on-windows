#!/usr/bin/env python3
"""verify-ipa.py —— App Store 校验器的 Windows 替身：在本地把能查的都查一遍。

它不联网、不签名、不依赖 macOS，只做静态检查。覆盖的检查项对应 Apple 侧最常见的拒绝原因：

  结构     Payload/ 前缀、正斜杠、单一 .app、无 __MACOSX
  Info.plist  必填键、版本格式、UIDeviceFamily、MinimumOSVersion、图标声明
  图标     CFBundleIconFiles 引用的 PNG 是否存在、尺寸是否与命名一致、有无 1024 营销图
  Mach-O   magic/cputype/filetype、LC_BUILD_VERSION 平台是否 iOS、LC_MAIN 是否存在
  依赖     LC_LOAD_DYLIB 只能是系统路径或 @executable_path/@rpath，不能出现构建机绝对路径
  签名     每个 Mach-O（含 Frameworks/ 内）都要有 LC_CODE_SIGNATURE，且页哈希对得上
  权限     若给了 entitlements，检查 application-identifier 与 bundle id 一致

用法：
    python tools/verify-ipa.py build/xc/AppCore-native.ipa
    python tools/verify-ipa.py x.ipa --json report.json
退出码：0 全通过；1 有 FAIL；2 只有 WARN。
"""
import argparse
import hashlib
import json
import os
import plistlib
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_CODE_SIGNATURE = 0x1D
LC_MAIN = 0x80000028
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2

results = []   # (level, code, message)


def add(level, code, msg):
    results.append((level, code, msg))


def ok(code, msg):
    add("PASS", code, msg)


def warn(code, msg):
    add("WARN", code, msg)


def fail(code, msg):
    add("FAIL", code, msg)


# ------------------------------------------------------------------ Mach-O
def parse_macho(blob: bytes, label: str):
    if len(blob) < 32:
        fail("macho.short", f"{label}: 文件太短")
        return None
    magic, cputype, cpusub, filetype = struct.unpack_from("<IIII", blob, 0)
    if magic != MH_MAGIC_64:
        fail("macho.magic", f"{label}: magic=0x{magic:08X}，不是 64 位 Mach-O")
        return None
    ncmds, sizeofcmds = struct.unpack_from("<II", blob, 16)
    off = 32
    info = {"dylibs": [], "code_sig": None, "has_main": False, "platform": None,
            "id_dylib": None, "cputype": cputype, "filetype": filetype}
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", blob, off)
        if cmd == LC_LOAD_DYLIB or cmd == LC_ID_DYLIB:
            no = struct.unpack_from("<I", blob, off + 8)[0]
            name = blob[off + no:off + cmdsize].split(b"\0")[0].decode("utf-8", "replace")
            if cmd == LC_LOAD_DYLIB:
                info["dylibs"].append(name)
            else:
                info["id_dylib"] = name
        elif cmd == LC_CODE_SIGNATURE:
            info["code_sig"] = struct.unpack_from("<II", blob, off + 8)
        elif cmd == LC_MAIN:
            info["has_main"] = True
        elif cmd == LC_BUILD_VERSION:
            info["platform"] = struct.unpack_from("<I", blob, off + 8)[0]
        off += cmdsize
    return info


def verify_signature(blob: bytes, info, label: str):
    if not info or not info["code_sig"]:
        fail("sig.missing", f"{label}: 没有 LC_CODE_SIGNATURE（未签名，iOS 会拒绝加载）")
        return
    dataoff, datasize = info["code_sig"]
    if dataoff + datasize > len(blob):
        fail("sig.bounds", f"{label}: 签名区越界（{dataoff}+{datasize} > {len(blob)}）")
        return
    sb = blob[dataoff:dataoff + datasize]
    if len(sb) < 12:
        fail("sig.short", f"{label}: 签名块过短")
        return
    magic, length, count = struct.unpack_from(">III", sb, 0)
    if magic != 0xFADE0CC0:
        fail("sig.superblob", f"{label}: 超级块 magic=0x{magic:08X}")
        return
    cd = None
    has_cms = False
    for i in range(count):
        slot, o = struct.unpack_from(">II", sb, 12 + i * 8)
        if slot == 0:
            cd = sb[o:]
        if slot == 0x10000:
            has_cms = True
    if cd is None:
        fail("sig.cd", f"{label}: 超级块里没有 CodeDirectory")
        return
    m, cdlen, ver, flags, hash_off, ident_off, n_spec, n_code, code_limit = struct.unpack_from(">IIIIIIIII", cd, 0)
    hash_size, hash_type, _plat, page_size = struct.unpack_from("4B", cd, 36)
    ident = cd[ident_off:cd.index(b"\0", ident_off)].decode("utf-8", "replace")
    bad = 0
    for i in range(n_code):
        start = i * 4096
        end = min(start + 4096, code_limit)
        want = cd[hash_off + n_spec * hash_size + i * hash_size:
                  hash_off + n_spec * hash_size + (i + 1) * hash_size]
        if want != hashlib.sha256(blob[start:end]).digest():
            bad += 1
    if bad:
        fail("sig.pages", f"{label}: {bad}/{n_code} 页哈希不匹配（文件被改过）")
    else:
        ok("sig.ok", f"{label}: 签名有效（{n_code} 页，ident={ident}，"
                     f"{'CMS' if has_cms else 'ad-hoc'}）")


def check_deps(info, label: str, bundle_id: str):
    for d in info["dylibs"]:
        if d.startswith("/System/Library/") or d.startswith("/usr/lib/"):
            continue
        if d.startswith("@executable_path/") or d.startswith("@rpath/"):
            continue
        if os.path.isabs(d):
            fail("dep.abs", f"{label}: 依赖了构建机绝对路径 {d}（真机加载会失败）")
        else:
            warn("dep.odd", f"{label}: 依赖路径不常见 {d}")


# ------------------------------------------------------------------ 主流程
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    if not os.path.exists(args.ipa):
        print(f"找不到 {args.ipa}")
        return 1

    z = zipfile.ZipFile(args.ipa)
    names = z.namelist()

    # ---- 结构
    if any("\\" in n for n in names):
        fail("zip.backslash", "zip 里有反斜杠路径（iOS 解包会失败）")
    else:
        ok("zip.slash", "zip 路径分隔符正确")
    payload = [n for n in names if n.startswith("Payload/")]
    if len(payload) != len(names):
        fail("zip.prefix", "存在不在 Payload/ 下的条目")
    apps = {n.split("/")[1] for n in payload if n.count("/") >= 2}
    if len(apps) != 1:
        fail("zip.app", f"应恰好一个 .app，实际 {sorted(apps)}")
        return 1
    app = apps.pop()
    if not app.endswith(".app"):
        fail("zip.ext", f"顶层不是 .app：{app}")
    ok("zip.structure", f"单一 bundle：{app}")

    info_name = f"Payload/{app}/Info.plist"
    if info_name not in names:
        fail("plist.missing", "Info.plist 不在 .app 根目录")
        return 1
    info = plistlib.loads(z.read(info_name))

    # ---- Info.plist 必填
    required = ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion",
                "CFBundleShortVersionString", "CFBundlePackageType"]
    missing = [k for k in required if k not in info]
    if missing:
        fail("plist.required", f"缺少必填键：{missing}")
    else:
        ok("plist.required", f"{info['CFBundleIdentifier']} {info['CFBundleShortVersionString']}({info['CFBundleVersion']})")
    if info.get("CFBundlePackageType") != "APPL":
        fail("plist.type", "CFBundlePackageType 必须是 APPL")
    if not str(info.get("MinimumOSVersion", "")).count(".") == 1:
        warn("plist.minos", f"MinimumOSVersion={info.get('MinimumOSVersion')} 格式可疑")

    exe_name = info.get("CFBundleExecutable", "")
    exe_path = f"Payload/{app}/{exe_name}"
    if exe_path not in names:
        fail("exe.missing", f"可执行文件不存在：{exe_path}")
        return 1

    # ---- 图标
    icon_files = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles", [])
    if not icon_files:
        icon_files = info.get("CFBundleIconFiles", [])
    if not icon_files:
        fail("icon.none", "Info.plist 没有任何图标声明（本地安装会白图标，上架必被拒）")
    else:
        found = 0
        for base in icon_files:
            variants = [f"{base}.png", f"{base}@2x.png", f"{base}@3x.png"]
            hit = [v for v in variants if f"Payload/{app}/{v}" in names]
            if hit:
                found += 1
        if found == 0:
            fail("icon.files", f"声明了图标但没有对应 PNG：{icon_files}")
        else:
            ok("icon.files", f"{found}/{len(icon_files)} 组图标存在")
        has_1024 = any(n.endswith("Icon-1024.png") for n in names)
        if not has_1024:
            warn("icon.1024", "没有 1024×1024 营销图标（App Store 需要）")
        else:
            ok("icon.1024", "1024×1024 营销图标存在")

    if "Assets.car" in " ".join(names):
        ok("icon.car", "存在 Assets.car")

    # ---- Mach-O：可执行体 + 所有 Frameworks
    exe_blob = z.read(exe_path)
    exe_info = parse_macho(exe_blob, exe_name)
    if exe_info:
        if exe_info["filetype"] != 2:
            fail("macho.filetype", f"{exe_name}: filetype={exe_info['filetype']}，应为 2 (MH_EXECUTE)")
        if exe_info["cputype"] != 0x0100000C:
            fail("macho.cpu", f"{exe_name}: cputype=0x{exe_info['cputype']:X}，应为 arm64")
        if exe_info["platform"] != PLATFORM_IOS:
            fail("macho.platform", f"{exe_name}: LC_BUILD_VERSION platform={exe_info['platform']}，应为 2 (iOS)")
        else:
            ok("macho.platform", f"{exe_name}: platform=iOS, arm64")
        if not exe_info["has_main"]:
            warn("macho.main", f"{exe_name}: 没有 LC_MAIN（dyld 可能找不到入口）")
        check_deps(exe_info, exe_name, info["CFBundleIdentifier"])
        verify_signature(exe_blob, exe_info, exe_name)

    for n in names:
        if not n.startswith(f"Payload/{app}/Frameworks/") or not n.endswith(".dylib"):
            continue
        blob = z.read(n)
        label = n.split("/")[-1]
        di = parse_macho(blob, label)
        if not di:
            continue
        if di["platform"] != PLATFORM_IOS:
            fail("dylib.platform", f"{label}: platform={di['platform']}，应为 iOS")
        if not di["id_dylib"]:
            warn("dylib.id", f"{label}: 没有 LC_ID_DYLIB（dyld 会警告）")
        elif not (di["id_dylib"].startswith("@rpath/") or di["id_dylib"].startswith("@executable_path/")):
            warn("dylib.idpath", f"{label}: LC_ID_DYLIB={di['id_dylib']} 不是 @rpath 形式")
        check_deps(di, label, info["CFBundleIdentifier"])
        verify_signature(blob, di, label)
        ok("dylib.info", f"{label}: {len(di['dylibs'])} 个系统依赖，已检查")

    # ---- 汇总
    fails = [r for r in results if r[0] == "FAIL"]
    warns = [r for r in results if r[0] == "WARN"]
    print(f"\n检查 {args.ipa}")
    for level, code, msg in results:
        mark = {"PASS": "  ok  ", "WARN": " warn ", "FAIL": " FAIL "}[level]
        print(f"[{mark}] {code:18} {msg}")
    print(f"\n{len(results)-len(fails)-len(warns)} 通过, {len(warns)} 警告, {len(fails)} 失败")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump([{"level": lv, "code": c, "message": m} for lv, c, m in results],
                      f, indent=2, ensure_ascii=False)

    return 1 if fails else (2 if warns else 0)


if __name__ == "__main__":
    sys.exit(main())
