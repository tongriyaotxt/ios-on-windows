#!/usr/bin/env python3
"""audit-device.py —— 「这包能不能在真 iPhone 上起来」的静态审计。

verify-ipa.py 查的是「包结构对不对」，本脚本查的是**启动链路**：
内核怎么加载它、dyld 怎么初始化、amfid 怎么验签、UIKit 怎么接管。

每条结论都带证据（从二进制里读出来的字段），并区分：
    FATAL  几乎必然启动失败
    HIGH   很可能失败 / 只在特定 iOS 版本失败
    MED    能装但行为可能不对
    INFO   仅影响工具链观察，不影响运行
"""
import argparse
import os
import plistlib
import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_DYLINKER = 0xE
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
LC_MAIN = 0x80000028
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_EXPORTS_TRIE = 0x80000033
CSSLOT_INFOSLOT = 1
CSSLOT_REQUIREMENTS = 2
CSSLOT_ENTITLEMENTS = 5

findings = []
TARGET = "device"


def add(sev, code, msg, fix=""):
    findings.append({"sev": sev, "code": code, "msg": msg, "fix": fix})


def parse_macho(blob, label):
    """返回 load command 摘要"""
    magic, cputype, cpusub, filetype = struct.unpack_from("<IIII", blob, 0)
    if magic != MH_MAGIC_64:
        return None
    ncmds, sizeofcmds = struct.unpack_from("<II", blob, 16)
    off = 32
    segs, dylibs, misc = [], [], {}
    while off < 32 + sizeofcmds:
        cmd, cmdsize = struct.unpack_from("<II", blob, off)
        if cmd == LC_SEGMENT_64:
            name = blob[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", blob, off + 24)
            nsects = struct.unpack_from("<I", blob, off + 64)[0]
            secs = []
            so = off + 72
            for _ in range(nsects):
                sname = blob[so:so + 16].rstrip(b"\0").decode()
                sseg = blob[so + 16:so + 32].rstrip(b"\0").decode()
                addr, size = struct.unpack_from("<QQ", blob, so + 32)
                offset = struct.unpack_from("<I", blob, so + 48)[0]
                align = struct.unpack_from("<I", blob, so + 52)[0]
                secs.append({"name": sname, "seg": sseg, "addr": addr, "size": size,
                             "offset": offset, "align": align})
                so += 80
            segs.append({"name": name, "vmaddr": vmaddr, "vmsize": vmsize,
                         "fileoff": fileoff, "filesize": filesize, "sects": secs})
        elif cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB):
            no = struct.unpack_from("<I", blob, off + 8)[0]
            nm = blob[off + no:off + cmdsize].split(b"\0")[0].decode()
            dylibs.append((cmd, nm))
        elif cmd == LC_BUILD_VERSION:
            plat, minos, sdk, ntools = struct.unpack_from("<IIII", blob, off + 8)
            misc["platform"] = plat
            misc["minos"] = f"{minos >> 16}.{minos & 0xffff}"
            misc["sdk"] = f"{sdk >> 16}.{sdk & 0xffff}"
        elif cmd == LC_MAIN:
            misc["entryoff"] = struct.unpack_from("<Q", blob, off + 8)[0]
        elif cmd == LC_CODE_SIGNATURE:
            misc["codesig"] = struct.unpack_from("<II", blob, off + 8)
        elif cmd == LC_LOAD_DYLINKER:
            no = struct.unpack_from("<I", blob, off + 8)[0]
            misc["dylinker"] = blob[off + no:off + cmdsize].split(b"\0")[0].decode()
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_DYLD_CHAINED_FIXUPS, LC_DYLD_EXPORTS_TRIE):
            misc.setdefault("dyld_info", []).append(hex(cmd))
        elif cmd == LC_SYMTAB:
            misc["symtab"] = True
        elif cmd == LC_UUID:
            misc["uuid"] = blob[off + 8:off + 24].hex()
        off += cmdsize
    return {"filetype": filetype, "segs": segs, "dylibs": dylibs, "misc": misc,
            "sizeofcmds": sizeofcmds}


