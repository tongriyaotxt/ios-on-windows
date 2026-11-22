#!/usr/bin/env python3
"""codesign_lite.py —— 在 Windows 上给 Mach-O 做代码签名（ad-hoc 或真证书 CMS），不需要 macOS。

写进二进制的是 Apple 的 embedded signature 结构：

    Mach-O
      └─ LC_CODE_SIGNATURE ──► SuperBlob(0xfade0cc0)
                                 ├─ [0x10000] CMS/PKCS#7（用 .p12 签时才有）
                                 ├─ [5]       Entitlements(0xfade7171)
                                 └─ [0]       CodeDirectory(0xfade0c02 v0x20400)
                                                ├─ 特殊槽：entitlements 的 SHA-256
                                                └─ 代码槽：每 4096B 一页的 SHA-256

难点在 LC_CODE_SIGNATURE.datasize 会随签名块长度变化，而它本身位于被哈希的头部里：
所以 sign 用不动点迭代（datasize → 页哈希 → CodeDirectory → CMS 长度 → 新 datasize），
一般 2–3 轮收敛。

命令：
    sign    --binary X --identifier com.a.b [--p12 cert.p12 --password pw] [--entitlements e.plist]
    verify  --binary X
    bundle  --binary X --out App.app --identifier com.a.b
"""
import argparse
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass
import hashlib
import json
import os
import plistlib
import struct
import sys


def align(n, a=16):
    return (n + a - 1) // a * a


MH_MAGIC_64 = 0xFEEDFACF
LC_CODE_SIGNATURE = 0x1D

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSMAGIC_BLOBWRAPPER = 0xFADE0B01

CSSLOT_CODEDIRECTORY = 0
CSSLOT_ENTITLEMENTS = 5
CSSLOT_SIGNATURESLOT = 0x10000

CD_VERSION = 0x20400
CD_FLAG_ADHOC = 0x0002
PAGE_SIZE = int(os.environ.get("CODESIGN_PAGE_SIZE", "12"))   # 12=4KB（iOS 常见） 14=16KB（arm64 macOS）
HASH_SIZE = 32
HASH_TYPE_SHA256 = 2
CD_HEADER_LEN = 88


# ---------------------------------------------------------------- Mach-O 解析
def find_code_signature(data: bytes):
    magic, = struct.unpack_from("<I", data, 0)
    if magic != MH_MAGIC_64:
        raise ValueError(f"not a 64-bit Mach-O (magic=0x{magic:08X})")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    off, end = 32, 32 + sizeofcmds
    while off < end:
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            return off, dataoff, datasize
        off += cmdsize
    return None, None, None


# ---------------------------------------------------------------- blob 构造
def entitlements_blob(ent: dict) -> bytes:
    body = plistlib.dumps(ent, fmt=plistlib.FMT_XML)
    return struct.pack(">II", CSMAGIC_EMBEDDED_ENTITLEMENTS, 8 + len(body)) + body


def code_directory(identifier: bytes, team_id: bytes, code_limit: int,
                   page_hashes, special_hashes, flags: int) -> bytes:
    n_special, n_code = len(special_hashes), len(page_hashes)
    ident_off = CD_HEADER_LEN
    team_off = ident_off + len(identifier) + 1 if team_id else 0
    hash_off = ident_off + len(identifier) + 1 + (len(team_id) + 1 if team_id else 0)
    total = hash_off + n_special * HASH_SIZE + n_code * HASH_SIZE

    hdr = struct.pack(
        ">IIIIIIIII4BIIIIQQQQ",
        CSMAGIC_CODEDIRECTORY, total, CD_VERSION, flags,
        hash_off, ident_off, n_special, n_code, code_limit,
        HASH_SIZE, HASH_TYPE_SHA256, 0, PAGE_SIZE,
        0,   # spare2
        0,   # scatterOffset
        team_off,
        0,   # spare3
        0,   # codeLimit64
        0, 0, 0,
    )
    assert len(hdr) == CD_HEADER_LEN, len(hdr)

    out = bytearray(hdr)
    out += identifier + b"\0"
    if team_id:
        out += team_id + b"\0"
    out += b"".join(special_hashes)
    out += b"".join(page_hashes)
    assert len(out) == total, (len(out), total)
    return bytes(out)


def blob(magic: int, payload: bytes) -> bytes:
    return struct.pack(">II", magic, 8 + len(payload)) + payload


def superblob(entries) -> bytes:
    entries = sorted(entries, key=lambda e: e[0])
    count = len(entries)
    off = 12 + 8 * count            # 超级块头是 magic(4)+length(4)+count(4) = 12
    index, body = b"", b""
    for slot, b in entries:
        index += struct.pack(">II", slot, off + len(body))
        body += b
    return struct.pack(">III", CSMAGIC_EMBEDDED_SIGNATURE, off + len(body), count) + index + body


