#!/bin/bash
# build.sh — compile DetroitRing, assemble a native .app bundle, ad-hoc sign, install.
# Gotchas applied:
#  - compiled arm64 Mach-O (immune to script-app Rosetta prompt)
#  - links only system frameworks, bundles no dylibs (immune to OS-upgrade dyld breakage)
#  - install to ~/Applications (NOT a sync dir) so FinderInfo rewrite can't break the signature
#  - xattr -cr then codesign --force --deep -s - (ad-hoc); spctl 'rejected' is normal for a local app
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="DetroitRing"
BUNDLE_ID="com.detroitring.app"
VERSION="1.0.0"
BUILD="build"
APP="$BUILD/$APPNAME.app"
INSTALL_DIR="$HOME/Applications"

echo "==> compiling (swiftc $(swiftc --version 2>/dev/null | head -1))"
mkdir -p "$BUILD"
swiftc -O src/Ring.swift src/AppCore.swift src/main.swift -o "$BUILD/$APPNAME"

echo "==> selftest (display logic + reducer timeline + eviction + pid-liveness + determinism oracle)"
"$BUILD/$APPNAME" --selftest || { echo "SELFTEST FAILED — aborting build"; exit 1; }

echo "==> egg-overlay determinism gate (must be closed-form in age — no Date/RNG/time API → oracle-safe)"
# The DBH easter-egg overlay views (everything after the "DBH easter-egg overlays" MARK in Ring.swift) are
# composed ABOVE the pure RingCanvas. If any of them read wall-clock/RNG, an offscreen render would diverge
# from the live frame. Static-assert they stay closed-form. (`clockwise`/`.radians` are not time APIs.)
if awk '/MARK: - DBH easter-egg overlays/{f=1} f' src/Ring.swift \
   | grep -nE 'Date\(|\.random\(|arc4random|CACurrentMediaTime|mach_absolute_time|DispatchTime\.now|systemUptime'; then
  echo "EGG OVERLAY READS A TIME/RNG SOURCE — breaks the determinism oracle — aborting build"; exit 1
else
  echo "   egg overlays closed-form (no Date/RNG): OK"
fi

echo "==> emit tests (ring_emit.py decision logic: from_prompt / attn-carry / abandon)"
python3 tools/test_emit.py || { echo "EMIT TESTS FAILED — aborting build"; exit 1; }

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$APPNAME" "$APP/Contents/MacOS/$APPNAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Detroit Ring</string>
  <key>CFBundleDisplayName</key><string>Detroit Ring</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APPNAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# bundle the app icon (also the icon the in-app notifications carry)
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing (ad-hoc)"
xattr -cr "$APP"
codesign --force --deep -s - "$APP"
codesign --verify --strict "$APP" && echo "   codesign verify: OK"

echo "==> installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APPNAME.app"
cp -R "$APP" "$INSTALL_DIR/$APPNAME.app"
# refresh LaunchServices so the (re-copied) bundle's icon isn't served stale by icon/notification caches
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APPNAME.app" 2>/dev/null || true

# install the hook emitter alongside the runtime state dir
mkdir -p "$HOME/.claude/ring/sessions"
cp src/ring_emit.py "$HOME/.claude/ring/ring-emit"
chmod +x "$HOME/.claude/ring/ring-emit"

echo "==> done. App: $INSTALL_DIR/$APPNAME.app  |  emitter: ~/.claude/ring/ring-emit"
