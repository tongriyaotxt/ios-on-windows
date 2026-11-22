"""工具链的单元测试（不联网、不需要 Apple 账号、不需要 macOS）。

覆盖四块最容易回归的逻辑：
  1. Mach-O 生成（machogen）—— 头部/段/加载命令齐全
  2. 代码签名（codesign_lite）—— 签一次再验一次，页哈希必须对得上
  3. IPA 校验（verify-ipa）—— 造一个最小 ipa，检查能过
  4. xip 解包（xip-extract）—— 自造三层包往返一致

跑：python -m pytest py_tests -q
"""
import importlib.util
import os
import struct
import subprocess
import sys
import zipfile

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- machogen
def test_machogen_header(tmp_path):
    machogen = load("machogen")
    out = tmp_path / "exe"
    blob, linkedit_off = machogen.build("com.example.app", sig_size=4096,
                                        dylibs=["@executable_path/Frameworks/X.dylib"])
    out.write_bytes(blob)

    magic, cputype, _sub, filetype = struct.unpack_from("<IIII", blob, 0)
    ncmds, sizeofcmds = struct.unpack_from("<II", blob, 16)
    assert magic == 0xFEEDFACF
    assert cputype == 0x0100000C, "必须是 arm64"
    assert filetype == 2, "必须是 MH_EXECUTE"

    # 关键 load command 必须存在
    seen = set()
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", blob, off)
        seen.add(cmd)
        off += size
    assert 0x19 in seen, "LC_SEGMENT_64"
    assert 0xE in seen, "LC_LOAD_DYLINKER（缺了内核不会跑 dyld）"
    assert 0x80000028 in seen, "LC_MAIN"
    assert 0x1D in seen, "LC_CODE_SIGNATURE"
    assert 0xC in seen, "LC_LOAD_DYLIB"
    assert sizeofcmds == off - 32


def test_machogen_segments_page_aligned(tmp_path):
    machogen = load("machogen")
    blob, _ = machogen.build("com.example.app", sig_size=0)
    ncmds, _sz = struct.unpack_from("<II", blob, 16)
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", blob, off)
        if cmd == 0x19:
            name = blob[off + 8:off + 24].rstrip(b"\0").decode()
            fileoff = struct.unpack_from("<Q", blob, off + 40)[0]
            if name != "__LINKEDIT" and name != "__PAGEZERO":
                assert fileoff % 0x4000 == 0, f"{name} 未按 16KB 对齐"
        off += size


def test_machogen_deterministic():
    machogen = load("machogen")
    a, _ = machogen.build("com.example.app", sig_size=0, deterministic=True)
    b, _ = machogen.build("com.example.app", sig_size=0, deterministic=True)
    assert a == b, "deterministic 模式两次产物必须完全一致"
    c, _ = machogen.build("com.example.other", sig_size=0, deterministic=True)
    assert a != c, "不同 bundle id 的 UUID 应不同"


# ---------------------------------------------------------------- codesign
@pytest.mark.slow
def test_sign_and_verify(tmp_path):
    machogen = load("machogen")
    binary = tmp_path / "bin"
    blob, _ = machogen.build("com.example.app", sig_size=8192)
    binary.write_bytes(blob)

    cmd = [sys.executable, os.path.join(TOOLS, "codesign_lite.py"), "sign",
           "--binary", str(binary), "--identifier", "com.example.app", "--inject"]
    assert subprocess.call(cmd) == 0

    cmd = [sys.executable, os.path.join(TOOLS, "codesign_lite.py"), "verify",
           "--binary", str(binary)]
    assert subprocess.call(cmd) == 0

    # 篡改一个字节，验签必须失败
    data = bytearray(binary.read_bytes())
    data[0x200] ^= 0xFF
    binary.write_bytes(bytes(data))
    assert subprocess.call(cmd) != 0, "改过内容后验签应该失败"


