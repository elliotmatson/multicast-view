#!/bin/bash
# Fallback builder for machines where SwiftPM cannot run.
#
# SwiftPM 5.8 (the version shipped with Command Line Tools alone) resolves the
# XCTest platform path eagerly at startup, and a CommandLineTools-only install
# has no Platforms/ directory to resolve it from. Every `swift build` then dies
# with "unable to lookup item 'PlatformPath'" before it compiles anything.
#
# swiftc itself is fine, so this script drives it directly, in dependency order.
# Once a full toolchain is installed (Xcode, or Swift 5.9+ from swift.org),
# plain `swift build` works and this script is redundant.
#
#   ./Scripts/build-without-swiftpm.sh          release build
#   ./Scripts/build-without-swiftpm.sh debug    debug build
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${1:-release}"
BUILD="$ROOT/.build-manual/$CONFIG"
SDK="${MCV_SDK:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk 2>/dev/null || xcrun --show-sdk-path)}"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macosx13.0"

if [ "$CONFIG" = "release" ]; then OPT=(-O -whole-module-optimization); else OPT=(-Onone -g -whole-module-optimization); fi

mkdir -p "$BUILD"
SWIFTC=(swiftc -target "$TARGET" -sdk "$SDK" "${OPT[@]}" -swift-version 5 -parse-as-library)
# Linking must not carry the compile flags, or swiftc treats the .o files as source.
LINK=(swiftc -target "$TARGET" -sdk "$SDK")

step() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

# ---- CBPF (C target) -------------------------------------------------------
step "CBPF"
clang -target "$TARGET" -isysroot "$SDK" -O2 -fPIC \
      -I "$ROOT/Sources/CBPF/include" \
      -c "$ROOT/Sources/CBPF"/*.c -o "$BUILD/CBPF.o"

# A module map so `import CBPF` resolves when driving swiftc by hand.
# SwiftPM synthesises one from Sources/CBPF/include; we write the same thing.
cat > "$BUILD/module.modulemap" <<EOF
module CBPF {
    header "$ROOT/Sources/CBPF/include/cbpf_shim.h"
    export *
}
EOF
CCFLAGS=(-Xcc -fmodule-map-file="$BUILD/module.modulemap" -Xcc -I"$ROOT/Sources/CBPF/include")

# ---- MulticastCore ---------------------------------------------------------
step "MulticastCore"
"${SWIFTC[@]}" -module-name MulticastCore -emit-module \
    -emit-module-path "$BUILD/MulticastCore.swiftmodule" \
    -c $(find "$ROOT/Sources/MulticastCore" -name '*.swift') \
    -o "$BUILD/MulticastCore.o" 2>&1

# ---- MulticastSystem -------------------------------------------------------
if [ -n "$(ls -A "$ROOT/Sources/MulticastSystem" 2>/dev/null)" ]; then
step "MulticastSystem"
"${SWIFTC[@]}" -module-name MulticastSystem -emit-module \
    -emit-module-path "$BUILD/MulticastSystem.swiftmodule" \
    -I "$BUILD" "${CCFLAGS[@]}" \
    -c $(find "$ROOT/Sources/MulticastSystem" -name '*.swift') \
    -o "$BUILD/MulticastSystem.o" 2>&1
fi

# ---- MulticastView (executable) -------------------------------------------
if [ -n "$(ls -A "$ROOT/Sources/MulticastView" 2>/dev/null)" ]; then
step "MulticastView"
"${SWIFTC[@]}" -module-name MulticastView \
    -I "$BUILD" "${CCFLAGS[@]}" \
    -c $(find "$ROOT/Sources/MulticastView" -name '*.swift') \
    -o "$BUILD/MulticastView.o" 2>&1

step "link"
"${LINK[@]}" -o "$BUILD/MulticastView" \
    "$BUILD/MulticastView.o" "$BUILD/MulticastSystem.o" "$BUILD/MulticastCore.o" "$BUILD/CBPF.o" \
    -framework AppKit -framework SwiftUI -framework Charts
fi

step "built -> $BUILD"
