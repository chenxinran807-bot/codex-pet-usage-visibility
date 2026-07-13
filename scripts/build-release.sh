#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Codex Pet Quota.app"
CONTENTS="$APP/Contents"
BUILD_PATH="${SWIFT_BUILD_PATH:-$ROOT/.build}"
ARCH_ARGS=(--arch arm64 --arch x86_64)

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_PATH/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$BUILD_PATH/module-cache}"

cd "$ROOT"
swift build -c release --disable-sandbox --build-path "$BUILD_PATH" "${ARCH_ARGS[@]}"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_PATH/apple/Products/Release/QuotaOverlayApp" "$CONTENTS/MacOS/QuotaOverlayApp"
cp -R "$ROOT/PetAssets" "$CONTENTS/Resources/PetAssets"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>QuotaOverlayApp</string>
  <key>CFBundleIdentifier</key><string>com.chenxinran.codexpetquota</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Codex Pet Quota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

plutil -lint "$CONTENTS/Info.plist" >/dev/null
lipo "$CONTENTS/MacOS/QuotaOverlayApp" -verify_arch arm64 x86_64
echo "Built: $APP"
