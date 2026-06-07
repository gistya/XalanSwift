#!/usr/bin/env bash
#
# Builds XalanCore.xcframework for macOS, iOS device, and iOS simulator
# (iPadOS uses the iOS slices).  For each platform it:
#
#   1. builds Xerces-C 3.2.5 as a static lib (libc iconv transcoder, no network)
#   2. builds Xalan-C 1.12.0 static libs against that Xerces (build tree, no install)
#   3. compiles the C++ shim (native/shim.cpp)
#   4. merges shim + xalan + xalanMsg + xerces into one static archive
#
# then assembles all slices into XalanCore.xcframework with the public header.
#
# The libc "iconv" transcoder (mblen/wcstombs, no extra link library) is used on
# every platform so there is no CoreServices dependency — that macOS-only Carbon
# API does not exist on iOS, which is why the macOS default cannot be reused.
# Cross-compiling to
# iOS reuses a host-built MsgCreator (see the CMAKE_CROSSCOMPILING branch in
# xalan-c/src/xalanc/Utils/MsgCreator/CMakeLists.txt).
#
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

XERCES_SRC="${XERCES_SRC:-/Users/shad/dev/3rdParty/xerces-c}"
XALAN_SRC="${XALAN_SRC:-/Users/shad/dev/3rdParty/xalan-c}"

MACOS_MIN="${MACOS_MIN:-11.0}"
IOS_MIN="${IOS_MIN:-13.0}"

WORK="$PKG_DIR/.xcframework-build"
OUT="$PKG_DIR/XalanCore.xcframework"
JOBS="$(sysctl -n hw.ncpu)"

NCOMMON=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
         -DCMAKE_POSITION_INDEPENDENT_CODE=ON)

HOST_MSGCREATOR=""   # filled in by the macOS build, reused when cross-compiling

echo "==> Cleaning"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/Headers"

# Shared public header + module map for every slice.
cp "$PKG_DIR/native/include/cxalan.h" "$WORK/Headers/cxalan.h"
cat > "$WORK/Headers/module.modulemap" <<'EOF'
module CXalan {
    header "cxalan.h"
    export *
}
EOF