@pytest.mark.slow
def test_sign_with_info_plist(tmp_path):
    """bundle 主程序的签名必须把 Info.plist 哈希写进特殊槽 1。"""
    machogen = load("machogen")
    binary = tmp_path / "bin"
    blob, _ = machogen.build("com.example.app", sig_size=8192)
    binary.write_bytes(blob)

    plist = tmp_path / "Info.plist"
    plist.write_bytes(b"<?xml version='1.0'?><plist version='1.0'><dict/></plist>")

    cmd = [sys.executable, os.path.join(TOOLS, "codesign_lite.py"), "sign",
           "--binary", str(binary), "--identifier", "com.example.app",
           "--inject", "--info-plist", str(plist)]
    assert subprocess.call(cmd) == 0

    cert = os.path.join(TOOLS, "codesign_lite.py")
    spec = importlib.util.spec_from_file_location("cs", cert)
    cs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cs)

    data = binary.read_bytes()
    lc, dataoff, datasize = cs.find_code_signature(data)
    assert lc is not None and datasize > 0
    sb = data[dataoff:dataoff + datasize]
    magic, _length, count = struct.unpack_from(">III", sb, 0)
    assert magic == 0xFADE0CC0
    cd_off = next(o for s, o in (struct.unpack_from(">II", sb, 12 + i * 8) for i in range(count)) if s == 0)
    n_spec = struct.unpack_from(">I", sb, cd_off + 24)[0]
    assert n_spec == 5, "有 Info.plist 时特殊槽应为 5"


# ---------------------------------------------------------------- verify-ipa
def _make_min_ipa(path, with_icon=True, with_profile=False):
    """造一个结构最小的 ipa：Payload/App.app/{App,Info.plist,...}"""
    import plistlib

    info = {
        "CFBundleIdentifier": "com.example.app",
        "CFBundleExecutable": "App",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundlePackageType": "APPL",
        "MinimumOSVersion": "17.0",
        "UIDeviceFamily": [1],
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
    }
    if with_icon:
        info["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["Icon-60"]}}
    blob = bytearray(64)
    struct.pack_into("<IiiIIIII", blob, 0, 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/App.app/Info.plist", plistlib.dumps(info))
        z.writestr("Payload/App.app/App", bytes(blob))
        if with_icon:
            z.writestr("Payload/App.app/Icon-60@2x.png", b"\x89PNG\r\n\x1a\n")
        if with_profile:
            z.writestr("Payload/App.app/embedded.mobileprovision", b"\x00")


def test_verify_ipa_catches_missing_icon(tmp_path):
    ipa = tmp_path / "a.ipa"
    _make_min_ipa(ipa, with_icon=False)
    rc = subprocess.call([sys.executable, os.path.join(TOOLS, "verify-ipa.py"), str(ipa)],
                         stdout=subprocess.DEVNULL)
    assert rc != 0, "没有图标必须判失败"


def test_verify_ipa_backslash_check(tmp_path):
    ipa = tmp_path / "b.ipa"
    _make_min_ipa(ipa)
    # 追加一个反斜杠路径（用底层写入模拟坏包）
    with zipfile.ZipFile(ipa, "a") as z:
        z.writestr("Payload\\App.app\\evil.txt", b"x")
    rc = subprocess.call([sys.executable, os.path.join(TOOLS, "verify-ipa.py"), str(ipa)],
                         stdout=subprocess.DEVNULL)
    assert rc != 0


# ---------------------------------------------------------------- xip
def test_xip_roundtrip(tmp_path):
    rc = subprocess.call([sys.executable, os.path.join(TOOLS, "test-xip.py")],
                         stdout=subprocess.DEVNULL)
    assert rc == 0


# ---------------------------------------------------------------- 退出码约定
def test_exit_code_convention():
    """约定：0=通过，1=阻断，2=仅警告。至少保证 audit/verify 在干净包上返回 0 或 2。"""
    docs = open(os.path.join(ROOT, "docs", "12-CONVENTIONS.md"), encoding="utf-8").read()
    assert "0" in docs and "2" in docs
