#!/bin/bash
# Assembles MulticastView.app from a release build.
#
# The app is unsigned and un-notarised by design: it is a local tool, it is not
# sandboxed (raw packet capture is impossible in a sandbox), and it has no
# privileged helper (shipping one needs a paid Developer ID). Capture privilege
# comes from Wireshark's ChmodBPF helper instead.
#
#   ./Scripts/make-app.sh              build and assemble into ./dist
#   ./Scripts/make-app.sh --open       ...and launch it
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
APP="$DIST/MulticastView.app"
VERSION="1.0"

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

# ---- build ----------------------------------------------------------------
BINARY=""
if swift build -c release --product MulticastView 2>/dev/null; then
    say "built with SwiftPM"
    BINARY="$(swift build -c release --product MulticastView --show-bin-path)/MulticastView"
else
    say "SwiftPM could not run; falling back to Scripts/build-without-swiftpm.sh"
    say "(see the comment at the top of that script for why)"
    "$ROOT/Scripts/build-without-swiftpm.sh" release
    BINARY="$ROOT/.build-manual/release/MulticastView"
fi

if [ ! -x "$BINARY" ]; then
    echo "error: no executable at $BINARY" >&2
    exit 1
fi

# ---- assemble -------------------------------------------------------------
say "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/MulticastView"

# Icon, built from Scripts/make-icon.sh rather than checked in as a binary.
ICON_LINE=""
if "$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
    ICON_LINE="    <key>CFBundleIconFile</key>               <string>AppIcon</string>"
    say "icon built"
else
    say "icon could not be built; continuing without one"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>       <string>en</string>
    <key>CFBundleExecutable</key>              <string>MulticastView</string>
    <key>CFBundleIdentifier</key>              <string>local.multicastview</string>
    <key>CFBundleInfoDictionaryVersion</key>   <string>6.0</string>
    <key>CFBundleName</key>                    <string>MulticastView</string>
    <key>CFBundleDisplayName</key>             <string>MulticastView</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
$ICON_LINE
    <key>CFBundleShortVersionString</key>      <string>$VERSION</string>
    <key>CFBundleVersion</key>                 <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>          <string>13.0</string>
    <key>LSApplicationCategoryType</key>       <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>         <true/>
    <key>NSPrincipalClass</key>                <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>        <string>Local build. Unsigned.</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/PkgInfo" <<'PKG'
APPL????
PKG

# An ad-hoc signature is not a Developer ID -- it just stops macOS complaining
# about a bundle whose contents changed since it was last opened.
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
    say "ad-hoc signed"
else
    say "ad-hoc signing unavailable; the app will still run"
fi

say "done -> $APP"
echo
echo "First run: Gatekeeper will refuse an unsigned app opened by double-click."
echo "Right-click the app and choose Open, or run:"
echo "    xattr -dr com.apple.quarantine \"$APP\""
echo
echo "Packet capture needs access to /dev/bpf*. If MulticastView says it cannot"
echo "open a capture device, install Wireshark's ChmodBPF helper and log out and"
echo "back in. The app explains this in its own words when it happens."

if [ "${1:-}" = "--open" ]; then
    open "$APP"
fi
