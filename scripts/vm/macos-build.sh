#!/bin/bash
# 在 macOS 客户机里跑：编译 AppCore → 导出 IPA → 起 http 服务让 Windows 拉回去。
# 前提：Xcode 已装（xcodebuild -version 能跑通）、xcodegen（brew install xcodegen）、本仓库已拷贝进客户机。
#
# 用法（客户机内）：
#   bash scripts/vm/macos-build.sh ~/src/ios-app 42
set -euo pipefail

REPO="${1:-$HOME/src/ios-app}"
BUILD_NUMBER="${2:-1}"
EXPORT_DIR="$REPO/build/vm-export"

cd "$REPO"
echo "== 环境 =="
xcodebuild -version
swift --version
which xcodegen >/dev/null || { echo "缺 xcodegen：brew install xcodegen"; exit 1; }

echo "== 生成工程 =="
cd App
xcodegen generate --spec project.yml

echo "== 单测（与 Windows 上同一份源码） =="
cd "$REPO"
swift test --parallel || echo "(单测失败不阻塞打包，但请看一眼)"

echo "== Archive =="
cd "$REPO/App"
ARCHIVE="$REPO/build/AppCore.xcarchive"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild \
  -project AppCore.xcodeproj \
  -scheme AppCore \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$(grep MARKETING_VERSION "$REPO/VERSION" | cut -d= -f2)" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive | tail -30

echo "== Export IPA =="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

ls -lh "$EXPORT_DIR"/*.ipa

echo
echo "== 起 http 服务（Windows 侧跑 Get-Artifact.ps1 拉取） =="
echo "   QEMU hostfwd 已把客户机 8000 映到 Windows 的 127.0.0.1:8000"
cd "$EXPORT_DIR"
exec python3 -m http.server 8000
