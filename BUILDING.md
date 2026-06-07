# Building Xalan-C + Xerces-C from source (for XalanSwift)

This is the guide I wish I'd had. It explains how the bundled
`XalanCore.xcframework` is produced from the Apache C++ sources — for **macOS,
iOS, and iPadOS** — and, more importantly, **every trap** along the way and how
to get around it.

There are two paths:

- **Just rebuild it** → run [`scripts/build-xcframework.sh`](scripts/build-xcframework.sh). It does everything below. Skip to [§7](#7-the-one-command-path).
- **Understand / do it by hand** → read on.

---

## 0. TL;DR of the gotchas

If you only remember five things:

| # | Trap | Fix |
|---|------|-----|
| 1 | Xerces-C **4.0** (the default `git clone`) breaks Xalan 1.12 (`XMLCh` became `char16_t`, APIs removed). | Use Xerces-C **3.2.x** (`git checkout v3.2.5`). |
| 2 | Xalan's `cmake_minimum_required` is older than modern CMake allows. | `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`. |
| 3 | macOS default transcoder (`macosunicodeconverter`) uses **CoreServices**, which **doesn't exist on iOS**. | `-Dtranscoder=iconv` (pure libc, works everywhere). |
| 4 | Xalan runs a build tool (`MsgCreator`) **during** the build — an iOS binary can't run on the macOS host. | Import a **host-built** MsgCreator when cross-compiling (small CMake patch). |
| 5 | iOS treats every executable as an app bundle → Xerces/Xalan CLI/sample/test targets **fail at configure** (`install TARGETS given no BUNDLE DESTINATION`). | Gate those subdirectories behind options and turn them **off** (small CMake patch). |

Two more that bite specifically when cross-compiling:

- The macOS Xerces static lib needs **CoreServices + CoreFoundation** frameworks at link time *if* you keep the macOS transcoder — another reason to use `iconv`.
- Xerces' **build-tree** `XercesCConfig.cmake` is **not** self-sufficient (it `include()`s an `XercesCConfigInternal.cmake` that only exists after `install`). So either `install` Xerces, or hand-write a tiny config (we do the latter to avoid building Xerces' 16 CLI tools).

---

## 1. Prerequisites

- macOS on **Apple Silicon** (the bundled slices are all `arm64`).
- **Xcode** (for the iOS SDKs and `xcodebuild -create-xcframework`). Check:
  ```sh
  xcodebuild -showsdks | grep -iE 'ios|macos'   # expect macOS, iphoneos, iphonesimulator
  ```
- **CMake** ≥ 3.5 (4.x is fine with the policy flag) and a recent **Apple clang** (`xcode-select --install`).

## 2. Get the sources (correct versions)

```sh
cd /path/to/where/deps/live          # XalanSwift expects these as siblings: ../xerces-c, ../xalan-c
git clone --depth 1 --branch v3.2.5 https://github.com/apache/xerces-c.git
git clone --depth 1 https://github.com/apache/xalan-c.git     # 1.12.0
```

> ⚠️ **Do not** use the default Xerces branch — it's 4.0-dev and will not compile
> against Xalan 1.12.

## 3. The two source patches (required for iOS)

These are tiny, well-contained edits to the **cloned dependency sources**. They
are harmless for the macOS build and only change behaviour when cross-compiling.

### 3a. Xalan — import a host-built `MsgCreator` when cross-compiling

`MsgCreator` is a code-generator Xalan compiles and then **executes** during the
build to turn the localized message catalog into C++ headers. When targeting
iOS, that binary is an iOS binary and can't run on your Mac. Its output is
platform-independent, so we reuse a host build.

`xalan-c/src/xalanc/Utils/MsgCreator/CMakeLists.txt` — wrap the `add_executable`:

```cmake
if(CMAKE_CROSSCOMPILING AND HOST_MSGCREATOR)
  add_executable(MsgCreator IMPORTED GLOBAL)
  set_target_properties(MsgCreator PROPERTIES IMPORTED_LOCATION "${HOST_MSGCREATOR}")
else()
  add_executable(MsgCreator ${msgcreator_sources} ${msgcreator_headers})
  target_include_directories(MsgCreator PUBLIC
    $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/src>
    $<BUILD_INTERFACE:${PROJECT_BINARY_DIR}/src>)
  target_link_libraries(MsgCreator XercesC::XercesC)
  if(transcoder STREQUAL "icu")
    target_link_libraries(MsgCreator ICU::uc ICU::i18n)
  endif()
  set_target_properties(MsgCreator PROPERTIES FOLDER "Message Library")
endif()
```

