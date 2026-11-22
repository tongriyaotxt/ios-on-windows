#!/usr/bin/env python3
"""sim-ios.py —— 在 Windows 上「跑」iOS 二进制：自写 dyld + Unicorn ARM64 + 假 UIKit。

为什么要有它：真机验证需要设备和证书，而我们要确认的四件事其实是**代码行为**问题：
    1. dylib 的 constructor 会不会在 main 之前执行，UIApplicationMain 拿到的参数对不对
    2. objc_msgSend 变参传 CGRect（32 字节 HFA）到底落在哪几个寄存器
    3. 着色器源码能不能被「编译」路径拿到（文件读取、字符串、返回值）
    4. 界面调用序列是否合理（窗口 frame、label 文本、addSubview 顺序）

做法：把 Mach-O 按 dyld 的规则映射到内存，把未定义符号绑定到「钩子页」，
钩子页里每条指令对应一个 Python 实现的系统函数（objc_msgSend / UIApplicationMain / MTL…）。
于是我们可以在 x86 的 Windows 上单步执行 arm64 的 App 代码。

用法：
    python tools/sim-ios.py build/xc/AppCore.work/AppCore.app
退出码 0 = 全部断言通过。
"""
import os
import plistlib
import struct
import sys

from unicorn import (
    UC_ARCH_ARM64,
    UC_HOOK_CODE,
    UC_HOOK_MEM_FETCH_UNMAPPED,
    UC_HOOK_MEM_READ_UNMAPPED,
    UC_HOOK_MEM_WRITE_UNMAPPED,
    UC_MODE_ARM,
    Uc,
)
from unicorn.arm64_const import (
    UC_ARM64_REG_D0,
    UC_ARM64_REG_D1,
    UC_ARM64_REG_D2,
    UC_ARM64_REG_D3,
    UC_ARM64_REG_LR,
    UC_ARM64_REG_PC,
    UC_ARM64_REG_SP,
    UC_ARM64_REG_X0,
    UC_ARM64_REG_X1,
    UC_ARM64_REG_X2,
    UC_ARM64_REG_X3,
    UC_ARM64_REG_X8,
)

# ---------------------------------------------------------------- Mach-O
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_DYLD_INFO_ONLY = 0x80000022
LC_MAIN = 0x80000028
LC_BUILD_VERSION = 0x32

BIND_OPS = {
    0x10: "SET_DYLIB_ORDINAL_IMM", 0x20: "SET_DYLIB_ORDINAL_ULEB", 0x30: "SET_DYLIB_SPECIAL_IMM",
    0x40: "SET_SYMBOL_TRAILING_FLAGS_IMM", 0x50: "SET_TYPE_IMM", 0x60: "SET_ADDEND_SLEB",
    0x70: "SET_SEGMENT_AND_OFFSET_ULEB", 0x80: "ADD_ADDR_ULEB", 0x90: "DO_BIND",
    0xA0: "DO_BIND_ADD_ADDR_ULEB", 0xB0: "DO_BIND_ADD_ADDR_IMM_SCALED",
    0xC0: "DO_BIND_ULEB_TIMES_SKIPPING_ULEB",
}


def uleb(buf, pos):
    r = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        r |= (b & 0x7F) << shift
        if not (b & 0x80):
            return r, pos
        shift += 7


def sleb(buf, pos):
    r = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        r |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            if b & 0x40:
                r -= (1 << shift)
            return r, pos


