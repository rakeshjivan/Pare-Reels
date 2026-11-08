#!/bin/bash
# Builds Pare Reels.app and copies it into /Applications.
# Run from Terminal:  bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Pare Reels.app"
ARCH="$(uname -m)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed. An installer window will open."
  xcode-select --install || true
  echo "When it finishes, run:  bash build.sh  again."
  exit 1
fi

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "Building Pare Reels (Apple Silicon + Intel)…"
  for A in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -swift-version 5 \
      -target "${A}-apple-macos13.0" Sources/*.swift -o "build/PareReels-$A"
  done
  lipo -create build/PareReels-arm64 build/PareReels-x86_64 -output "$APP/Contents/MacOS/PareReels"
else
  echo "Building Pare Reels for $ARCH…"
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -target "${ARCH}-apple-macos13.0" Sources/*.swift -o "$APP/Contents/MacOS/PareReels"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pare Reels</string>
  <key>CFBundleDisplayName</key><string>Pare Reels</string>
  <key>CFBundleIdentifier</key><string>au.jivan.parereels</string>
  <key>CFBundleExecutable</key><string>PareReels</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null
rm -rf build

# On GitHub's build machines, stop here (the workflow zips the app).
if [ -n "${CI:-}" ]; then echo "Built $APP"; exit 0; fi

if ditto "$APP" "/Applications/$APP" 2>/dev/null; then
  echo "Installed to /Applications/Pare Reels.app"
  open "/Applications/$APP"
else
  echo "Built $(pwd)/$APP (couldn't copy to /Applications — drag it there yourself)."
  open "$APP"
fi
