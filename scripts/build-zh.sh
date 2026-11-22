#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="dist/Tatemoni.app"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# 构建 Apple Silicon 和 Intel 通用版本。
for binary in kururin_pa_app kururin_pa_daemon; do
  for arch in arm64 x86_64; do
    swiftc -O -target "${arch}-apple-macosx12.3" \
      -module-cache-path "$temp/cache" "$binary.swift" -o "$temp/$binary-$arch"
  done
  lipo -create "$temp/$binary-arm64" "$temp/$binary-x86_64" -output "$app/Contents/MacOS/$binary"
  lipo "$app/Contents/MacOS/$binary" -verify_arch arm64 x86_64
done

cp AppIcon.icns LICENSE "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tatemoni</string>
  <key>CFBundleDisplayName</key><string>Tatemoni</string>
  <key>CFBundleExecutable</key><string>kururin_pa_app</string>
  <key>CFBundleIdentifier</key><string>com.yama.kururin-pa</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/MacOS/kururin_pa_daemon"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" dist/Tatemoni-zh-CN.zip
