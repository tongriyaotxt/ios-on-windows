#!/usr/bin/env python3
"""machogen.py —— 在 Windows 上直接生成一个合法的 arm64 iOS Mach-O 可执行文件。

用途：
  · 交叉编译 UIKit App 时，作为「只负责加载 Frameworks/AppCore.dylib」的极简可执行体
  · 没有 LLVM 时，作为结构正确的占位可执行体

产物包含真机启动所需的全部骨架（参考 tools/audit-device.py 的 FATAL/HIGH 项逐条补齐）：
    LC_SEGMENT_64 __PAGEZERO / __TEXT(__text) / __DATA / __LINKEDIT
    LC_LOAD_DYLINKER /usr/lib/dyld      ← 缺它内核会当静态二进制，dyld 不运行
    LC_LOAD_DYLIB   …                   ← 默认 libSystem，可追加
    LC_DYLD_INFO_ONLY（全零）            ← 无外部符号时的合法写法
    LC_SYMTAB（空表）
    LC_UUID
    LC_BUILD_VERSION platform=iOS
    LC_MAIN
    LC_CODE_SIGNATURE（预留区，交给 codesign_lite.py 填）

段全部按 16KB 对齐（arm64 iOS 的页大小），避免 dyld 报 "malformed mach-o"。
"""
import argparse
import hashlib
import struct
import sys
import uuid

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_PIE = 0x00200000
MH_NOUNDEFS = 0x00000001
MH_DYLDLINK = 0x00000004
MH_TWOLEVEL = 0x00000080

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_LOAD_DYLINKER = 0xE
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
LC_DYLD_INFO_ONLY = 0x80000022
LC_BUILD_VERSION = 0x32
LC_MAIN = 0x80000028

PLATFORM_IOS = 2
PAGE = 0x4000            # 16 KB
PAGEZERO_SIZE = 0x100000000
BASE_ADDR = 0x100000000

# mov w0, #0 ; ret
CODE = struct.pack("<II", 0x52800000, 0xD65F03C0)


def align(n, a):
    return (n + a - 1) // a * a


def seg_cmd(name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sections=None):
    sections = sections or []
    cmdsize = 72 + 80 * len(sections)
    out = struct.pack("<II16sQQQQiiII", LC_SEGMENT_64, cmdsize, name.encode().ljust(16, b"\0"),
                      vmaddr, vmsize, fileoff, filesize, maxprot, initprot, len(sections), 0)
    for (seg, sect, addr, size, off, algn, flags) in sections:
        out += struct.pack("<16s16sQQIIIIIIII", sect.encode().ljust(16, b"\0"),
                           seg.encode().ljust(16, b"\0"), addr, size, off, algn, 0, 0, flags, 0, 0, 0)
    return out


def str_cmd(cmd_id, path, extra=0):
    raw = path.encode() + b"\0"
    raw += b"\0" * (align(len(raw), 8) - len(raw))
    return struct.pack("<III", cmd_id, 12 + len(raw), 12 if cmd_id == LC_LOAD_DYLINKER else extra) + raw


