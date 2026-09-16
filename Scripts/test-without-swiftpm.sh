#!/bin/bash
# Runs the MulticastCore test suite without SwiftPM. See the comment at the top
# of build-without-swiftpm.sh for why that is necessary here.
#
# The test files are ordinary XCTest. This script compiles Scripts/xctest-shim
# as a module literally named XCTest so their `import XCTest` resolves, then
# generates a main.swift that calls each test method. `swift test` on a machine
# with a full toolchain runs the very same files against real XCTest.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/.build-manual/tests"
SDK="${MCV_SDK:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk 2>/dev/null || xcrun --show-sdk-path)}"
TARGET="$(uname -m)-apple-macosx13.0"
SWIFTC=(swiftc -target "$TARGET" -sdk "$SDK" -Onone -whole-module-optimization -swift-version 5)
# Linking must not carry the compile flags, or swiftc treats the .o files as source.
LINK=(swiftc -target "$TARGET" -sdk "$SDK")

rm -rf "$BUILD"; mkdir -p "$BUILD"

# 1. MulticastCore
"${SWIFTC[@]}" -parse-as-library -module-name MulticastCore -emit-module \
    -emit-module-path "$BUILD/MulticastCore.swiftmodule" \
    -c $(find "$ROOT/Sources/MulticastCore" -name '*.swift') -o "$BUILD/MulticastCore.o"

# 2. The XCTest stand-in
"${SWIFTC[@]}" -parse-as-library -module-name XCTest -emit-module \
    -emit-module-path "$BUILD/XCTest.swiftmodule" \
    -c "$ROOT/Scripts/xctest-shim/XCTest.swift" -o "$BUILD/XCTest.o"

# 3. Generate a runner. Real XCTest discovers tests via the Objective-C runtime;
#    the shim has no runtime, so the list is generated from the source instead.
python3 "$ROOT/Scripts/generate-test-runner.py" "$ROOT/Tests/MulticastCoreTests" > "$BUILD/main.swift"

# 4. Compile tests + runner, then link against the modules built above.
"${SWIFTC[@]}" -module-name TestRunner -I "$BUILD" \
    -c $(find "$ROOT/Tests/MulticastCoreTests" -name '*.swift') "$BUILD/main.swift" \
    -o "$BUILD/TestRunner.o"

"${LINK[@]}" -o "$BUILD/TestRunner" \
    "$BUILD/TestRunner.o" "$BUILD/MulticastCore.o" "$BUILD/XCTest.o"

"$BUILD/TestRunner"
