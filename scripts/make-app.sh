#!/bin/bash
# 构建 release 二进制并组装 Stats.app（含图标、Info.plist、ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f build/AppIcon.icns ]; then
    echo "==> 生成 App 图标"
    swift scripts/make-icon.swift
    iconutil -c icns build/icon.iconset -o build/AppIcon.icns
fi

echo "==> swift build -c release"
swift build -c release

APP="build/Stats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Stats "$APP/Contents/MacOS/Stats"

if [ -f build/AppIcon.icns ]; then
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Stats</string>
    <key>CFBundleDisplayName</key><string>Stats</string>
    <key>CFBundleIdentifier</key><string>com.hhq.stats</string>
    <key>CFBundleExecutable</key><string>Stats</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "==> 完成: $APP"
