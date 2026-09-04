#!/bin/bash
# MacStatus 构建脚本：swiftc 直接编译 + 手工组装 .app 包（无需 Xcode 工程）
set -e
cd "$(dirname "$0")"

APP=build/MacStatus.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/menubar-icon.png "$APP/Contents/Resources/menubar-icon.png"

xcrun swiftc -O -parse-as-library \
    -target arm64-apple-macos13.0 \
    Sources/SMCKit.swift \
    Sources/SystemStats.swift \
    Sources/Monitor.swift \
    Sources/MacStatusApp.swift \
    -o "$APP/Contents/MacOS/MacStatus" \
    -module-cache-path build/module-cache

codesign --force -s - "$APP"
echo "构建完成: $APP"
