"""描述文件校验器的正反用例（不联网、不需要 Apple 账号）。

做法：用 `cryptography` 现场造一张证书和一个 CMS 包裹的 plist，
结构与 Apple 的 `.mobileprovision` 一致，于是可以验证：
  · 匹配时通过
  · bundle id 不匹配时失败
  · UDID 未登记时失败
  · p12 密码错时干净失败（不抛栈）
"""
import datetime
import os
import plistlib
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "check-provisioning.py")


@pytest.fixture(scope="module")
def creds(tmp_path_factory):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.serialization import pkcs7, pkcs12
    from cryptography.x509.oid import NameOID

    d = tmp_path_factory.mktemp("creds")
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Apple Distribution: Test (TEAM123456)")])
    now = datetime.datetime.now(datetime.UTC)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=200))
            .sign(key, hashes.SHA256()))
    p12 = d / "dist.p12"
    p12.write_bytes(pkcs12.serialize_key_and_certificates(
        b"t", key, cert, None, serialization.BestAvailableEncryption(b"testpass")))

    profile = {
        "Name": "Test AdHoc",
        "TeamIdentifier": ["TEAM123456"],
        "ApplicationIdentifierPrefix": ["TEAM123456"],
        "Platform": ["iOS"],
        "ExpirationDate": now + datetime.timedelta(days=200),
        "ProvisionedDevices": ["00008030-001A2C3E0E91802E"],
        "DeveloperCertificates": [cert.public_bytes(serialization.Encoding.DER)],
        "Entitlements": {
            "application-identifier": "TEAM123456.com.example.app",
            "get-task-allow": True,
        },
    }
    body = plistlib.dumps(profile)
    signed = (pkcs7.PKCS7SignatureBuilder().set_data(body)
              .add_signer(cert, key, hashes.SHA256())
              .sign(serialization.Encoding.DER, [pkcs7.PKCS7Options.Binary]))
    mob = d / "test.mobileprovision"
    mob.write_bytes(signed)
    return {"p12": str(p12), "profile": str(mob)}


def run(*args):
    return subprocess.run([sys.executable, TOOL, *args],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding="utf-8")


def test_profile_matches(creds):
    r = run("--profile", creds["profile"], "--bundle-id", "com.example.app",
            "--p12", creds["p12"], "--p12-password", "testpass",
            "--udid", "00008030-001A2C3E0E91802E")
    assert r.returncode == 0, r.stdout
    assert "证书匹配描述文件" in r.stdout


def test_profile_bundle_mismatch(creds):
    r = run("--profile", creds["profile"], "--bundle-id", "com.other.app")
    assert r.returncode == 1
    assert "但 bundle id 是" in r.stdout


def test_profile_udid_missing(creds):
    r = run("--profile", creds["profile"], "--udid", "DEADBEEF-0000")
    assert r.returncode == 1
    assert "UDID 不在描述文件里" in r.stdout


def test_profile_bad_password(creds):
    r = run("--profile", creds["profile"], "--p12", creds["p12"], "--p12-password", "wrong")
    assert r.returncode == 1
    assert "读不出 p12" in r.stdout
    assert "Traceback" not in r.stdout


def test_emit_entitlements(creds, tmp_path):
    out = tmp_path / "ent.plist"
    r = run("--profile", creds["profile"], "--emit-entitlements", str(out))
    assert r.returncode in (0, 2)
    ents = plistlib.loads(out.read_bytes())
    assert ents["application-identifier"] == "TEAM123456.com.example.app"
