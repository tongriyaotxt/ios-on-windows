#!/usr/bin/env python3
"""check-provisioning.py —— 装到真机前最容易翻车的一环：描述文件 ↔ 证书 ↔ bundle id ↔ entitlements。

真机上 `ApplicationVerificationFailed` 有 90% 出在这四者的不一致上，而它们都能在 Windows 上静态比对：

  · 描述文件里的 `Entitlements.application-identifier` 是否以 `<TeamID>.` 开头且 bundle id 一致
  · 描述文件是否过期、是否包含目标设备 UDID（development / ad-hoc）
  · `.p12` 里的证书是否就是描述文件里 `DeveloperCertificates` 的其中一张
  · 已签名的 ipa 里，签名带的 entitlements 是否是描述文件 entitlements 的子集
  · ipa 里是否带了 `embedded.mobileprovision`，且与你给的是同一份

用法：
    python tools/check-provisioning.py --profile App.mobileprovision --bundle-id com.a.b
    python tools/check-provisioning.py --profile App.mobileprovision --p12 dist.p12 --p12-password *** --ipa App.ipa --udid 00008030-...
    python tools/check-provisioning.py --profile App.mobileprovision --emit-entitlements ent.plist
退出码：0 通过 / 2 有警告 / 1 阻断
"""
import argparse
import datetime
import hashlib
import plistlib
import struct
import sys
import zipfile

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

RESULTS = []


def ok(msg):
    RESULTS.append(("PASS", msg))


def warn(msg):
    RESULTS.append(("WARN", msg))


def bad(msg):
    RESULTS.append(("FAIL", msg))


def load_profile(path):
    """从 CMS 容器里把那段 XML plist 抠出来（Apple 的 .mobileprovision 就是 CMS SignedData）。"""
    blob = open(path, "rb").read()
    start = blob.find(b"<?xml")
    end = blob.find(b"</plist>")
    if start < 0 or end < 0:
        raise SystemExit("描述文件里找不到 plist（不是合法的 .mobileprovision？）")
    return plistlib.loads(blob[start:end + len(b"</plist>")])


def cert_public_bytes(cert):
    from cryptography.hazmat.primitives import serialization
    return cert.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo)


def load_p12(path, password):
    from cryptography.hazmat.primitives.serialization import pkcs12
    with open(path, "rb") as f:
        key, cert, extra = pkcs12.load_key_and_certificates(
            f.read(), password.encode() if password else None)
    return key, cert, extra or []