def cms_sign(cd: bytes, p12_path: str, password: str) -> bytes:
    """用 p12 里的证书对 CodeDirectory 做分离式 PKCS#7（DER）。"""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.serialization import pkcs7, pkcs12

    with open(p12_path, "rb") as f:
        key, cert, extra = pkcs12.load_key_and_certificates(
            f.read(), password.encode() if password else None)
    if key is None or cert is None:
        raise SystemExit("p12 里没有私钥或证书")

    builder = pkcs7.PKCS7SignatureBuilder().set_data(cd).add_signer(cert, key, hashes.SHA256())
    for c in (extra or []):
        builder = builder.add_certificate(c)
    der = builder.sign(serialization.Encoding.DER,
                       [pkcs7.PKCS7Options.DetachedSignature, pkcs7.PKCS7Options.Binary])
    print(f"  CMS: {len(der)}B signer={cert.subject.rfc4514_string()}")
    return blob(CSMAGIC_BLOBWRAPPER, der)



# ---------------------------------------------------------------- 注入 LC_CODE_SIGNATURE
def _linkedit_info(data):
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19:                      # LC_SEGMENT_64
            segname = bytes(data[off + 8:off + 24]).rstrip(b"\0")
            if segname == b"__LINKEDIT":
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
                return {"cmd_off": off, "vmaddr": vmaddr, "vmsize": vmsize,
                        "fileoff": fileoff, "filesize": filesize}
        off += cmdsize
    return None


def _first_section_offset(data):
    """load commands 之后、第一个 section 数据之前，就是可以放新 LC 的空白区。"""
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    off, lowest = 32, None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            sec_off = off + 72
            for _s in range(nsects):
                size, offset = struct.unpack_from("<QI", data, sec_off + 40)
                if size > 0:
                    lowest = offset if lowest is None else min(lowest, offset)
                sec_off += 80
        off += cmdsize
    return lowest


def inject_code_signature(data: bytearray) -> int:
    """给没有 LC_CODE_SIGNATURE 的 Mach-O 插入该命令，并把签名区放到文件尾部。"""
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    lc_end = 32 + sizeofcmds
    lowest = _first_section_offset(data)
    limit = lowest if lowest is not None else len(data)
    if lc_end + 16 > limit:
        raise SystemExit("头部没有 16 字节空位放 LC_CODE_SIGNATURE；链接时加 -Wl,-headerpad,0x1000 后重试")
    if any(data[lc_end:lc_end + 16]):
        raise SystemExit("LC 之后不是空白，拒绝覆盖")

    dataoff = align(len(data), 16)
    if dataoff > len(data):
        data += b"\0" * (dataoff - len(data))

    le = _linkedit_info(data)
    if le is None:
        raise SystemExit("没有 __LINKEDIT 段，无法安放签名")
    # 预留足够放 CMS 的空间（8192），并把 __LINKEDIT 扩到覆盖它
    reserve = 8192
    struct.pack_into("<IIII", data, lc_end, LC_CODE_SIGNATURE, 16, dataoff, reserve)
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + 16)
    new_filesize = dataoff + reserve - le["fileoff"]
    struct.pack_into("<Q", data, le["cmd_off"] + 48, new_filesize)
    struct.pack_into("<Q", data, le["cmd_off"] + 32, align(new_filesize, 0x4000))
    return dataoff

