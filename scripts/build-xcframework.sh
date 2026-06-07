#!/usr/bin/env bash
#
# Builds XalanCore.xcframework: the C++ shim compiled and merged together with
# the static Xalan-C / Xerces-C / xalanMsg archives into a single static library,
# wrapped as an XCFramework with the public C header (cxalan.h).
#
# The resulting XalanCore.xcframework is committed into the package so that
# consumers need nothing on disk except this repository.
#
# Re-run this after changing native/shim.cpp or rebuilding the dependencies.
#
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Locations of the static dependency builds (override via env if you moved them).
XALAN_ROOT="${XALAN_ROOT:-/Users/shad/dev/3rdParty/xalan-c/_install}"
XERCES_ROOT="${XERCES_ROOT:-/Users/shad/dev/3rdParty/xerces-c/_install}"

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

BUILD="$PKG_DIR/.xcframework-build"
OUT="$PKG_DIR/XalanCore.xcframework"

echo "==> Cleaning"
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD/Headers"

echo "==> Compiling shim (arm64, macOS $DEPLOYMENT_TARGET)"
clang++ -c \
    -std=c++14 -fPIC -O2 \
    -arch arm64 \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -I "$PKG_DIR/native/include" \
    -I "$XALAN_ROOT/include" \
    -I "$XERCES_ROOT/include" \
    "$PKG_DIR/native/shim.cpp" \
    -o "$BUILD/shim.o"

echo "==> Merging static archives"
ar rcs "$BUILD/libcxalanshim.a" "$BUILD/shim.o"
libtool -static -o "$BUILD/libXalanCore.a" \
    "$BUILD/libcxalanshim.a" \
    "$XALAN_ROOT/lib/libxalan-c.a" \
    "$XALAN_ROOT/lib/libxalanMsg.a" \
    "$XERCES_ROOT/lib/libxerces-c.a"

echo "==> Staging headers + module map"
cp "$PKG_DIR/native/include/cxalan.h" "$BUILD/Headers/cxalan.h"
cat > "$BUILD/Headers/module.modulemap" <<'EOF'
module CXalan {
    header "cxalan.h"
    export *
}
EOF

echo "==> Creating XCFramework"
xcodebuild -create-xcframework \
    -library "$BUILD/libXalanCore.a" \
    -headers "$BUILD/Headers" \
    -output "$OUT"

echo "==> Done: $OUT"
lipo -info "$OUT"/*/libXalanCore.a 2>/dev/null || true
