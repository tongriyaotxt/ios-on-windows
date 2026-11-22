#!/usr/bin/env python3
"""xip-extract.py —— 在 Windows 上解苹果的 .xip（Xcode / Command Line Tools 安装包）。

.xip 是三层套娃，三层都有公开格式：
    1. xar      容器：magic 'xar!' + zlib 压缩的 TOC(XML) + 堆
    2. pbzx     payload 流：magic 'pbzx' + 分块，块内是 xz（flags=0x1000000）
    3. cpio     '070701' newc 归档，记录每个文件的路径/权限

拿到 Xcode.xip 之后这样用（只需 Apple ID 在浏览器里下一次，不需要 Mac）：

    python tools/xip-extract.py Xcode_16.xip --out F:\\Xcode16 --only \\
        "Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs"

抽出来的 iPhoneOS.sdk 就是 osxcross / sweetpad 路线里那份「SDK」，配上
zig（clang 前端）就能编 Swift 之外的一切；再配合 SDK 里的 *.swiftmodule 才有可能编 SwiftUI。
"""
import argparse
import bz2
import lzma
import os
import struct
import sys
import xml.etree.ElementTree as ET
import zlib


# ------------------------------------------------------------------ xar
def read_xar(path):
    with open(path, "rb") as f:
        head = f.read(28)
        if len(head) < 28 or head[:4] != b"xar!":
            raise SystemExit("不是 xar 容器（magic 不是 'xar!'）")
        _magic, header_size, version, toc_len_c, toc_len_u, cksum_alg = struct.unpack(">IHHQQI", head)
        toc_comp = f.read(toc_len_c)
        toc = zlib.decompress(toc_comp)
        if len(toc) != toc_len_u:
            print(f"  warn: TOC 解压后 {len(toc)} 字节，头部声明 {toc_len_u}", file=sys.stderr)

        root = ET.fromstring(toc)
        entries = []
        for el in root.iter("file"):
            name_el = el.find("name")
            data_el = el.find("data")
            if name_el is None or data_el is None:
                continue
            off = int(data_el.findtext("offset", "0"))
            length = int(data_el.findtext("length", "0"))
            size = int(data_el.findtext("size", "0"))
            enc_el = data_el.find("encoding")
            style = enc_el.get("style", "") if enc_el is not None else ""
            entries.append({"name": name_el.text, "type": el.get("type", "file"),
                            "offset": off, "length": length, "size": size, "encoding": style})
        return entries, header_size + toc_len_c


def read_heap_slice(path, base, offset, length):
    with open(path, "rb") as f:
        f.seek(base + offset)
        return f.read(length)


# ------------------------------------------------------------------ pbzx
def pbzx_decompress(blob: bytes) -> bytes:
    if blob[:4] != b"pbzx":
        raise SystemExit("不是 pbzx 流")
    flags = struct.unpack_from(">Q", blob, 4)[0]
    out = bytearray()
    pos = 12
    while pos < len(blob):
        if pos + 8 > len(blob):
            break
        chunk_len = struct.unpack_from(">Q", blob, pos)[0]
        pos += 8
        if chunk_len == 0 or pos + chunk_len > len(blob):
            break
        chunk = blob[pos:pos + chunk_len]
        pos += chunk_len
        if flags == 0x01000000:          # xz
            out += lzma.decompress(chunk)
        elif flags & 0x01000000:
            try:
                out += lzma.decompress(chunk)
            except lzma.LZMAError:
                out += chunk
        else:
            out += chunk
    return bytes(out)


# ------------------------------------------------------------------ cpio (newc)
def cpio_parse(data: bytes, out_dir: str, only: str = None):
    pos = 0
    written = []
    while True:
        if data[pos:pos + 6] not in (b"070701", b"070702"):
            if data[pos:pos + 6] == b"070707":
                raise SystemExit("检测到旧版 cpio(070707)，暂不支持；请用 7z 解这一层")
            break
        _magic = data[pos:pos + 6].decode()
        pos += 6
        fields = [int(data[pos + i * 8: pos + (i + 1) * 8], 16) for i in range(13)]
        pos += 104
        (ino, mode, uid, gid, nlink, mtime, filesize,
         devmajor, devminor, rdevmajor, rdevminor, namesize, check) = fields
        name = data[pos:pos + namesize - 1].decode("utf-8", "replace")
        pos += namesize
        pos = (pos + 3) & ~3                      # 4 字节对齐
        payload = data[pos:pos + filesize]
        pos += filesize
        pos = (pos + 3) & ~3

        if name == "TRAILER!!!":
            break
        if only and only not in name:
            continue

        target = os.path.join(out_dir, name.replace("/", os.sep))
        if name.endswith("/"):
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(payload)
        # 权限：cpio 的 mode 高位是文件类型，低 12 位是权限
        os.chmod(target, mode & 0o7777)
        written.append((name, filesize))
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xip")
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default=None, help="只解路径包含该子串的条目")
    ap.add_argument("--list", action="store_true", help="只列 xar 条目，不解包")
    args = ap.parse_args()

    entries, heap_base = read_xar(args.xip)
    if args.list:
        for e in entries:
            print(f"{e['type']:5} {e['size']:>12} {e['name']}")
        return 0

    payload = None
    for e in entries:
        if e["type"] == "file" and e["size"] > (payload["size"] if payload else 0):
            payload = e
    if payload is None:
        raise SystemExit("xar 里没有数据条目")

    print(f"payload: {payload['name']} ({payload['size']/1e6:.1f} MB, {payload['encoding'] or 'raw'})")
    raw = read_heap_slice(args.xip, heap_base, payload["offset"], payload["length"])
    style = payload["encoding"]
    if "x-gzip" in style or raw[:2] == b"\x1f\x8b":
        raw = zlib.decompress(raw, 16 + zlib.MAX_WBITS)
    elif "bz2" in style:
        raw = bz2.decompress(raw)
    elif "xz" in style and raw[:4] != b"pbzx":
        raw = lzma.decompress(raw)

    blob = pbzx_decompress(raw) if raw[:4] == b"pbzx" else raw
    print(f"cpio stream: {len(blob)/1e6:.1f} MB")

    os.makedirs(args.out, exist_ok=True)
    written = cpio_parse(blob, args.out, args.only)
    total = sum(s for _, s in written)
    print(f"解出 {len(written)} 个文件，{total/1e6:.1f} MB -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