def build(identifier="com.tongriyaotxt.helloios", sig_size=0, dylibs=None, minos=(17, 0),
          deterministic=False):
    if dylibs is None:
        dylibs = ["/usr/lib/libSystem.B.dylib"]

    # 先估算 load commands 长度（段命令里的地址依赖最终布局，先按固定尺寸算）
    dylib_cmds = b""
    for p in dylibs:
        raw = p.encode() + b"\0"
        raw += b"\0" * (align(len(raw), 8) - len(raw))
        dylib_cmds += struct.pack("<IIIIII", LC_LOAD_DYLIB, 24 + len(raw), 24, 2, 0x10000, 0x10000) + raw
    dylinker = str_cmd(LC_LOAD_DYLINKER, "/usr/lib/dyld")

    # PAGEZERO/TEXT/DATA/LINKEDIT/DYLD_INFO/SYMTAB/UUID/BUILD/MAIN/CODESIG = 10，+ dylinker + 每个 dylib
    ncmds = 11 + len(dylibs)
    # __PAGEZERO(72) __TEXT(72+80) __DATA(72) __LINKEDIT(72) BUILD(24) MAIN(24) CODESIG(16)
    # SYMTAB(24) DYLD_INFO(48) UUID(24) + dylinker + dylibs
    sizeofcmds = 72 + 152 + 72 + 72 + 24 + 24 + 16 + 24 + 48 + 24 + len(dylinker) + len(dylib_cmds)

    # 布局：header+cmds → __text → 补齐到 16KB → __DATA(16B) → 补齐 → __LINKEDIT(sig)
    code_off = align(32 + sizeofcmds, 16)
    text_filesize = align(code_off + len(CODE), PAGE)
    data_off = text_filesize
    data_filesize = 16
    linkedit_off = align(data_off + data_filesize, PAGE)

    cmds = b""
    cmds += seg_cmd("__PAGEZERO", 0, PAGEZERO_SIZE, 0, 0, 0, 0)
    cmds += seg_cmd("__TEXT", BASE_ADDR, text_filesize, 0, text_filesize, 5, 5,
                    [("__TEXT", "__text", BASE_ADDR + code_off, len(CODE), code_off, 4, 0x80000400)])
    cmds += seg_cmd("__DATA", BASE_ADDR + text_filesize, PAGE, data_off, data_filesize, 3, 3)
    cmds += seg_cmd("__LINKEDIT", BASE_ADDR + linkedit_off, align(max(sig_size, PAGE), PAGE),
                    linkedit_off, sig_size, 1, 1)
    # dyld 绑定信息：无外部符号，全零合法
    cmds += struct.pack("<IIIIIIIIIIII", LC_DYLD_INFO_ONLY, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    cmds += struct.pack("<IIIIII", LC_SYMTAB, 24, 0, 0, 0, 0)
    if deterministic:
        # 可复现构建：UUID 由 identifier+minos 派生，不用随机数
        digest = hashlib.sha256(f"{identifier}/{minos[0]}.{minos[1]}".encode()).digest()
        cmds += struct.pack("<II", LC_UUID, 24) + digest[:16]
    else:
        cmds += struct.pack("<II", LC_UUID, 24) + uuid.uuid4().bytes
    cmds += struct.pack("<IIIIII", LC_BUILD_VERSION, 24, PLATFORM_IOS,
                        (minos[0] << 16) | minos[1], (17 << 16), 0)
    cmds += struct.pack("<IIQQ", LC_MAIN, 24, code_off, 0)
    cmds += struct.pack("<IIII", LC_CODE_SIGNATURE, 16, linkedit_off, 0)
    cmds += dylinker + dylib_cmds

    assert len(cmds) == sizeofcmds, f"sizeofcmds mismatch: {len(cmds)} != {sizeofcmds}"

    header = struct.pack("<IiiIIIII", MH_MAGIC_64, CPU_TYPE_ARM64, 0, MH_EXECUTE, ncmds,
                         sizeofcmds, MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE, 0)
    out = bytearray(header + cmds)
    out += b"\0" * (code_off - len(out))
    out += CODE
    out += b"\0" * (data_off + data_filesize - len(out))
    out += b"\0" * (linkedit_off - len(out))
    out += b"\0" * sig_size
    return bytes(out), linkedit_off


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--identifier", default="com.tongriyaotxt.helloios")
    ap.add_argument("--signature-size", type=int, default=0)
    ap.add_argument("--load-dylib", action="append", default=None)
    ap.add_argument("--minos", default="17.0")
    ap.add_argument("--deterministic", action="store_true", help="固定 UUID，产物可复现")
    args = ap.parse_args()

    major, minor = (int(x) for x in args.minos.split("."))
    libs = args.load_dylib if args.load_dylib else ["/usr/lib/libSystem.B.dylib"]
    blob, linkedit_off = build(args.identifier, args.signature_size, dylibs=libs,
                               minos=(major, minor), deterministic=args.deterministic)
    with open(args.output, "wb") as f:
        f.write(blob)
    print(f"wrote {args.output}: {len(blob)} bytes")
    print(f"  magic=0x{MH_MAGIC_64:08X} arm64 MH_EXECUTE iOS{major}.{minor}  __LINKEDIT@{linkedit_off}")
    print("  segments: __PAGEZERO __TEXT __DATA __LINKEDIT (16KB aligned)")
    print(f"  dylibs: {libs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
