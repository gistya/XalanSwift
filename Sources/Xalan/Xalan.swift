import CXalan

/// Namespace for global Apache Xalan-C++ library state.
///
/// The underlying C++ library has process-global initialisation that must run
/// exactly once before any transformer or XPath call.  This happens
/// automatically and thread-safely the first time you create a
/// ``XSLTProcessor`` or ``XalanDocument`` — you normally never call anything
/// here directly.
public enum Xalan {

    /// The Xalan-C++ version this wrapper was built against (e.g. `"1.12.0"`).
    public static let version = String(cString: cxalan_version())

    // Runs `cxalan_initialize()` exactly once.  `static let` gives us the
    // thread-safe run-once semantics for free.
    private static let bootstrap: Void = {
        if cxalan_initialize() != 0 {
            fatalError("Xalan: cxalan_initialize() failed — could not start Xerces/Xalan")
        }
    }()

    /// Ensure the library is initialised.  Idempotent and thread-safe.
    public static func initialize() {
        _ = bootstrap
    }

    static func ensureInitialized() {
        _ = bootstrap
    }

    /// Tear down the library.  Only call this once, at process shutdown, after
    /// every ``XSLTProcessor`` / ``XalanDocument`` has been released.  Using the
    /// library again afterwards is undefined.  You usually do not need this.
    ///
    /// - Parameter cleanupICU: also release ICU's static data (only safe if ICU
    ///   will not be used again anywhere in the process).
    public static func terminate(cleanupICU: Bool = false) {
        cxalan_terminate(cleanupICU ? 1 : 0)
    }
}

/// An error raised by the Xalan XSLT / XPath engine.
public struct XalanError: Error, CustomStringConvertible {
    /// Human-readable description of what went wrong.
    public let message: String
    /// The non-zero status code returned by the underlying C API, if any.
    public let code: Int32

    public init(message: String, code: Int32 = -1) {
        self.message = message
        self.code = code
    }

    public var description: String { message }
}