You build macOS first (which produces a real `MsgCreator`), then pass its path
to the iOS configures via `-DHOST_MSGCREATOR=/path/to/macos/build/.../MsgCreator`.

### 3b. Xalan & Xerces — gate the executable subdirectories

iOS makes every `add_executable` a `MACOSX_BUNDLE`, and the `install(TARGETS …)`
rules for the CLI/samples/tests have no `BUNDLE DESTINATION`, so **`cmake`
configure fails** before you can build anything. None of those programs are
needed to build or use the library.

`xalan-c/CMakeLists.txt` — gate the program subdirs:

```cmake
option(XALAN_BUILD_PROGRAMS "Build Xalan command-line programs, tests and samples" ON)
# add_subdirectory(src/xalanc/Utils/...)  # (libraries — keep)
# add_subdirectory(src/xalanc)            # (library — keep)
if(XALAN_BUILD_PROGRAMS)
  add_subdirectory(src/xalanc/TestXSLT)
  add_subdirectory(src/xalanc/TestXPath)
  add_subdirectory(samples)
  add_subdirectory(Tests)
endif()
```

`xalan-c/src/xalanc/CMakeLists.txt` — also gate the `Xalan` CLI exe (it lives in
the library subdir): wrap its `add_executable(Xalan …)` + `install(TARGETS Xalan …)`
in `if(XALAN_BUILD_PROGRAMS) … endif()`.

`xerces-c/CMakeLists.txt` — gate samples/tests:

```cmake
option(XERCES_BUILD_SAMPLES "Build Xerces sample programs" ON)
option(XERCES_BUILD_TESTS "Build Xerces test programs" ON)
if(XERCES_BUILD_TESTS)
  add_subdirectory(tests)
endif()
if(XERCES_BUILD_SAMPLES)
  add_subdirectory(samples)
endif()
```

## 4. Build per platform

Do this **three times** — once per slice. Use a separate build dir for each.
`<COMMON>` below is:

```
-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
```

and the per-platform cmake flags are:

| Slice | Extra CMake flags | clang flags for the shim |
|-------|-------------------|--------------------------|
| **macOS** | `-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0` | `-isysroot $(xcrun --sdk macosx --show-sdk-path) -arch arm64 -mmacosx-version-min=11.0` |
| **iOS device** | `-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0` | `-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -miphoneos-version-min=13.0` |
| **iOS sim** | `-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0` | `-isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) -arch arm64 -mios-simulator-version-min=13.0` |

### 4a. Xerces-C (static lib only)

```sh
cmake -S ../xerces-c -B build-xerces <COMMON> <PLATFORM-FLAGS> \
      -Dnetwork=OFF -Dtranscoder=iconv \
      -DXERCES_BUILD_SAMPLES=OFF -DXERCES_BUILD_TESTS=OFF
cmake --build build-xerces --target xerces-c -j$(sysctl -n hw.ncpu)
```

- `-Dtranscoder=iconv` → the libc transcoder. **Don't** use `gnuiconv`: CMake's
  `check_function_exists(iconv)` doesn't link libiconv, so it reports gnuiconv as
  "unavailable". `iconv` uses `mblen`/`wcstombs`, which are in libc on every Apple
  platform and need no extra link library.
- `-Dnetwork=OFF` → no libcurl dependency (drops remote `document()` fetching).

