#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/QuarkFast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 "$ROOT"/Sources/*.swift \
  -o "$APP/Contents/MacOS/QuarkFast" \
  -framework SwiftUI -framework AppKit \
  -target arm64-apple-macosx13.0
cp "$ROOT/Resources/quark_dl.py" "$APP/Contents/Resources/quark_dl.py"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f "$ROOT/AppIcon.icns" ] && cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ $APP"
