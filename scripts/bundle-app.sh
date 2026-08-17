#!/bin/bash
# 组装 DeepSeek Harness.app（SwiftUI 原生壳 + 内置 Node/pnpm/源码）并制作 DMG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${DSH_REPO:-$ROOT/../deepseek-harness}"
VENDOR="$ROOT/vendor"
OUT="${1:-$ROOT/dist}"
APP_NAME="DeepSeek Harness"
APP="$OUT/$APP_NAME.app"

echo "==> [1/6] release 编译 Swift"
cd "$ROOT"
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build -c release

echo "==> [2/6] 准备 Node 运行时"
if [ ! -x "$VENDOR/node/bin/node" ]; then
  mkdir -p "$VENDOR/node"
  tar -xJf "$VENDOR/node.tar.xz" -C "$VENDOR/node" --strip-components=1
fi
"$VENDOR/node/bin/node" --version

echo "==> [3/6] 组装 .app 骨架"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/DSHMac" "$APP/Contents/MacOS/DSHMac"
cp "$ROOT/Sources/DSHMac/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DeepSeek Harness</string>
    <key>CFBundleDisplayName</key>
    <string>DeepSeek Harness</string>
    <key>CFBundleExecutable</key>
    <string>DSHMac</string>
    <key>CFBundleIdentifier</key>
    <string>ai.deepseek.dshmac</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> [4/6] 拷贝 Node / pnpm / shim / 源码树（纯净运行时集合）"
mkdir -p "$APP/Contents/Resources/node" "$APP/Contents/Resources/pnpm"
rsync -a "$VENDOR/node/" "$APP/Contents/Resources/node/"
cp "$VENDOR/pnpm" "$APP/Contents/Resources/pnpm/pnpm"
chmod +x "$APP/Contents/Resources/pnpm/pnpm"
cp "$ROOT/resources-node/uds-shim.mjs" "$APP/Contents/Resources/uds-shim.mjs"
# 纯净打包：仅运行时必需内容（源码 + node_modules + .git 供从源更新）；
# 排除文档/示例/Python/CI 等非运行时目录与构建残留
rsync -a \
  --exclude '.build' \
  --exclude 'docs' \
  --exclude 'website' \
  --exclude 'examples' \
  --exclude 'python' \
  --exclude '.github' \
  --exclude '.agents' \
  --exclude '.claude' \
  --exclude '.vscode' \
  --exclude '.idea' \
  --exclude 'assets' \
  --exclude 'scripts' \
  --exclude '.DS_Store' \
  --exclude '*.tsbuildinfo' \
  --exclude '*.log' \
  --exclude 'BENCHMARK.md' \
  --exclude 'CONTRIBUTING*.md' \
  --exclude 'README*.md' \
  --exclude '*.i18n.yaml' \
  "$REPO/" "$APP/Contents/Resources/repo/"
(cd "$REPO" && git rev-parse HEAD) > "$APP/Contents/Resources/SOURCE_VERSION"

echo "==> [5/6] ad-hoc 签名"
codesign --force --sign - --deep "$APP"
codesign --verify "$APP"

echo "==> [6/6] 制作 DMG"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$APP" \
  -ov -format UDZO \
  "$OUT/DeepSeek-Harness-mac-arm64.dmg"

echo ""
echo "完成："
du -sh "$APP" "$OUT/DeepSeek-Harness-mac-arm64.dmg"
echo "源码版本：$(cat "$APP/Contents/Resources/SOURCE_VERSION")"