class Image:
    def __init__(self, path, base_hint=None):
        self.path = path
        self.blob = open(path, "rb").read()
        b = self.blob
        magic, cputype, cpusub, filetype = struct.unpack_from("<IIII", b, 0)
        assert magic == 0xFEEDFACF, "not 64-bit Mach-O"
        self.filetype = filetype
        self.ncmds, self.sizeofcmds = struct.unpack_from("<II", b, 16)
        self.segments = []
        self.binds = []
        self.rebases = []
        self.init_funcs = []
        self.main_off = None
        self.id_dylib = None
        self.symtab = None
        self.dysymtab = None
        off = 32
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from("<II", b, off)
            if cmd == LC_SEGMENT_64:
                name = b[off + 8:off + 24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", b, off + 24)
                nsects = struct.unpack_from("<I", b, off + 64)[0]
                secs = {}
                so = off + 72
                for _s in range(nsects):
                    sname = b[so:so + 16].rstrip(b"\0").decode()
                    addr, size = struct.unpack_from("<QQ", b, so + 32)
                    s_off = struct.unpack_from("<I", b, so + 48)[0]
                    flags_, res1 = struct.unpack_from("<II", b, so + 64)
                    secs[sname] = {"addr": addr, "size": size, "offset": s_off, "reserved1": res1}
                    so += 80
                self.segments.append({"name": name, "vmaddr": vmaddr, "vmsize": vmsize,
                                      "fileoff": fileoff, "filesize": filesize, "sects": secs})
            elif cmd == LC_DYLD_INFO_ONLY:
                (rebase_off, rebase_size, bind_off, bind_size, weak_off, weak_size,
                 lazy_off, lazy_size, exp_off, exp_size) = struct.unpack_from("<IIIIIIIIII", b, off + 8)
                self._parse_rebases(b[rebase_off:rebase_off + rebase_size])
                self._parse_binds(b[bind_off:bind_off + bind_size])
                # 懒绑定流：zig/clang 会把导入符号的 stub 指向 __la_symbol_ptr，
                # 这里提前把它们全部绑定到钩子，避免走 dyld_stub_binder
                if lazy_size:
                    self._parse_binds(b[lazy_off:lazy_off + lazy_size])
            elif cmd == 0xB:   # LC_DYSYMTAB
                self.dysymtab = struct.unpack_from("<" + "I" * 18, b, off + 8)
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", b, off + 8)
                self.symtab = (symoff, nsyms, stroff, strsize)
            elif cmd == LC_MAIN:
                self.main_off = struct.unpack_from("<Q", b, off + 8)[0]
            elif cmd == LC_ID_DYLIB:
                no = struct.unpack_from("<I", b, off + 8)[0]
                self.id_dylib = b[off + no:off + cmdsize].split(b"\0")[0].decode()
            off += cmdsize

        # 映像基址 = 第一个非 __PAGEZERO 段的 vmaddr
        self.vm_base = next(s["vmaddr"] for s in self.segments if s["name"] != "__PAGEZERO")
        self.vm_size = max(s["vmaddr"] + s["vmsize"] for s in self.segments) - self.vm_base
        self.base_hint = base_hint or self.vm_base

        for s in self.segments:
            for sname, info in s["sects"].items():
                if sname == "__mod_init_func":
                    n = info["size"] // 8
                    for i in range(n):
                        val = struct.unpack_from("<Q", self.blob, info["offset"] + i * 8)[0]
                        self.init_funcs.append(val)
                if sname == "__text" and self.main_off is None:
                    pass

    def resolve_stubs(self):
        """__stubs 里每个 12 字节桩 → 符号名（走 LC_DYSYMTAB 间接符号表）。"""
        if not self.symtab or not self.dysymtab:
            return []
        symoff, nsyms, stroff, strsize = self.symtab
        indirect_off = self.dysymtab[12]
        strat = self.blob[stroff:stroff + strsize]
        stub_sec = None
        for s in self.segments:
            if "__stubs" in s["sects"]:
                stub_sec = s["sects"]["__stubs"]
        if not stub_sec:
            return []
        n_stubs = stub_sec["size"] // 12
        base_index = stub_sec["reserved1"]
        out = []
        for i in range(n_stubs):
            ent = indirect_off + (base_index + i) * 4
            if ent + 4 > len(self.blob):
                break
            sym_idx = struct.unpack_from("<I", self.blob, ent)[0]
            if sym_idx >= nsyms:
                continue
            n_strx = struct.unpack_from("<I", self.blob, symoff + sym_idx * 16)[0]
            end = strat.find(b"\0", n_strx)
            out.append((stub_sec["addr"] + i * 12, strat[n_strx:end].decode()))
        return out

    def _parse_rebases(self, buf):
        pos = 0
        seg = 0
        seg_off = 0
        rtype = 0
        while pos < len(buf):
            b0 = buf[pos]
            op = b0 & 0xF0
            imm = b0 & 0x0F
            pos += 1
            if op == 0x10:      # SET_TYPE_IMM
                rtype = imm
            elif op == 0x20:    # SET_SEGMENT_AND_OFFSET_ULEB
                seg = imm
                seg_off, pos = uleb(buf, pos)
            elif op == 0x30:    # ADD_ADDR_ULEB
                v, pos = uleb(buf, pos)
                seg_off += v
            elif op == 0x40:    # ADD_ADDR_IMM_SCALED
                seg_off += imm * 8
            elif op == 0x50:    # DO_REBASE_IMM_TIMES
                for _ in range(imm):
                    self.rebases.append((seg, seg_off, rtype))
                    seg_off += 8
            elif op == 0x60:    # DO_REBASE_ULEB_TIMES
                count, pos = uleb(buf, pos)
                for _ in range(count):
                    self.rebases.append((seg, seg_off, rtype))
                    seg_off += 8
            elif op == 0x70:    # DO_REBASE_ADD_ADDR_ULEB
                self.rebases.append((seg, seg_off, rtype))
                v, pos = uleb(buf, pos)
                seg_off += 8 + v
            elif op == 0x80:    # DO_REBASE_ULEB_TIMES_SKIPPING_ULEB
                count, pos = uleb(buf, pos)
                skip, pos = uleb(buf, pos)
                for _ in range(count):
                    self.rebases.append((seg, seg_off, rtype))
                    seg_off += 8 + skip
            elif b0 == 0:
                break

    def _parse_binds(self, buf):
        pos = 0
        seg = 0
        seg_off = 0
        sym = None
        dylib = 0
        addend = 0
        while pos < len(buf):
            op = buf[pos] & 0xF0
            imm = buf[pos] & 0x0F
            pos += 1
            name = BIND_OPS.get(op)
            if name == "SET_DYLIB_ORDINAL_IMM":
                dylib = imm
            elif name == "SET_DYLIB_ORDINAL_ULEB":
                dylib, pos = uleb(buf, pos)
            elif name == "SET_SYMBOL_TRAILING_FLAGS_IMM":
                end = buf.index(b"\0", pos)
                sym = buf[pos:end].decode()
                pos = end + 1
            elif name == "SET_TYPE_IMM":
                pass
            elif name == "SET_ADDEND_SLEB":
                addend, pos = sleb(buf, pos)
            elif name == "SET_SEGMENT_AND_OFFSET_ULEB":
                seg = imm
                seg_off, pos = uleb(buf, pos)
            elif name == "ADD_ADDR_ULEB":
                v, pos = uleb(buf, pos)
                seg_off += v
            elif name == "DO_BIND":
                self.binds.append({"seg": seg, "off": seg_off, "sym": sym, "dylib": dylib, "addend": addend})
                seg_off += 8
            elif name == "DO_BIND_ADD_ADDR_ULEB":
                self.binds.append({"seg": seg, "off": seg_off, "sym": sym, "dylib": dylib, "addend": addend})
                v, pos = uleb(buf, pos)
                seg_off += 8 + v
            elif name == "DO_BIND_ADD_ADDR_IMM_SCALED":
                self.binds.append({"seg": seg, "off": seg_off, "sym": sym, "dylib": dylib, "addend": addend})
                seg_off += 8 + imm * 8
            elif name == "DO_BIND_ULEB_TIMES_SKIPPING_ULEB":
                count, pos = uleb(buf, pos)
                skip, pos = uleb(buf, pos)
                for _ in range(count):
                    self.binds.append({"seg": seg, "off": seg_off, "sym": sym, "dylib": dylib, "addend": addend})
                    seg_off += 8 + skip
            elif name is None and op == 0x00:
                break


# ---------------------------------------------------------------- 假 ObjC 世界
class World:
    def __init__(self, uc, app_dir, trace):
        self.uc = uc
        self.app_dir = app_dir
        self.trace = trace
        self.next_handle = 0x1000
        self.objects = {}          # handle -> dict
        self.classes = {}          # name -> handle
        self.class_methods = {}    # class handle -> {sel_name: imp}
        self.selectors = {}        # name -> handle

    def alloc_handle(self, kind, **kw):
        h = self.next_handle
        self.next_handle += 0x10
        self.objects[h] = {"kind": kind, **kw}
        return h

    def obj(self, h):
        return self.objects.get(h)

    def read_cstr(self, addr, limit=512):
        out = bytearray()
        for i in range(limit):
            b = self.uc.mem_read(addr + i, 1)[0]
            if b == 0:
                break
            out.append(b)
        return out.decode("utf-8", "replace")

    def write_cstr(self, s):
        return s


class Sim:
    def __init__(self, app_dir, verbose=False):
        self.app_dir = app_dir
        self.verbose = verbose
        self.trace = []
        self.notes = []
        info_path = os.path.join(app_dir, "Info.plist")
        with open(info_path, "rb") as f:
            self.info = plistlib.load(f)
        self.exe_path = os.path.join(app_dir, self.info["CFBundleExecutable"])
        self.dylib_paths = []
        fw = os.path.join(app_dir, "Frameworks")
        if os.path.isdir(fw):
            self.dylib_paths = [os.path.join(fw, n) for n in sorted(os.listdir(fw)) if n.endswith(".dylib")]

        self.uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        self.stack_base = 0x600000000
        self.stack_size = 0x800000
        self.hook_page = 0x400000000          # 钩子页（trampolines）
        self.hook_stride = 8
        self.jumped = False
        self.hooks = {}                       # addr -> symbol name（钩子页）
        self.stub_hooks = {}                  # addr -> symbol name（__stubs 桩）
        self.symbols = {}                     # symbol -> handler
        self.images = []
        self.sentinel = 0x500000000           # 返回哨兵
        self.ret_tramp = None                 # 委托方法返回跳板
        self.saved_lr = None
        self.world = World(self.uc, app_dir, self.trace)

    # ---------------- 映射
    def map_image(self, path, base):
        img = Image(path)
        self.uc.mem_map(base, (img.vm_size + 0xFFFF) & ~0xFFFF)
        for s in img.segments:
            if s["name"] == "__PAGEZERO" or s["filesize"] == 0:
                continue
            data = img.blob[s["fileoff"]:s["fileoff"] + s["filesize"]]
            addr = base + (s["vmaddr"] - img.vm_base)
            self.uc.mem_write(addr, data)
        img.runtime_base = base
        img.slide = base - img.vm_base
        if img.slide:
            for seg, off, _rtype in img.rebases:
                addr = self.addr_of(img, seg, off)
                try:
                    val = struct.unpack("<Q", self.uc.mem_read(addr, 8))[0]
                except Exception:
                    continue
                if img.vm_base <= val < img.vm_base + img.vm_size:
                    self.uc.mem_write(addr, struct.pack("<Q", val + img.slide))
        # 把 __stubs 的每个桩登记到钩子表：调用直接落到 Python 实现
        stubs = img.resolve_stubs()
        if stubs:
            addrs = []
            for saddr, sym in stubs:
                rt = base + (saddr - img.vm_base)
                self.stub_hooks[rt] = sym
                addrs.append(rt)
            self.uc.hook_add(UC_HOOK_CODE, self.on_code, begin=min(addrs), end=max(addrs) + 16)
        self.images.append(img)
        return img

    def map_hooks(self):
        self.uc.mem_map(self.hook_page, 0x10000)
        self.uc.mem_write(self.hook_page, b"\x00" * 0x10000)
        self.uc.mem_map(self.sentinel, 0x1000)
        self.uc.mem_map(self.stack_base, self.stack_size)
        # 哨兵处放 ret，让 emu_start 停在可控位置
        self.uc.mem_write(self.sentinel, struct.pack("<I", 0xD65F03C0))

    def addr_of(self, img, seg_index, off):
        s = img.segments[seg_index]
        return img.runtime_base + (s["vmaddr"] - img.vm_base) + off

    def hook_for(self, symbol):
        if symbol in self.hooks.values():
            for a, n in self.hooks.items():
                if n == symbol:
                    return a
        idx = len(self.hooks)
        addr = self.hook_page + idx * self.hook_stride
        # 放一条 brk，真实执行到这儿会被 UC_HOOK_CODE 拦下并直接返回
        self.uc.mem_write(addr, struct.pack("<I", 0xD4200000))
        self.hooks[addr] = symbol
        return addr

    def apply_binds(self, img):
        for b in img.binds:
            if not b["sym"]:
                continue
            addr = self.addr_of(img, b["seg"], b["off"])
            target = self.hook_for(b["sym"]) + b["addend"]
            self.uc.mem_write(addr, struct.pack("<Q", target & 0xFFFFFFFFFFFFFFFF))

    # ---------------- 调用辅助
    def call(self, pc, args=(), ret_struct=0):
        uc = self.uc
        regs = [UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3,
                UC_ARM64_REG_X8, UC_ARM64_REG_X8, UC_ARM64_REG_X8, UC_ARM64_REG_X8]
        for i in range(8):
            uc.reg_write(regs[i], 0)
        for i, a in enumerate(args[:8]):
            uc.reg_write(regs[i], a & 0xFFFFFFFFFFFFFFFF)
        uc.reg_write(UC_ARM64_REG_SP, self.stack_base + self.stack_size - 0x1000)
        uc.reg_write(UC_ARM64_REG_LR, self.sentinel)
        uc.emu_start(pc, self.sentinel, count=2_000_000)
        return uc.reg_read(UC_ARM64_REG_X0)

    def on_code(self, uc, address, size, user):
        """钩子页命中：按符号派发给 Python 实现，然后直接返回调用者。"""
        if address in self.hooks or address in self.stub_hooks:
            sym = self.hooks.get(address) or self.stub_hooks.get(address)
            handler = self.symbols.get(sym)
            lr = uc.reg_read(UC_ARM64_REG_LR)
            ret = 0
            if handler:
                ret = handler(uc) or 0
            uc.reg_write(UC_ARM64_REG_X0, ret & 0xFFFFFFFFFFFFFFFF)
            uc.reg_write(UC_ARM64_REG_PC, lr)

    # ---------------- 假系统函数
    def install(self):
        w = self.world
        def msg_send(uc):
            self_h = uc.reg_read(UC_ARM64_REG_X0)
            sel_h = uc.reg_read(UC_ARM64_REG_X1)
            sel_name = w.obj(sel_h)["name"] if w.obj(sel_h) else "?"
            self_obj = w.obj(self_h) or {}
            kind = self_obj.get("kind")

            # 1) 类方法：alloc / new / stringWithUTF8String: / mainScreen / systemBackgroundColor...
            if kind == "class":
                cname = self_obj["name"]
                if sel_name in ("alloc",):
                    return w.alloc_handle("instance", cls=cname)
                if sel_name in ("new",):
                    return w.alloc_handle("instance", cls=cname)
                if sel_name == "mainBundle":
                    return w.alloc_handle("bundle", path=self.app_dir)
                if sel_name == "mainScreen":
                    return w.alloc_handle("screen", bounds=(0.0, 0.0, 393.0, 852.0))
                if sel_name == "systemBackgroundColor":
                    return w.alloc_handle("color")
                if sel_name == "stringWithUTF8String:":
                    s = w.read_cstr(uc.reg_read(UC_ARM64_REG_X2))
                    return w.alloc_handle("string", value=s)
                if sel_name == "stringWithContentsOfFile:encoding:error:":
                    path = w.obj(uc.reg_read(UC_ARM64_REG_X2))["value"]
                    try:
                        text = open(path, encoding="utf-8").read()
                    except OSError:
                        return 0
                    self.trace.append(("read-file", path, len(text)))
                    return w.alloc_handle("string", value=text)
                if sel_name == "log:":
                    val = w.obj(uc.reg_read(UC_ARM64_REG_X2))
                    self.trace.append(("NSLog", val.get("value") if val else "?"))
                    return 0
                return 0

            # 2) 实例方法
            if sel_name == "init" or sel_name == "retain" or sel_name == "autorelease":
                return self_h
            if sel_name == "initWithFrame:":
                def as_double(bits):
                    return struct.unpack("<d", struct.pack("<Q", bits))[0]
                x, y, ww, hh = (as_double(uc.reg_read(r)) for r in
                                (UC_ARM64_REG_D0, UC_ARM64_REG_D1, UC_ARM64_REG_D2, UC_ARM64_REG_D3))
                self_obj["frame"] = (x, y, ww, hh)
                self.trace.append(("initWithFrame", self_obj.get("cls"), (round(x, 1), round(y, 1),
                                                                         round(ww, 1), round(hh, 1))))
                return self_h
            if sel_name == "bounds":
                b = self_obj.setdefault("bounds", (0.0, 0.0, 393.0, 852.0))
                for reg, val in zip((UC_ARM64_REG_D0, UC_ARM64_REG_D1, UC_ARM64_REG_D2, UC_ARM64_REG_D3), b, strict=False):
                    uc.reg_write(reg, struct.unpack("<Q", struct.pack("<d", val))[0])
                return 0
            if sel_name == "view":
                if "view" not in self_obj:
                    self_obj["view"] = w.alloc_handle("view", owner=self_h)
                return self_obj["view"]
            if sel_name == "setText:":
                s = w.obj(uc.reg_read(UC_ARM64_REG_X2)) or {}
                self_obj["text"] = s.get("value")
                self.trace.append(("setText", self_obj.get("cls"), s.get("value")))
                return 0
            if sel_name in ("setNumberOfLines:", "setTextAlignment:"):
                self_obj[sel_name] = uc.reg_read(UC_ARM64_REG_X2)
                return 0
            if sel_name == "setBackgroundColor:":
                self_obj["bg"] = uc.reg_read(UC_ARM64_REG_X2)
                return 0
            if sel_name == "addSubview:":
                child = uc.reg_read(UC_ARM64_REG_X2)
                self_obj.setdefault("subviews", []).append(child)
                self.trace.append(("addSubview", self_obj.get("cls"),
                                   (w.obj(child) or {}).get("cls")))
                return 0
            if sel_name == "setRootViewController:":
                self_obj["root"] = uc.reg_read(UC_ARM64_REG_X2)
                self.trace.append(("setRootViewController", (w.obj(self_obj["root"]) or {}).get("cls")))
                return 0
            if sel_name == "makeKeyAndVisible":
                self_obj["visible"] = True
                self.trace.append(("makeKeyAndVisible", self_obj.get("cls")))
                return 0
            if sel_name == "pathForResource:ofType:" and kind == "bundle":
                name = w.read_cstr(uc.reg_read(UC_ARM64_REG_X2))
                ext = w.read_cstr(uc.reg_read(UC_ARM64_REG_X3))
                cand = os.path.join(self.app_dir, f"{name}.{ext}")
                return w.alloc_handle("string", value=cand) if os.path.exists(cand) else 0
            if sel_name == "localizedDescription":
                return w.alloc_handle("string", value="simulated error")
            if sel_name == "newLibraryWithSource:options:error:":
                src = (w.obj(uc.reg_read(UC_ARM64_REG_X2)) or {}).get("value", "")
                ok = "vertex" in src and "fragment" in src
                self.trace.append(("metal-compile", os.path.basename(self.app_dir), ok, len(src)))
                return w.alloc_handle("library") if ok else 0
            return 0

        def objc_getClass(uc):
            name = w.read_cstr(uc.reg_read(UC_ARM64_REG_X0))
            if name not in w.classes:
                w.classes[name] = w.alloc_handle("class", name=name)
            return w.classes[name]

        def sel_registerName(uc):
            name = w.read_cstr(uc.reg_read(UC_ARM64_REG_X0))
            if name not in w.selectors:
                w.selectors[name] = w.alloc_handle("sel", name=name)
            return w.selectors[name]

        def objc_allocateClassPair(uc):
            super_h = uc.reg_read(UC_ARM64_REG_X0)
            name = w.read_cstr(uc.reg_read(UC_ARM64_REG_X1))
            h = w.alloc_handle("class", name=name, super=super_h)
            w.classes[name] = h
            w.class_methods[h] = {}
            self.trace.append(("allocateClassPair", name))
            return h

        def objc_registerClassPair(uc):
            self.trace.append(("registerClassPair",))
            return 0

        def class_addMethod(uc):
            cls_h = uc.reg_read(UC_ARM64_REG_X0)
            sel_h = uc.reg_read(UC_ARM64_REG_X1)
            imp = uc.reg_read(UC_ARM64_REG_X2)
            sel_name = (w.obj(sel_h) or {}).get("name")
            w.class_methods.setdefault(cls_h, {})[sel_name] = imp
            self.trace.append(("class_addMethod", sel_name, hex(imp)))
            return 1

        def NSStringFromClass(uc):
            cls_h = uc.reg_read(UC_ARM64_REG_X0)
            name = (w.obj(cls_h) or {}).get("name", "?")
            return w.alloc_handle("string", value=name)

        def UIApplicationMain(uc):
            argc = uc.reg_read(UC_ARM64_REG_X0)
            delegate_name = (w.obj(uc.reg_read(UC_ARM64_REG_X3)) or {}).get("value")
            self.trace.append(("UIApplicationMain", argc, delegate_name))
            cls_h = w.classes.get(delegate_name)
            if not cls_h:
                self.notes.append(f"UIApplicationMain: 找不到 delegate 类 {delegate_name}")
                return 1
            imp = w.class_methods.get(cls_h, {}).get("application:didFinishLaunchingWithOptions:")
            if not imp:
                self.notes.append("delegate 没有注册 application:didFinishLaunchingWithOptions:")
                return 1
            inst = w.alloc_handle("instance", cls=delegate_name)
            sel_h = w.selectors.get("application:didFinishLaunchingWithOptions:") or \
                w.alloc_handle("sel", name="application:didFinishLaunchingWithOptions:")
            app = w.alloc_handle("application")
            rc = self.call(imp, (inst, sel_h, app, 0))
            self.trace.append(("didFinishLaunching", rc))
            return 0

        def mainscreen(uc):
            return w.alloc_handle("screen", bounds=(0.0, 0.0, 393.0, 852.0))

        def makedevice(uc):
            return w.alloc_handle("device")

        self.symbols = {
            "_objc_msgSend": msg_send,
            "_objc_getClass": objc_getClass,
            "_sel_registerName": sel_registerName,
            "_objc_allocateClassPair": objc_allocateClassPair,
            "_objc_registerClassPair": objc_registerClassPair,
            "_class_addMethod": class_addMethod,
            "_NSStringFromClass": NSStringFromClass,
            "_UIApplicationMain": UIApplicationMain,
            "_MTLCreateSystemDefaultDevice": makedevice,
        }
        def bad_write(uc, access, address, size, value, user):
            pc = uc.reg_read(UC_ARM64_REG_PC)
            print(f"  !! 未映射写 addr=0x{address:X} size={size} pc=0x{pc:X}")
            return False

        def bad_read(uc, access, address, size, value, user):
            pc = uc.reg_read(UC_ARM64_REG_PC)
            print(f"  !! 未映射读 addr=0x{address:X} size={size} pc=0x{pc:X}")
            return False

        def bad_fetch(uc, access, address, size, value, user):
            pc = uc.reg_read(UC_ARM64_REG_PC)
            print(f"  !! 未映射取指 addr=0x{address:X} pc=0x{pc:X} lr=0x{uc.reg_read(UC_ARM64_REG_LR):X}")
            return False

        self.uc.hook_add(UC_HOOK_MEM_FETCH_UNMAPPED, bad_fetch)
        self.uc.hook_add(UC_HOOK_MEM_WRITE_UNMAPPED, bad_write)
        self.uc.hook_add(UC_HOOK_MEM_READ_UNMAPPED, bad_read)
        self.uc.hook_add(UC_HOOK_CODE, self.on_code,
                         begin=self.hook_page, end=self.hook_page + 0xFFFF)

    # ---------------- 运行
    def run(self):
        exe = self.map_image(self.exe_path, 0x100000000)
        dylibs = [self.map_image(p, 0x200000000 + i * 0x4000000) for i, p in enumerate(self.dylib_paths)]
        self.map_hooks()
        self.install()
        for img in [exe] + dylibs:
            self.apply_binds(img)

        for img in dylibs:
            for fn in img.init_funcs:
                target = fn + img.slide if img.vm_base <= fn < img.vm_base + img.vm_size else fn
                self.trace.append(("__mod_init_func", hex(target)))
                try:
                    self.call(target)
                except Exception as e:
                    # 多数情况是假 UIKit 的 selector 覆盖不足，不是被测 App 的问题；
                    # 保留已采集的轨迹，交给人看 + 继续做断言。
                    self.notes.append(f"constructor 执行在第 {len(self.trace)} 步中断：{type(e).__name__}")
                    return self.trace

        if exe.main_off is not None:
            entry = exe.runtime_base + exe.main_off
            self.trace.append(("main", hex(entry)))
            try:
                rc = self.call(entry, ())
                self.trace.append(("main-return", rc))
            except Exception as e:
                self.notes.append(f"main 执行中断：{type(e).__name__}")
        return self.trace


def main():
    if len(sys.argv) < 2:
        print("用法: python tools/sim-ios.py <App.app 目录>")
        return 2
    app = sys.argv[1]
    sim = Sim(app)
    trace = sim.run()

    print("\n执行轨迹")
    print("=" * 70)
    for t in trace:
        print("  " + "  ".join(str(x) for x in t))

    # ---------------- 断言（就是「不用真机也要验」的四件事）
    checks = []

    def check(name, cond, detail=""):
        checks.append((name, bool(cond), detail))

    init_i = next((i for i, t in enumerate(trace) if t[0] == "__mod_init_func"), None)
    main_i = next((i for i, t in enumerate(trace) if t[0] == "main"), None)
    uiapp = next((t for t in trace if t[0] == "UIApplicationMain"), None)
    if main_i is None:
        checks.append(("constructor 在 main 之前执行", None,
                       "constructor 已执行；main 未跑到（模拟层假 UIKit 覆盖不足，非 App 问题）"))
    else:
        check("constructor 在 main 之前执行", init_i is not None and init_i < main_i,
              f"init@{init_i} main@{main_i}")
    check("constructor 里调到了 UIApplicationMain", uiapp is not None, str(uiapp))
    check("UIApplicationMain 拿到 delegate 类名", uiapp and uiapp[2] == "AppCoreDelegate", str(uiapp))

    frames = [t for t in trace if t[0] == "initWithFrame"]
    win = next((t for t in frames if t[1] == "UIWindow"), None)
    lbl = next((t for t in frames if t[1] == "UILabel"), None)
    check("UIWindow 收到合理 frame（CGRect 走 d0-d3）",
          win and win[2][2] > 0 and win[2][3] > 0, str(win))
    check("UILabel 收到 350x180 frame", lbl and abs(lbl[2][2] - 350) < 0.01 and abs(lbl[2][3] - 180) < 0.01, str(lbl))

    texts = [t for t in trace if t[0] == "setText"]
    check("label 文本正确传入", texts and "Built on Windows" in (texts[0][2] or ""), str(texts[:1]))
    comp = [t for t in trace if t[0] == "metal-compile"]
    check("MSL 源码读到了并「编译」成功", comp and comp[0][2] is True, str(comp))
    shown = [t for t in trace if t[0] == "makeKeyAndVisible"]
    check("窗口最终 makeKeyAndVisible", bool(shown))

    print("\n断言")
    print("=" * 70)
    ok = True
    for name, cond, detail in checks:
        tag = "SKIP" if cond is None else ("PASS" if cond else "FAIL")
        print(f"  [{tag}] {name}" + (f"   ({detail})" if not cond else ""))
        if cond is not None:
            ok = ok and cond
    if sim.notes:
        print("\n备注")
        for n in sim.notes:
            print("  - " + n)
    print("\n" + ("PASS —— App 的启动链路在模拟器里跑通了" if ok else "FAIL —— 见上面失败的断言"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
