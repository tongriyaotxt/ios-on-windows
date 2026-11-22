#!/usr/bin/env python3
"""本地 App Store Connect mock —— 只为了在 Windows 上离线验证 asc-upload.ps1。

它实现上传流程用到的 5 个端点，并做三件较真的事：
  1. 校验 Authorization 里的 JWT 结构（ES256 / 3 段 / 64 字节签名 / aud / exp）；
  2. 校验分片 offset+length 是否严丝合缝地覆盖整个文件；
  3. 重组分片后对比 sha256，确认一个字节都没错。
用法： python tools/mock-asc-server.py --port 8787 --ipa build/test.ipa
"""
import argparse
import base64
import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE = {
    "expected_size": 0,
    "expected_sha": None,
    "chunks": {},          # offset -> bytes
    "uploaded": False,
    "build_version": None,
    "chunk_size": 0,
    "jwt_checked": 0,
    "errors": [],
}


def b64url_decode(seg: str) -> bytes:
    pad = "=" * (-len(seg) % 4)
    return base64.urlsafe_b64decode(seg + pad)


def check_jwt(auth_header: str):
    if not auth_header or not auth_header.startswith("Bearer "):
        raise ValueError("missing bearer token")
    token = auth_header.split(" ", 1)[1]
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError(f"jwt must have 3 segments, got {len(parts)}")
    header = json.loads(b64url_decode(parts[0]))
    payload = json.loads(b64url_decode(parts[1]))
    sig = b64url_decode(parts[2])
    if header.get("alg") != "ES256":
        raise ValueError(f"alg must be ES256, got {header.get('alg')}")
    if not header.get("kid"):
        raise ValueError("kid missing")
    if payload.get("aud") != "appstoreconnect-v1":
        raise ValueError("aud mismatch")
    if len(sig) != 64:
        raise ValueError(f"ES256 signature must be 64 bytes, got {len(sig)}")
    if payload.get("exp", 0) - payload.get("iat", 0) > 1200:
        raise ValueError("token lifetime above 20 minutes")
    STATE["jwt_checked"] += 1
    return payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # 安静点，结果自己打印

    def _send(self, code: int, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            check_jwt(self.headers.get("Authorization", ""))
        except ValueError as e:
            STATE["errors"].append(str(e))
            return self._send(401, {"errors": [{"title": "unauthorized", "detail": str(e)}]})

        body = json.loads(self._read_body() or b"{}")
        if path == "/v1/buildUploads":
            attrs = body["data"]["attributes"]
            STATE["build_version"] = attrs.get("bundleVersion")
            return self._send(201, {"data": {
                "type": "buildUploads", "id": "bu-mock-1",
                "attributes": {"bundleVersion": attrs.get("bundleVersion"),
                               "platform": attrs.get("platform"),
                               "state": "AWAITING_UPLOAD"}}})

        if path == "/v1/buildUploadFiles":
            attrs = body["data"]["attributes"]
            size = int(attrs["fileSize"])
            name = attrs["fileName"]
            STATE["expected_size"] = size
            chunk = max(1024 * 1024, (size + 3) // 4)     # 4 片
            STATE["chunk_size"] = chunk
            ops = []
            off = 0
            i = 0
            while off < size:
                ln = min(chunk, size - off)
                ops.append({
                    "method": "PUT",
                    "url": f"http://127.0.0.1:{PORT}/upload/{i}?offset={off}&len={ln}",
                    "length": ln,
                    "offset": off,
                    "requestHeaders": [
                        {"name": "Content-Type", "value": "application/octet-stream"},
                        {"name": "x-apple-mock", "value": f"chunk-{i}"},
                    ],
                })
                off += ln
                i += 1
            return self._send(201, {"data": {
                "type": "buildUploadFiles", "id": "buf-mock-1",
                "attributes": {"fileName": name, "fileSize": size, "assetType": "BUILD",
                               "uploadOperations": ops}}})

        return self._send(404, {"errors": [{"title": "not found", "detail": path}]})

    def do_PUT(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/upload/"):
            return self._send(404, {})
        q = parse_qs(parsed.query)
        offset = int(q["offset"][0])
        length = int(q["len"][0])
        data = self._read_body()
        if len(data) != length:
            STATE["errors"].append(f"chunk at {offset}: declared {length}, received {len(data)}")
            return self._send(400, {"detail": "length mismatch"})
        if self.headers.get("x-apple-mock") is None:
            STATE["errors"].append(f"chunk at {offset}: missing x-apple-mock header")
            return self._send(400, {"detail": "missing header"})
        STATE["chunks"][offset] = data
        return self._send(200, {"ok": True})

    def do_PATCH(self):
        path = urlparse(self.path).path
        try:
            check_jwt(self.headers.get("Authorization", ""))
        except ValueError as e:
            return self._send(401, {"errors": [{"title": "unauthorized", "detail": str(e)}]})
        self._read_body()
        if not path.startswith("/v1/buildUploads/"):
            return self._send(404, {})

        ordered = [STATE["chunks"][o] for o in sorted(STATE["chunks"])]
        blob = b"".join(ordered)
        if len(blob) != STATE["expected_size"]:
            STATE["errors"].append(f"reassembled {len(blob)} bytes, expected {STATE['expected_size']}")
        if STATE["expected_sha"] and hashlib.sha256(blob).hexdigest() != STATE["expected_sha"]:
            STATE["errors"].append("reassembled sha256 mismatch")
        STATE["uploaded"] = True
        return self._send(200, {"data": {
            "type": "buildUploads", "id": "bu-mock-1",
            "attributes": {"bundleVersion": STATE["build_version"], "platform": "IOS",
                           "state": "COMPLETE" if not STATE["errors"] else "FAILED"}}})

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/v1/builds":
            return self._send(200, {"data": [{
                "type": "builds", "id": "build-mock-1",
                "attributes": {"version": STATE["build_version"],
                               "processingState": "VALID" if STATE["uploaded"] else "PROCESSING"}}]})
        return self._send(404, {})


def main():
    global PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--ipa", required=True, help="用来对比重组结果的原始文件")
    args = ap.parse_args()
    PORT = args.port

    data = open(args.ipa, "rb").read()
    STATE["expected_size"] = len(data)
    STATE["expected_sha"] = hashlib.sha256(data).hexdigest()

    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock ASC listening on http://127.0.0.1:{PORT}  (expecting {len(data)} bytes)")
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        while True:
            line = input()
            if line.strip() == "quit":
                break
    except (EOFError, KeyboardInterrupt):
        pass
    finally:
        srv.shutdown()
        print(json.dumps({
            "jwt_checks": STATE["jwt_checked"],
            "chunks": len(STATE["chunks"]),
            "uploaded": STATE["uploaded"],
            "errors": STATE["errors"],
        }, indent=2))


if __name__ == "__main__":
    main()
