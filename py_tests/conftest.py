"""pytest 全局配置。

CI 上最容易踩的坑：windows-latest 的默认控制台编码是 cp1252，
工具里的中文 print 会抛 UnicodeEncodeError。这里统一给子进程设 UTF-8。
"""
import os
import sys

os.environ.setdefault("PYTHONIOENCODING", "utf-8")
os.environ.setdefault("PYTHONUTF8", "1")

# 本进程的 stdout 也切到 UTF-8，便于直接跑工具
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
