// swift-tools-version: 5.9
import PackageDescription

// XalanCore.xcframework bundles the C++ shim merged with the static Xalan-C /
// Xerces-C archives, plus the public C header (cxalan.h).  It is committed into
// the repository, so the package is fully self-contained — no external paths and
// nothing to build beyond `swift build`.  Regenerate it with
// `scripts/build-xcframework.sh` after changing the shim or dependencies.
let package = Package(
    name: "Xalan",
    platforms: [.macOS(.v11), .iOS(.v13)],
    products: [
        .library(name: "Xalan", targets: ["Xalan"]),
    ],
    targets: [
        // Prebuilt: the merged static library + cxalan.h module.
        // XalanCore.xcframework ships macOS, iOS device, and iOS simulator
        // slices (all arm64); iPadOS uses the iOS slices.
        .binaryTarget(
            name: "CXalan",
            path: "XalanCore.xcframework"
        ),
        // Idiomatic Swift API.  The static archive only needs the C++ runtime;
        // the libc "iconv" transcoder used in the build avoids any platform
        // framework dependency (works identically on macOS and iOS).
        .target(
            name: "Xalan",
            dependencies: ["CXalan"],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        // Small demo CLI: `swift run xalan-demo`.
        .executableTarget(
            name: "xalan-demo",
            dependencies: ["Xalan"]
        ),
        .testTarget(
            name: "XalanTests",
            dependencies: ["Xalan"]
        ),
    ]
)
