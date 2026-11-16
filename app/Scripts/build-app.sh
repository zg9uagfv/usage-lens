#!/bin/bash
# 把 SwiftPM 产物装进一个真正的 .app（菜单栏 App 需要 bundle 才能稳定常驻）。
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
# 在某些受限/沙箱环境里 SwiftPM 自带的 manifest 沙箱会被拒绝，可用
# SWIFT_BUILD_FLAGS=--disable-sandbox 追加参数。正常机器上不需要设置。
EXTRA_FLAGS="${SWIFT_BUILD_FLAGS:-}"
cd "$APP_DIR"

# shellcheck disable=SC2086
swift build -c "$CONFIG" --product UsageLens $EXTRA_FLAGS

# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path $EXTRA_FLAGS)"
OUT="$APP_DIR/dist/UsageLens.app"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/probes"
cp "$BIN_DIR/UsageLens" "$OUT/Contents/MacOS/UsageLens"
cp "$APP_DIR/Resources/Info.plist" "$OUT/Contents/Info.plist"
cp "$APP_DIR"/../probes/*.py "$OUT/Contents/Resources/probes/"

# ad-hoc 签名：本机自用足够，避免 Gatekeeper 对未签名 bundle 的打扰。
/usr/bin/codesign --force --sign - "$OUT" >/dev/null 2>&1 || true

echo "$OUT"