# ---------------------------------------------------------------- sign
def cmd_sign(args):
    data = bytearray(open(args.binary, "rb").read())
    lc_off, dataoff, _ = find_code_signature(data)
    if lc_off is None:
        if not getattr(args, "inject", False):
            raise SystemExit("二进制里没有 LC_CODE_SIGNATURE：加 --inject 让本工具自动插入，"
                             "或用 machogen.py --signature-size N 预留")
        print("  inject: 找不到 LC_CODE_SIGNATURE，自动插入")
        dataoff = inject_code_signature(data)
        lc_off, dataoff, _ = find_code_signature(data)
    code_limit = dataoff

    identifier = args.identifier.encode()
    team_id = args.team_id.encode() if args.team_id else b""

    ent_bytes = None
    if args.entitlements:
        with open(args.entitlements, encoding="utf-8-sig") as f:
            txt = f.read().strip()
        ent = json.loads(txt) if txt.startswith("{") else plistlib.loads(txt.encode())
        if args.bundle_id and args.team_id:
            ent.setdefault("application-identifier", f"{args.team_id}.{args.bundle_id}")
        ent_bytes = entitlements_blob(ent)

    n_code = (code_limit + 4096 - 1) // 4096
    info_bytes = None
    if args.info_plist:
        with open(args.info_plist, "rb") as f:
            info_bytes = f.read()
    n_special = 5 if (ent_bytes or info_bytes) else 0
    cd_len = (CD_HEADER_LEN + len(identifier) + 1 + (len(team_id) + 1 if team_id else 0)
              + n_special * HASH_SIZE + n_code * HASH_SIZE)
    n_entries = (1 if ent_bytes else 0) + (1 if args.p12 else 0) + 1
    fixed_len = 12 + 8 * n_entries + cd_len + (len(ent_bytes) if ent_bytes else 0)

    def build(datasize: int, cms_len: int, want_cd_only=False):
        """datasize 参与页哈希（它在被哈希的头部里），所以必须迭代到稳定。"""
        struct.pack_into("<I", data, lc_off + 8, dataoff)
        struct.pack_into("<I", data, lc_off + 12, datasize)
        pages = [hashlib.sha256(bytes(data[i * 4096: min((i + 1) * 4096, code_limit)])).digest()
                 for i in range(n_code)]
        # 文件里的顺序是 slot n … slot 1（降序）：index0=slot5(entitlements)，index4=slot1(Info.plist)
        special = []
        if n_special:
            slots = [b"\0" * HASH_SIZE] * 5
            if ent_bytes:
                slots[0] = hashlib.sha256(ent_bytes).digest()
            if info_bytes:
                slots[4] = hashlib.sha256(info_bytes).digest()   # CSSLOT_INFOSLOT = 1
            special = slots
        cd = code_directory(identifier, team_id, code_limit, pages, special,
                            CD_FLAG_ADHOC if not args.p12 else 0)
        parts = [(CSSLOT_CODEDIRECTORY, cd)]
        if ent_bytes:
            parts.append((CSSLOT_ENTITLEMENTS, ent_bytes))
        if want_cd_only:
            return cd
        if args.p12:
            parts.append((CSSLOT_SIGNATURESLOT, cms_sign(cd, args.p12, args.password)))
        return superblob(parts)

    # datasize 位于被哈希的头部里，而它又取决于 CMS 长度（CMS 长度会因 DER 编码抖动 ±1 字节）。
    # 所以不追求长度相等，而是「先定尺寸、留余量、再填充」——真 codesign 的 datasize 也常大于 blob 实际长度。
    datasize = fixed_len + 64
    for i in range(6):
        cd = build(datasize, 0, want_cd_only=True)
        need = fixed_len - (len(cd) - cd_len)            # 用当前 cd 重算固定部分
        need = 12 + 8 * n_entries + len(cd) + (len(ent_bytes) if ent_bytes else 0)
        if args.p12:
            cms = cms_sign(cd, args.p12, args.password)
            need += len(cms) - 8
        print(f"  iter {i}: datasize={datasize} need={need}")
        if need <= datasize:
            break
        datasize = need + 64
    else:
        raise SystemExit("签名块尺寸没有收敛")

    final = build(datasize, 0)
    if len(final) > datasize:                             # CMS 又长了一点：再加余量重来一次
        datasize = len(final) + 64
        final = build(datasize, 0)
    if len(final) > datasize:
        raise SystemExit(f"签名块过长: {len(final)} > {datasize}")
    final = final + b"\0" * (datasize - len(final))       # 尾部填充，superblob.length 才是真实长度

    if len(data) < dataoff + len(final):
        data += b"\0" * (dataoff + len(final) - len(data))
    data[dataoff:dataoff + len(final)] = final
    struct.pack_into("<I", data, lc_off + 12, len(final))
    open(args.binary, "wb").write(bytes(data))
    print(f"signed {args.binary}: blob={len(final)}B codeLimit={code_limit} pages={n_code} "
          f"mode={'cms' if args.p12 else 'adhoc'} ident={identifier.decode()}")



