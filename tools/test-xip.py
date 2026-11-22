#!/usr/bin/env python3
"""test-xip.py —— 自造一个结构等价的 .xip（cpio → pbzx → xar），再用 xip-extract.py 解回来。

这不是在验证苹果的包，而是验证**三层解析器本身**：格式是公开的，能自洽往返就说明
拿到真 Xcode.xip 时不会卡在解析上（而且真包的每一层都是同一套结构）。
"""
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib


def cpio_newc(entries):
    out = bytearray()

    def rec(name, data, mode=0o644):
        namesize = len(name) + 1
        fields = [0, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, namesize, 0]
        out.extend(b"070701" + b"".join(b"%08X" % f for f in fields))
        out.extend(name.encode() + b"\0")
        while len(out) % 4:
            out.append(0)
        out.extend(data)
        while len(out) % 4:
            out.append(0)

    for name, data in entries:
        rec(name, data, 0o100644 if not name.endswith("/") else 0o040755)
    rec("TRAILER!!!", b"", 0)
    return bytes(out)


def pbzx(stream, use_xz=True):
    chunks = [stream[i:i + (1 << 16)] for i in range(0, len(stream), 1 << 16)]
    out = bytearray(b"pbzx")
    out += struct.pack(">Q", 0x01000000 if use_xz else 0)
    for c in chunks:
        packed = lzma.compress(c) if use_xz else c
        out += struct.pack(">Q", len(packed)) + packed
    out += struct.pack(">Q", 0)
    return bytes(out)


def xar(payload, name="Content"):
    toc = ET.Element("xar")
    toc_el = ET.SubElement(toc, "toc")
    file_el = ET.SubElement(toc_el, "file")
    ET.SubElement(file_el, "name").text = name
    data_el = ET.SubElement(file_el, "data")
    ET.SubElement(data_el, "offset").text = "0"
    ET.SubElement(data_el, "length").text = str(len(payload))
    ET.SubElement(data_el, "size").text = str(len(payload))
    ET.SubElement(data_el, "encoding", style="application/octet-stream")
    body = ET.tostring(toc, encoding="utf-8")
    comp = zlib.compress(body, 9)
    header = struct.pack(">IHHQQI", 0x78617221, 28, 1, len(comp), len(body), 0)
    return header + comp + payload


def main():
    tmp = tempfile.mkdtemp(prefix="xip-test-")
    files = [
        ("Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/usr/include/UIKit/UIKit.h",
         b"/* fake UIKit header */\n"),
        ("Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/usr/lib/libobjc.tbd",
         b"--- !tapi-tbd\ntbd-version: 4\n...\n"),
        ("Xcode.app/Contents/Developer/usr/bin/actool", b"\xcf\xfa\xed\xfe fake-macho"),
    ]
    stream = cpio_newc(files)
    artifact = os.path.join(tmp, "Fake.xip")
    with open(artifact, "wb") as f:
        f.write(xar(pbzx(stream)))

    out = os.path.join(tmp, "out")
    print(f"合成 {artifact} ({os.path.getsize(artifact)} bytes, {len(files)} 个文件)")
    rc = subprocess.call([sys.executable, os.path.join(os.path.dirname(__file__), "xip-extract.py"),
                          artifact, "--out", out])
    if rc != 0:
        print("FAIL: 解包失败")
        return 1

    ok = True
    for name, data in files:
        path = os.path.join(out, name.replace("/", os.sep))
        if not os.path.exists(path):
            print(f"FAIL: 缺少 {name}")
            ok = False
            continue
        got = open(path, "rb").read()
        if got != data:
            print(f"FAIL: 内容不一致 {name} ({len(got)} vs {len(data)})")
            ok = False
    print("PASS: xar → pbzx(xz) → cpio 三层往返一致" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
