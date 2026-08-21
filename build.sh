#!/bin/bash
#
# Builds Glitter.app from main.swift.
#
#   chmod +x build.sh
#   ./build.sh
#   open Glitter.app
#
# Requires the Xcode command line tools. If swiftc is missing, run:
#   xcode-select --install
#

set -euo pipefail

APP="Glitter.app"
BIN="Glitter"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Run: xcode-select --install"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Glitter</string>
  <key>CFBundleDisplayName</key>     <string>Glitter</string>
  <key>CFBundleExecutable</key>      <string>Glitter</string>
  <key>CFBundleIdentifier</key>      <string>local.glitter.cursor</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>12.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "Compiling (universal binary: arm64 + x86_64)..."
# Built for both architectures explicitly, not just whatever machine runs
# this script -- otherwise the binary only runs on the same CPU family it
# was compiled on (e.g. a build made on an Apple Silicon CI runner won't
# open at all on an Intel Mac, and vice versa: "not supported on this Mac").
swiftc -O -target arm64-apple-macosx12.0 main.swift -o "$APP/Contents/MacOS/${BIN}-arm64"
swiftc -O -target x86_64-apple-macosx12.0 main.swift -o "$APP/Contents/MacOS/${BIN}-x86_64"
lipo -create -output "$APP/Contents/MacOS/$BIN" \
  "$APP/Contents/MacOS/${BIN}-arm64" "$APP/Contents/MacOS/${BIN}-x86_64"
rm "$APP/Contents/MacOS/${BIN}-arm64" "$APP/Contents/MacOS/${BIN}-x86_64"

# Ad-hoc signature keeps macOS from complaining about an unsigned binary.
# (No --deep: there's nothing nested in this bundle to sign recursively.)
codesign --force --sign - "$APP" 2>/dev/null || true

echo
echo "Built ./$APP"
echo "Run it with:  open $APP"
echo "Quit it from the menu bar: ✨ → Quit Glitter"