def cmd_verify(args):
    data = open(args.binary, "rb").read()
    lc_off, dataoff, datasize = find_code_signature(data)
    if lc_off is None or not datasize:
        print("FAIL: 没有签名")
        return 1
    sb = data[dataoff:dataoff + datasize]
    magic, length, count = struct.unpack_from(">III", sb, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        print(f"FAIL: 超级块 magic 错: 0x{magic:08X}")
        return 1
    print(f"superblob: {length} bytes, {count} entries")
    cd = None
    cms_present = False
    for i in range(count):
        slot, off = struct.unpack_from(">II", sb, 12 + i * 8)
        print(f"  slot 0x{slot:04X} @ {off}")
        if slot == CSSLOT_CODEDIRECTORY:
            cd = sb[off:]
        if slot == CSSLOT_SIGNATURESLOT:
            cms_present = True
    if cd is None:
        print("FAIL: 没有 CodeDirectory")
        return 1

    m, cd_len, version, flags, hash_off, ident_off, n_spec, n_code, code_limit = struct.unpack_from(">IIIIIIIII", cd, 0)
    hash_size, hash_type, platform, page_size = struct.unpack_from("4B", cd, 36)
    ident = cd[ident_off:cd.index(b"\0", ident_off)].decode()
    print(f"CodeDirectory v0x{version:X} len={cd_len} flags=0x{flags:X} ident={ident}")
    print(f"  hashType={hash_type} hashSize={hash_size} pageSize=2^{page_size} "
          f"nCode={n_code} nSpecial={n_spec} codeLimit={code_limit}")

    ok = True
    for i in range(n_code):
        start = i * 4096
        end = min(start + 4096, code_limit)
        want = cd[hash_off + n_spec * hash_size + i * hash_size: hash_off + n_spec * hash_size + (i + 1) * hash_size]
        got = hashlib.sha256(data[start:end]).digest()
        if want != got:
            print(f"  FAIL page {i}: hash mismatch")
            ok = False
    print(f"pages: {n_code} checked, {'all match' if ok else 'MISMATCH'}")
    print(f"cms: {'present' if cms_present else 'none (ad-hoc)'}")
    print("RESULT:", "VALID" if ok else "INVALID")
    return 0 if ok else 1


def cmd_bundle(args):
    os.makedirs(args.out, exist_ok=True)
    exe_name = args.executable_name or "App"
    if args.binary:
        with open(args.binary, "rb") as f:
            blob = f.read()
        with open(os.path.join(args.out, exe_name), "wb") as f:
            f.write(blob)
        os.chmod(os.path.join(args.out, exe_name), 0o755)

    if args.info_plist and os.path.exists(args.info_plist):
        with open(args.info_plist, "rb") as f:
            info = plistlib.load(f)
    else:
        info = {}
    defaults = {
        "CFBundleExecutable": exe_name,
        "CFBundleIdentifier": args.identifier,
        "CFBundleName": args.name or exe_name,
        "CFBundleDisplayName": args.name or exe_name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": args.version,
        "CFBundleVersion": args.build,
        "MinimumOSVersion": "17.0",
        "UIDeviceFamily": [1],
        "UILaunchScreen": {},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        "ITSAppUsesNonExemptEncryption": False,
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "LSRequiresIPhoneOS": True,
        "DTPlatformName": "iphoneos",
        "DTSDKName": "iphoneos17.0",
        "DTXcode": "1600",
        "DTXcodeBuild": "16A242d",
    }
    for k, v in defaults.items():
        info.setdefault(k, v)
    with open(os.path.join(args.out, "Info.plist"), "wb") as f:
        plistlib.dump(info, f)

    if args.provisioning_profile:
        with open(args.provisioning_profile, "rb") as src, \
             open(os.path.join(args.out, "embedded.mobileprovision"), "wb") as dst:
            dst.write(src.read())

    print(f"bundle {args.out}: exe={exe_name} id={info['CFBundleIdentifier']} "
          f"ver={info['CFBundleShortVersionString']}({info['CFBundleVersion']})")
    print("  contents: " + ", ".join(sorted(os.listdir(args.out))))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sign")
    s.add_argument("--binary", required=True)
    s.add_argument("--identifier", required=True)
    s.add_argument("--bundle-id", default=None)
    s.add_argument("--team-id", default=None)
    s.add_argument("--entitlements", default=None, help="plist 或 json")
    s.add_argument("--p12", default=None, help="不给就是 ad-hoc 签名")
    s.add_argument("--password", default="")
    s.add_argument("--inject", action="store_true", help="缺少 LC_CODE_SIGNATURE 时自动插入")
    s.add_argument("--info-plist", default=None, help="bundle 的 Info.plist；其哈希写入特殊槽 1")
    s.set_defaults(func=cmd_sign)

    v = sub.add_parser("verify")
    v.add_argument("--binary", required=True)
    v.set_defaults(func=cmd_verify)

    b = sub.add_parser("bundle")
    b.add_argument("--binary", default=None)
    b.add_argument("--out", required=True)
    b.add_argument("--identifier", required=True)
    b.add_argument("--executable-name", default="App")
    b.add_argument("--name", default=None)
    b.add_argument("--version", default="1.0.0")
    b.add_argument("--build", default="1")
    b.add_argument("--info-plist", default=None)
    b.add_argument("--provisioning-profile", default=None)
    b.set_defaults(func=cmd_bundle)

    args = ap.parse_args()
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
