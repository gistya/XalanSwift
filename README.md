# XalanSwift

A Swift wrapper around [Apache Xalan-C++](https://xalan.apache.org/xalan-c/),
the XSLT 1.0 / XPath 1.0 processor. It gives you idiomatic, memory-safe Swift
types for transforming XML with stylesheets and for running XPath queries,
backed by the battle-tested Xalan/Xerces C++ engines.

Runs on **macOS, iOS and iPadOS** (Apple Silicon). The full test suite passes
both natively on macOS and on the iOS Simulator.

```swift
import Xalan

let html = try XSLTProcessor().transform(xml: xmlString, stylesheet: xslString)

let doc = try XalanDocument(xml: xmlString)
let count = try doc.number("count(//book)")
let titles = try doc.nodes("//book/title").map(\.value)
```

## How it's put together

```
XalanSwift/                 ← this package — fully self-contained
 ├─ XalanCore.xcframework/  ← ✅ committed: merged static lib + cxalan.h module
 ├─ Sources/
 │   ├─ Xalan/             ← idiomatic Swift API (XSLTProcessor, XalanDocument, …)
 │   └─ xalan-demo/        ← `swift run xalan-demo`
 ├─ native/                ← C++ shim source (shim.cpp + cxalan.h), built into the .xcframework
 ├─ scripts/build-xcframework.sh
 └─ Tests/XalanTests/
```

Three layers:

1. **Xerces-C 3.2.5** and **Xalan-C 1.12.0** are built **from source** as
   **static** libraries (no Homebrew / system dylib dependency).
2. A small C++ shim (`native/shim.cpp`) wraps the Xalan C++ classes behind a
   pure-C header (`native/include/cxalan.h`). All C++ exceptions are trapped at
   the boundary; UTF‑8 ⇄ UTF‑16 conversion is handled here.
3. The shim object is **merged together with** the three static archives into a
   single `libXalanCore.a` per platform, wrapped as **`XalanCore.xcframework`**
   (slices: `macos-arm64`, `ios-arm64`, `ios-arm64-simulator`) and committed into
   the repo as a SwiftPM `binaryTarget`. `Xalan` is the Swift module you `import`.

Because the merged archive is vendored, the package needs **nothing on disk
beyond this directory** — no external paths, no separate dependency build. The
only runtime dependency is the C++ runtime, declared in `Package.swift`. Xerces
is built with the libc **`iconv`** transcoder (not the macOS CoreServices one),
so the exact same code works on iOS, where CoreServices does not exist.

> Architecture: the framework is **arm64** across all slices (Apple Silicon Macs,
> iOS/iPadOS devices, and the simulator on Apple Silicon). It does **not** include
> an `x86_64` simulator slice, so it won't link for an Intel-Mac iOS simulator. To
> add that, build the deps + shim for `iphonesimulator`/`x86_64` and pass an extra
> `-library` to `xcodebuild -create-xcframework` (see `scripts/build-xcframework.sh`).

## Building / using

The package is ready to use as-is:

```sh
swift build
swift test
swift run xalan-demo
```

Add it as a dependency like any other local SwiftPM package
(`.package(path: "…/XalanSwift")`).

To build/run for iOS, use `xcodebuild` with an iOS destination, e.g.:

```sh
# Run the test suite on a simulator
xcodebuild test -scheme Xalan-Package -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Regenerating the bundled framework

Only needed if you change `native/shim.cpp` or want to rebuild the engines:

```sh
./scripts/build-xcframework.sh
```

The script is self-contained: for **each** platform (macOS, iOS device, iOS
simulator) it builds Xerces-C 3.2.5 and Xalan-C 1.12.0 as static libs straight
from their source trees, compiles the shim, merges everything, and assembles
`XalanCore.xcframework`. It reads the dependency **sources** from `$XERCES_SRC`
/ `$XALAN_SRC` (defaulting to `../xerces-c` and `../xalan-c`) — no separate
dependency build or install step is required.

Two small, documented patches are applied to the cloned dependency sources to
support iOS cross-compilation (importing a host-built `MsgCreator`, and gating
the command-line/sample/test executables that can't configure as iOS app
bundles).

📖 **Rebuilding from scratch?** [`BUILDING.md`](BUILDING.md) is a full step-by-step
guide to compiling Xerces-C + Xalan-C from source for macOS/iOS/iPadOS, with every
gotcha (transcoder choice, `MsgCreator`, iOS app-bundle configure errors, the
Xerces package-config trap) explained and worked around.

## API overview

### Transforming XML (`XSLTProcessor`)

```swift
let p = try XSLTProcessor()

// One-shot, strings or Data or files:
let out  = try p.transform(xml: xmlString, stylesheet: xslString)
let data = try p.transform(xml: xmlData,   stylesheet: xslData)   // raw bytes
try p.transformFile(xml: "in.xml", stylesheet: "s.xsl", output: "out.html")
let s = try p.transformFile(xml: "in.xml", stylesheet: "s.xsl")    // to string
let r = try p.transformUsingEmbeddedStylesheet(xml: xmlString)     // <?xml-stylesheet?>

// Top-level xsl:param values:
p.setParameter("name",  string: "World")          // literal string (any quotes OK)
p.setParameter("scale", number: 2.5)              // number
p.setParameter("nodes", xpath:  "//item[@on]")    // raw XPath expression
p.clearParameters()

// Output / processing options:
p.setValidation(true)
p.setIndent(2)
p.setOutputEncoding("UTF-8")

// Compile once, run many (fast for repeated transforms):
let css = try p.compileStylesheet(xslString)       // or contentsOfFile:
let src = try p.parse(xml: xmlString)              // or contentsOfFile:
let result = try p.transform(src, with: css)
try p.transform(src, with: css, toFile: "out.xml")
```

`CompiledStylesheet` and `ParsedSource` are owned by the processor and keep it
alive automatically; just let them go out of scope to free them.

### Querying XML (`XalanDocument`)

```swift
let doc = try XalanDocument(xml: xmlString)        // or contentsOfFile:

// Typed result with all coercions:
let result = try doc.evaluate("//book[@id='2']/price")
result.kind      // .nodeSet / .number / .string / .boolean / …
result.string    // string value
result.number    // numeric coercion
result.boolean   // boolean coercion
result.nodes     // [XPathNode] (name + string value), for node-sets

// Convenience shorthands:
try doc.string("/catalog/book[1]/title")           // "XML Basics"
try doc.number("count(//book)")                    // 3
try doc.boolean("//book[@genre='tech']")           // true
try doc.nodes("//title")                           // [XPathNode]

// Evaluate relative to a context node:
try doc.string("price", context: "/catalog/book[2]")
```

Namespace prefixes in expressions are resolved against the namespace
declarations present in the parsed document.

### Errors and lifecycle

All failures throw `XalanError` (with `.message` and `.code`). The underlying
library is initialised automatically and thread-safely on first use. If you want
a clean shutdown at process exit you can call `Xalan.terminate()`, but it's
optional.

`XSLTProcessor` instances are **not** thread-safe — use one per thread. The
global library state *is* thread-safe.

## Notes & limitations

- Built against **Xalan-C 1.12** (XSLT **1.0** / XPath **1.0**) — this is the
  language level Xalan implements; there is no XSLT 2.0/3.0 support upstream.
- Xerces is built with its network accessor **off**, so `document()` calls and
  includes that reference remote `http(s)://` URLs won't fetch over the network.
  Local files and in-memory strings work fully. Rebuild Xerces without
  `-Dnetwork=OFF` (it will use libcurl) if you need remote retrieval.
- Runs on **macOS / iOS / iPadOS**, **arm64** only. There is no `x86_64`
  simulator slice (so no Intel-Mac iOS simulator) and no Intel-Mac native slice;
  see the architecture note above to add them.

## Licensing

`XalanCore.xcframework` statically links compiled code from two Apache Software
Foundation projects, both under the **Apache License 2.0**:

- **Apache Xalan-C++ 1.12.0** — XSLT/XPath engine
- **Apache Xerces-C++ 3.2.5** — XML parser

Because that compiled code is redistributed with this package, the Apache
License 2.0 requires shipping the license and attribution notices alongside it.
They are included here:

- [`NOTICE`](NOTICE) — aggregated attribution (Apache-2.0 §4(d)).
- [`ThirdPartyLicenses/Apache-Xalan-C/`](ThirdPartyLicenses/Apache-Xalan-C) —
  full `LICENSE`, `NOTICE`, `CREDITS`.
- [`ThirdPartyLicenses/Apache-Xerces-C/`](ThirdPartyLicenses/Apache-Xerces-C) —
  full `LICENSE`, `NOTICE`, `CREDITS`.

The Xalan/Xerces sources were compiled **unmodified** from their official
releases (only build flags changed). If you redistribute this package or an app
that embeds it, keep `NOTICE` and `ThirdPartyLicenses/` with it — that is all
the Apache License requires.

The Swift code and the C/C++ shim in this repository (`Sources/`, `native/`) are
original work, separate from the Apache projects, and are also licensed under the
**Apache License 2.0** — see [`LICENSE`](LICENSE). So the whole package (wrapper
+ bundled engines) is consistently Apache-2.0.