# build_platform <name> <sdk> <min-flag> <extra-cmake...>
build_platform() {
    local name="$1"; shift
    local sdk="$1"; shift
    local minflag="$1"; shift
    local -a cmake_extra=("$@")

    local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local pdir="$WORK/$name"
    local xerces_build="$pdir/xerces"
    local xalan_build="$pdir/xalan"
    mkdir -p "$pdir"

    echo
    echo "############################################################"
    echo "## Platform: $name  (sdk=$sdk)"
    echo "############################################################"

    echo "==> [$name] Xerces-C (static, iconv transcoder)"
    cmake -S "$XERCES_SRC" -B "$xerces_build" -G "Unix Makefiles" \
        "${NCOMMON[@]}" "${cmake_extra[@]}" \
        -Dnetwork=OFF -Dtranscoder=iconv \
        -DXERCES_BUILD_SAMPLES=OFF -DXERCES_BUILD_TESTS=OFF >/dev/null
    cmake --build "$xerces_build" --target xerces-c -j"$JOBS" >/dev/null

    # Hand-written package config pointing at the build-tree lib + headers, so
    # Xalan's find_package(XercesC) works without a full `install` (which would
    # build all of Xerces' command-line tools — unnecessary for us).
    local xerces_cfg="$pdir/xerces-config"
    mkdir -p "$xerces_cfg"
    cat > "$xerces_cfg/XercesCConfig.cmake" <<EOF
add_library(XercesC::XercesC STATIC IMPORTED)
set_target_properties(XercesC::XercesC PROPERTIES
  IMPORTED_LOCATION "$xerces_build/src/libxerces-c.a"
  INTERFACE_INCLUDE_DIRECTORIES "$XERCES_SRC/src;$xerces_build/src")
set(XercesC_VERSION "3.2.5")
set(XercesC_INCLUDE_DIRS "$XERCES_SRC/src;$xerces_build/src")
set(XercesC_LIBRARIES XercesC::XercesC)
set(XercesC_FOUND TRUE)
EOF
    cat > "$xerces_cfg/XercesCConfigVersion.cmake" <<'EOF'
set(PACKAGE_VERSION "3.2.5")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOF

    echo "==> [$name] Xalan-C (static libs)"
    local -a xalan_args=(
        "${NCOMMON[@]}" "${cmake_extra[@]}"
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        # Use our hand-written Xerces package config rather than CMake's bundled
        # FindXercesC module.
        -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=TRUE
        -DXercesC_DIR="$xerces_cfg"
    )
    if [[ -n "$HOST_MSGCREATOR" ]]; then
        # Cross-compiling: import the host MsgCreator and skip executable
        # subdirectories (they fail to configure as iOS app bundles).
        xalan_args+=(
            -DHOST_MSGCREATOR="$HOST_MSGCREATOR"
            -DXALAN_BUILD_PROGRAMS=OFF
            -DCMAKE_FIND_ROOT_PATH="$xerces_cfg"
            -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
        )
    fi
    cmake -S "$XALAN_SRC" -B "$xalan_build" -G "Unix Makefiles" "${xalan_args[@]}" >/dev/null
    cmake --build "$xalan_build" --target xalan-c xalanMsg -j"$JOBS" >/dev/null

    # On the (native) host build, remember the freshly built MsgCreator.
    if [[ -z "$HOST_MSGCREATOR" ]]; then
        HOST_MSGCREATOR="$(find "$xalan_build" -name MsgCreator -type f -perm +111 | head -1)"
        echo "==> host MsgCreator: $HOST_MSGCREATOR"
    fi

    echo "==> [$name] compiling shim"
    clang++ -c -std=c++14 -fPIC -O2 \
        -isysroot "$sysroot" -arch arm64 "$minflag" \
        -I "$PKG_DIR/native/include" \
        -I "$XALAN_SRC/src" \
        -I "$xalan_build/src" \
        -I "$xalan_build/src/xalanc/PlatformSupport" \
        -I "$XERCES_SRC/src" \
        -I "$xerces_build/src" \
        "$PKG_DIR/native/shim.cpp" -o "$pdir/shim.o"
    ar rcs "$pdir/libcxalanshim.a" "$pdir/shim.o"

    echo "==> [$name] merging archives"
    local xalan_lib xalanmsg_lib
    xalan_lib="$(find "$xalan_build" -name libxalan-c.a | head -1)"
    xalanmsg_lib="$(find "$xalan_build" -name libxalanMsg.a | head -1)"
    libtool -static -o "$pdir/libXalanCore.a" \
        "$pdir/libcxalanshim.a" \
        "$xalan_lib" \
        "$xalanmsg_lib" \
        "$xerces_build/src/libxerces-c.a" 2>/dev/null
    lipo -info "$pdir/libXalanCore.a"
}

# macOS first so it produces the host MsgCreator reused by the iOS builds.
build_platform macos        macosx          "-mmacosx-version-min=$MACOS_MIN" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" -DCMAKE_OSX_ARCHITECTURES=arm64

build_platform ios          iphoneos        "-miphoneos-version-min=$IOS_MIN" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"

build_platform iossimulator iphonesimulator "-mios-simulator-version-min=$IOS_MIN" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"

echo
echo "==> Assembling XCFramework"
xcodebuild -create-xcframework \
    -library "$WORK/macos/libXalanCore.a"        -headers "$WORK/Headers" \
    -library "$WORK/ios/libXalanCore.a"          -headers "$WORK/Headers" \
    -library "$WORK/iossimulator/libXalanCore.a" -headers "$WORK/Headers" \
    -output "$OUT"

echo
echo "==> Done: $OUT"
find "$OUT" -name "*.a" -exec sh -c 'echo "  $1:"; lipo -info "$1" | sed "s/^/    /"' _ {} \;