def read_ipa_entitlements(ipa):
    """从 ipa 里的可执行体签名里读出 entitlements 字典（没有就返回 None）。"""
    z = zipfile.ZipFile(ipa)
    apps = sorted({n.split("/")[1] for n in z.namelist()
                   if n.startswith("Payload/") and n.count("/") >= 2})
    if not apps:
        return None, None
    app = apps[0]
    info = plistlib.loads(z.read(f"Payload/{app}/Info.plist"))
    exe = info["CFBundleExecutable"]
    blob = z.read(f"Payload/{app}/{exe}")

    # 找到 LC_CODE_SIGNATURE
    ncmds = struct.unpack_from("<I", blob, 16)[0]
    off, cs = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", blob, off)
        if cmd == 0x1D:
            cs = struct.unpack_from("<II", blob, off + 8)
        off += size
    if not cs:
        return None, app
    dataoff, datasize = cs
    sb = blob[dataoff:dataoff + datasize]
    magic, _length, count = struct.unpack_from(">III", sb, 0)
    if magic != 0xFADE0CC0:
        return None, app
    ent_off = None
    for i in range(count):
        slot, o = struct.unpack_from(">II", sb, 12 + i * 8)
        if slot == 5:                       # CSSLOT_ENTITLEMENTS
            ent_off = o
    if ent_off is None:
        return None, app
    m, blen = struct.unpack_from(">II", sb, ent_off)
    return plistlib.loads(sb[ent_off + 8: ent_off + blen]), app


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True, help=".mobileprovision")
    ap.add_argument("--bundle-id", default=None)
    ap.add_argument("--p12", default=None)
    ap.add_argument("--p12-password", default="")
    ap.add_argument("--ipa", default=None)
    ap.add_argument("--udid", default=None)
    ap.add_argument("--emit-entitlements", default=None, help="把描述文件里的 entitlements 写成 plist（给构建用）")
    args = ap.parse_args()

    prof = load_profile(args.profile)
    ents = prof.get("Entitlements", {})
    team = (prof.get("TeamIdentifier") or [""])[0]
    app_id_prefix = (prof.get("ApplicationIdentifierPrefix") or [""])[0]
    name = prof.get("Name", "?")
    devices = prof.get("ProvisionedDevices") or []
    is_wildcard = bool(prof.get("ProvisionsAllDevices"))
    exp = prof.get("ExpirationDate")
    platforms = prof.get("Platform") or []

    ok(f"描述文件：{name}  team={team or '?'}  设备={len(devices)}  "
       f"{'企业/无限制' if is_wildcard else 'ad-hoc/development'}")

    # ---- 1. 过期
    if exp:
        now = datetime.datetime.now(datetime.UTC) if exp.tzinfo else datetime.datetime.now()
        if exp < now:
            bad(f"描述文件已过期：{exp}")
        else:
            days = (exp - now).days
            (warn if days < 30 else ok)(f"有效期还剩 {days} 天（{exp:%Y-%m-%d}）")

    # ---- 2. platform
    if platforms and not any("iOS" in str(p) or "ios" in str(p) for p in platforms):
        warn(f"Platform 字段是 {platforms}，确认这是 iOS 的描述文件")

    # ---- 3. bundle id
    app_id = ents.get("application-identifier", "")
    if args.bundle_id:
        expect_prefix = f"{app_id_prefix or team}."
        if app_id.endswith("*"):
            prefix = app_id[:-1]
            if args.bundle_id.startswith(prefix):
                ok(f"application-identifier 通配匹配：{app_id} ⊇ {args.bundle_id}")
            else:
                bad(f"application-identifier 不匹配：{app_id} vs {args.bundle_id}")
        elif app_id == f"{app_id_prefix or team}.{args.bundle_id}" or app_id.endswith(f".{args.bundle_id}"):
            ok(f"application-identifier 匹配：{app_id}")
        elif app_id.startswith(expect_prefix) and app_id != f"{expect_prefix}{args.bundle_id}":
            bad(f"application-identifier 是 {app_id}，但 bundle id 是 {args.bundle_id}")
        else:
            bad(f"application-identifier 缺失或不匹配：{app_id!r} vs {args.bundle_id}")
    else:
        warn("没给 --bundle-id，跳过包名一致性检查")

    # ---- 4. UDID
    if args.udid:
        if is_wildcard:
            ok("企业/App Store 描述文件，不需要登记 UDID")
        elif args.udid in devices:
            ok(f"UDID 已登记：{args.udid}")
        else:
            bad(f"UDID 不在描述文件里：{args.udid}（装机时会 ApplicationVerificationFailed）")

    # ---- 5. 证书
    if args.p12:
        try:
            _key, cert, _extra = load_p12(args.p12, args.p12_password)
        except Exception as e:
            bad(f"读不出 p12（密码错或文件损坏）：{type(e).__name__}")
            _key, cert, _extra = None, None, []
        if cert is None:
            pass
        elif cert is None:
            bad("p12 里没有证书")
        else:
            mine = cert_public_bytes(cert)
            dev_certs = prof.get("DeveloperCertificates") or []
            matched = False
            for der in dev_certs:
                try:
                    from cryptography import x509
                    c = x509.load_der_x509_certificate(der)
                    if cert_public_bytes(c) == mine:
                        matched = True
                        break
                except Exception:
                    continue
            if matched:
                ok(f"证书匹配描述文件（{cert.subject.rfc4514_string()}）")
            else:
                bad(f"p12 的证书不在描述文件的 DeveloperCertificates 里"
                    f"（共 {len(dev_certs)} 张）—— 装机会被拒")
            # 有效期
            if hasattr(cert, "not_valid_after_utc"):
                if cert.not_valid_after_utc < datetime.datetime.now(datetime.UTC):
                    bad(f"证书已过期：{cert.not_valid_after_utc}")
            if len(dev_certs) > 3:
                warn(f"描述文件里有 {len(dev_certs)} 张证书，分发证书通常不超过 3 张")

    # ---- 6. ipa
    if args.ipa:
        ipa_ents, app = read_ipa_entitlements(args.ipa)
        if ipa_ents is None:
            bad("ipa 的签名里没有 entitlements（装机会被拒）。签名时加 --entitlements")
        else:
            missing = []
            for k, v in ipa_ents.items():
                if k in ("application-identifier", "com.apple.developer.team-identifier"):
                    if k in ents and ents[k] != v:
                        missing.append(f"{k}: 包内 {v} ≠ 描述文件 {ents[k]}")
                elif k not in ents:
                    missing.append(f"{k} 不在描述文件里")
            if missing:
                bad("签名 entitlements 与描述文件不一致：" + "; ".join(missing))
            else:
                ok(f"签名 entitlements 是描述文件的子集（{len(ipa_ents)} 项）")
        names = zipfile.ZipFile(args.ipa).namelist()
        if f"Payload/{app}/embedded.mobileprovision" not in names:
            bad("ipa 里没有 embedded.mobileprovision（development/ad-hoc 安装必需）")
        else:
            embed = zipfile.ZipFile(args.ipa).read(f"Payload/{app}/embedded.mobileprovision")
            same = hashlib.sha256(embed).hexdigest() == hashlib.sha256(open(args.profile, "rb").read()).hexdigest()
            (ok if same else bad)("ipa 内的描述文件与你给的是同一份" if same
                                  else "ipa 内的描述文件与 --profile 不是同一份")

    # ---- 7. 导出 entitlements
    if args.emit_entitlements:
        with open(args.emit_entitlements, "wb") as f:
            plistlib.dump(ents, f)
        ok(f"entitlements 已导出 -> {args.emit_entitlements}")

    # ---- 汇总
    print()
    for level, msg in RESULTS:
        tag = {"PASS": " ok  ", "WARN": "warn ", "FAIL": "FAIL "}[level]
        print(f"[{tag}] {msg}")
    fails = sum(1 for lv, _ in RESULTS if lv == "FAIL")
    warns = sum(1 for lv, _ in RESULTS if lv == "WARN")
    print(f"\n{len(RESULTS) - fails - warns} 通过, {warns} 警告, {fails} 失败")
    if fails:
        return 1
    return 2 if warns else 0


if __name__ == "__main__":
    sys.exit(main())
