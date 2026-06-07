// swift-tools-version: 5.9
import PackageDescription

// XalanCore.xcframework bundles the C++ shim merged with the static Xalan-C /
// Xerces-C archives, plus the public C header (cxalan.h).  It is committed into
// the repository, so the package is fully self-contained — no external paths and
// nothing to build beyond `swift build`.  Regenerate it with
// `scripts/build-xcframework.sh` after changing the shim or dependencies.
let package = Package(
    name: "Xalan",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "Xalan", targets: ["Xalan"]),
    ],
    targets: [
        // Prebuilt: the merged static library + cxalan.h module.
        .binaryTarget(
            name: "CXalan",
            path: "XalanCore.xcframework"
        ),
        // Idiomatic Swift API.  The static archive needs the C++ runtime and
        // the macOS frameworks used by Xerces' Unicode transcoder; declaring
        // them here keeps the package usable as a normal dependency.
        .target(
            name: "Xalan",
            dependencies: ["CXalan"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreFoundation"),
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