def audit_macho(blob, label, is_exec):
    m = parse_macho(blob, label)
    if not m:
        add("FATAL", "macho.parse", f"{label}: 不是 64 位 Mach-O")
        return
    misc = m["misc"]
    segnames = [s["name"] for s in m["segs"]]

    if is_exec:
        if "dylinker" not in misc:
            add("FATAL", "exec.dylinker",
                f"{label}: 缺 LC_LOAD_DYLINKER（内核会把它当静态可执行文件，dyld 根本不会运行）",
                "machogen 增加 LC_LOAD_DYLINKER /usr/lib/dyld")
        else:
            add("INFO", "exec.dylinker", f"{label}: LC_LOAD_DYLINKER={misc['dylinker']}")
        if "entryoff" not in misc:
            add("FATAL", "exec.main", f"{label}: 缺 LC_MAIN，dyld 找不到入口")
        if "__DATA" not in segnames and "__DATA_CONST" not in segnames:
            add("HIGH", "exec.data",
                f"{label}: 没有 __DATA 段（{segnames}）——带 PAC/指针认证的设备可能拒绝映射",
                "machogen 增加一个空的 __DATA 段")
        if "symtab" not in misc:
            add("MED", "exec.symtab", f"{label}: 没有 LC_SYMTAB（不影响启动，影响崩溃符号化）")
        if "dyld_info" not in misc:
            add("HIGH", "exec.dyldinfo",
                f"{label}: 既无 LC_DYLD_INFO_ONLY 也无 chained fixups —— dyld 无法建立绑定表",
                "有外部符号时必须带绑定信息；无符号时可接受")

    # 段对齐：__TEXT/__DATA 的 fileoff 与 vmsize 必须按页对齐（arm64: 16KB）
    for s in m["segs"]:
        if s["name"] == "__PAGEZERO":
            continue
        if s["fileoff"] % 0x4000 and s["name"] != "__LINKEDIT":
            add("HIGH", "seg.align",
                f"{label}: {s['name']} fileoff=0x{s['fileoff']:X} 未按 16KB 对齐（dyld: malformed mach-o）",
                "把每个段起点对齐到 0x4000")
        if s["filesize"] and s["filesize"] % 0x1000:
            add("MED", "seg.filesize",
                f"{label}: {s['name']} filesize=0x{s['filesize']:X} 不是页的整数倍")

    if is_exec and misc.get("platform") != 2:
        add("FATAL", "exec.platform", f"{label}: LC_BUILD_VERSION platform={misc.get('platform')} != iOS(2)")
    minos = misc.get("minos")
    if minos:
        major = int(minos.split(".")[0])
        add("INFO", "macho.minos", f"{label}: minos={minos}（设备 iOS 低于此值会拒绝启动）")
        if major >= 18:
            add("HIGH", "macho.minos18",
                f"{label}: 最低系统要求 {minos}，iOS 17 设备装不上/起不来",
                "zig 目标改为 aarch64-ios.17.0")
    return m