Then **hand-write a package config** so Xalan can find this build *without
installing* (and without building Xerces' 16 CLI tools). In a fresh dir
`xerces-config/`:

```cmake
# xerces-config/XercesCConfig.cmake
add_library(XercesC::XercesC STATIC IMPORTED)
set_target_properties(XercesC::XercesC PROPERTIES
  IMPORTED_LOCATION "<ABS>/build-xerces/src/libxerces-c.a"
  INTERFACE_INCLUDE_DIRECTORIES "<ABS>/../xerces-c/src;<ABS>/build-xerces/src")
set(XercesC_VERSION "3.2.5")
set(XercesC_INCLUDE_DIRS "<ABS>/../xerces-c/src;<ABS>/build-xerces/src")
set(XercesC_LIBRARIES XercesC::XercesC)
set(XercesC_FOUND TRUE)
```
```cmake
# xerces-config/XercesCConfigVersion.cmake
set(PACKAGE_VERSION "3.2.5")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
```

> Why hand-write it? Xerces' own *build-tree* `XercesCConfig.cmake` `include()`s
> `XercesCConfigInternal.cmake`, which is only generated by `install`. So using
> the build tree directly fails. The alternatives are (a) `install` Xerces — but
> that builds all the CLI tools — or (b) this 12-line file. We pick (b).

### 4b. Xalan-C (static libs only)

```sh
cmake -S ../xalan-c -B build-xalan <COMMON> <PLATFORM-FLAGS> \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=TRUE \
      -DXercesC_DIR="<ABS>/xerces-config" \
      # --- cross-compile only (iOS device + sim): ---
      -DHOST_MSGCREATOR="<ABS>/build-xalan-macos/src/xalanc/Utils/MsgCreator/MsgCreator" \
      -DXALAN_BUILD_PROGRAMS=OFF \
      -DCMAKE_FIND_ROOT_PATH="<ABS>/xerces-config" \
      -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
cmake --build build-xalan --target xalan-c xalanMsg -j$(sysctl -n hw.ncpu)
```

- `-DCMAKE_FIND_PACKAGE_PREFER_CONFIG=TRUE` forces Config mode (our hand-written
  config) instead of CMake's bundled `FindXercesC` module, which would fail.
- For iOS, `CMAKE_FIND_ROOT_PATH` + `…_MODE_PACKAGE=BOTH` let `find_package` look
  **outside** the iOS sysroot (cross builds otherwise restrict the search).
- Building target `xalan-c` triggers the `MsgCreator` message-generation step
  (the library sources include the generated headers).

The two static libs land at (use `find`):
`build-xalan/.../libxalan-c.a` and `build-xalan/.../libxalanMsg.a`.

## 5. Compile the shim and merge into one archive

```sh
clang++ -c -std=c++14 -fPIC -O2 <SHIM-CLANG-FLAGS> \
  -I native/include \
  -I ../xalan-c/src -I build-xalan/src -I build-xalan/src/xalanc/PlatformSupport \
  -I ../xerces-c/src -I build-xerces/src \
  native/shim.cpp -o shim.o
ar rcs libcxalanshim.a shim.o

libtool -static -o libXalanCore.a \
  libcxalanshim.a \
  build-xalan/.../libxalan-c.a \
  build-xalan/.../libxalanMsg.a \
  build-xerces/src/libxerces-c.a
```

`libtool -static` merges the four archives into one fat static library — the
single artifact each xcframework slice carries.

## 6. Assemble the XCFramework

Stage the public header + a module map once (shared by all slices):

```sh
mkdir -p Headers
cp native/include/cxalan.h Headers/
cat > Headers/module.modulemap <<'EOF'
module CXalan {
    header "cxalan.h"
    export *
}
EOF
```

Then:

```sh
xcodebuild -create-xcframework \
  -library macos/libXalanCore.a        -headers Headers \
  -library ios/libXalanCore.a          -headers Headers \
  -library iossimulator/libXalanCore.a -headers Headers \
  -output XalanCore.xcframework
```

`xcodebuild` infers each slice's platform/variant from the Mach-O load commands,
so the device and simulator `arm64` archives don't collide.

## 7. The one-command path

All of the above is encoded in **[`scripts/build-xcframework.sh`](scripts/build-xcframework.sh)**:

```sh
./scripts/build-xcframework.sh
# overrideable: XERCES_SRC, XALAN_SRC, MACOS_MIN, IOS_MIN
```

It builds macOS first (to produce the host `MsgCreator`), then the two iOS
slices, and writes `XalanCore.xcframework`.

## 8. Verify

```sh
swift test                                            # macOS, natively
xcodebuild test -scheme Xalan-Package \
  -destination 'platform=iOS Simulator,name=iPhone 15'  # iOS simulator
```

Both should report **27 tests, 0 failures**.

## 9. Adding an x86_64 simulator slice (Intel Macs)

The bundled framework is `arm64`-only. To also support the iOS simulator on an
Intel Mac, repeat §4–§5 for the simulator with `-DCMAKE_OSX_ARCHITECTURES=x86_64`
and `-arch x86_64` (and `x86_64-apple-ios…-simulator` min flags), then `lipo
-create` the two simulator archives into one universal `arm64 + x86_64` archive
before passing it to `-create-xcframework`. (A native Intel-Mac slice is
analogous with `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` for the macOS build.)
```