def audit_signature(blob, m, label, plist_bytes=None, profile_ent=None, bundle_main=True):
    misc = m["misc"]
    cs = misc.get("codesig")
    if not cs:
        add("FATAL", "sig.missing", f"{label}: 没有 LC_CODE_SIGNATURE")
        return
    dataoff, datasize = cs
    if datasize == 0:
        add("HIGH", "sig.empty", f"{label}: LC_CODE_SIGNATURE 存在但长度为 0（还没签名）")
        return
    sb = blob[dataoff:dataoff + datasize]
    if len(sb) < 12:
        add("HIGH", "sig.short", f"{label}: 签名区不足 12 字节")
        return
    magic, length, count = struct.unpack_from(">III", sb, 0)
    slots = {}
    for i in range(count):
        slot, o = struct.unpack_from(">II", sb, 12 + i * 8)
        slots[slot] = o
    cd_off = slots.get(0)
    if cd_off is None:
        add("FATAL", "sig.cd", f"{label}: 无 CodeDirectory")
        return
    cd = sb[cd_off:]
    (_, cdlen, ver, flags, hash_off, ident_off, n_spec, n_code,
     code_limit) = struct.unpack_from(">IIIIIIIII", cd, 0)
    hash_size, hash_type, _plat, page_size = struct.unpack_from("4B", cd, 36)
    add("INFO", "sig.cd",
        f"{label}: CD v0x{ver:X} pages={n_code} special={n_spec} pageSize=2^{page_size} "
        f"flags=0x{flags:X}")

    if 4096 != (1 << page_size):
        add("HIGH", "sig.pagesize",
            f"{label}: 签名页大小 {1 << page_size}B；arm64 iOS 校验常用 16KB —— 不一致时 amfid 会判签名无效",
            "把 PAGE_SIZE 改成 14（16384）并重签")

    if bundle_main and n_spec < 5:
        add("HIGH", "sig.infoslot",
            f"{label}: 特殊槽只有 {n_spec} 个 —— Info.plist 的哈希没进槽位 1，"
            f"iOS 安装/启动时会判定 bundle 签名无效",
            "签名时把 Info.plist 的 SHA-256 写进 CSSLOT_INFOSLOT(1)")

    if 0x10000 in slots:
        add("INFO", "sig.cms", f"{label}: 带 CMS（证书链签名）")
    elif TARGET == "trollstore":
        add("INFO", "sig.adhoc", f"{label}: ad-hoc 签名 —— TrollStore 接受（它会自行处理签名）")
    else:
        add("HIGH", "sig.adhoc",
            f"{label}: 只有 ad-hoc 签名 —— 真机（非越狱）不会接受任何 ad-hoc 签名的 App",
            "用 Apple 分发证书签（codesign_lite.py --p12）")

    if profile_ent is not None:
        ents = profile_ent
        if "application-identifier" not in ents:
            add("FATAL", "ent.appid", f"{label}: 缺 application-identifier entitlement")
        if "get-task-allow" not in ents:
            add("MED", "ent.gettask", f"{label}: 无 get-task-allow（发布签名正常；调试需要）")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ipa")
    ap.add_argument("--profile", default=None, help="embedded.mobileprovision 或 entitlements plist")
    ap.add_argument("--target", default="device", choices=["device", "trollstore", "appstore"],
                    help="device=普通真机(默认) trollstore=TrollStore appstore=上架")
    args = ap.parse_args()
    global TARGET
    TARGET = args.target

    z = zipfile.ZipFile(args.ipa)
    names = z.namelist()
    apps = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and n.count("/") >= 2})
    app = apps[0]
    info = plistlib.loads(z.read(f"Payload/{app}/Info.plist"))
    exe = info["CFBundleExecutable"]

    # ---- Info.plist 里设备会看的键
    for key, sev, why in [
        ("CFBundleSupportedPlatforms", "HIGH", "iOS 用它判定包能不能在本平台安装"),
        ("MinimumOSVersion", "HIGH", "缺失时系统可能拒绝安装"),
        ("UIDeviceFamily", "MED", "缺失时可能装到 iPad 布局异常"),
        ("CFBundleIcons", "MED", "缺失时白图标（不影响启动）"),
    ]:
        if key not in info and not (key == "CFBundleIcons" and info.get("CFBundleIconFiles")):
            add(sev, f"plist.{key}", f"Info.plist 缺 {key}：{why}",
                "bundle 步骤补上" if key != "CFBundleIcons" else "attach-icons.py")

    if "embedded.mobileprovision" not in " ".join(names):
        if TARGET == "trollstore":
            add("INFO", "bundle.profile", "没有 embedded.mobileprovision —— TrollStore 不需要它")
        elif TARGET == "appstore":
            add("INFO", "bundle.profile", "没有 embedded.mobileprovision —— App Store 分发本来就不带")
        else:
            add("FATAL", "bundle.profile",
                "bundle 里没有 embedded.mobileprovision —— 真机安装（development/ad-hoc）会直接失败",
                "把描述文件放到 .app 根目录（Build-IosAppNative -ProvisioningProfile）")

    # ---- 可执行体
    exe_blob = z.read(f"Payload/{app}/{exe}")
    m = audit_macho(exe_blob, exe, is_exec=True)
    if m:
        audit_signature(exe_blob, m, exe)

    # ---- 嵌套 dylib
    for n in names:
        if n.startswith(f"Payload/{app}/Frameworks/") and n.endswith(".dylib"):
            blob = z.read(n)
            label = n.split("/")[-1]
            dm = audit_macho(blob, label, is_exec=False)
            if dm:
                audit_signature(blob, dm, label, bundle_main=False)
                if not any(c == LC_ID_DYLIB for c, _ in dm["dylibs"]):
                    add("MED", "dylib.id", f"{label}: 没有 LC_ID_DYLIB")

    # ---- 输出
    order = {"FATAL": 0, "HIGH": 1, "MED": 2, "INFO": 3}
    findings.sort(key=lambda f: order[f["sev"]])
    print(f"\n真机启动审计：{os.path.basename(args.ipa)}\n" + "=" * 70)
    for f in findings:
        print(f"[{f['sev']:5}] {f['code']:18} {f['msg']}")
        if f["fix"]:
            print(f"{'':9}  fix: {f['fix']}")
    fatal = sum(1 for f in findings if f["sev"] == "FATAL")
    high = sum(1 for f in findings if f["sev"] == "HIGH")
    print("=" * 70)
    print(f"FATAL={fatal}  HIGH={high}  共 {len(findings)} 条")
    print("FATAL 会让 App 一定起不来；HIGH 在多数设备/版本上起不来。")
    return 0 if fatal == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
