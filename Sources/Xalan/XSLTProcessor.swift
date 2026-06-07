import CXalan
import Foundation

/// An XSLT 1.0 processor backed by Apache Xalan-C++.
///
/// A processor is the entry point for transforming XML with stylesheets.  It
/// also owns any ``CompiledStylesheet`` and ``ParsedSource`` instances you
/// create from it, so keep the processor alive while those are in use.
///
/// Instances are *not* thread-safe; use one processor per thread (the global
/// library state is shared and thread-safe, individual processors are not).
public final class XSLTProcessor {

    let handle: cxalan_transformer

    /// Create a new processor.
    public init() throws {
        Xalan.ensureInitialized()
        guard let h = cxalan_transformer_create() else {
            throw XalanError(message: "could not create XalanTransformer")
        }
        handle = h
    }

    deinit {
        cxalan_transformer_destroy(handle)
    }

    /// The message describing the most recent failure on this processor.
    public var lastError: String {
        String(cString: cxalan_transformer_last_error(handle))
    }

    private func fail(_ code: Int32) -> XalanError {
        XalanError(message: lastError.isEmpty ? "transformation failed" : lastError,
                   code: code)
    }

    // MARK: - One-shot transforms

    /// Transform an in-memory XML string with an in-memory stylesheet string.
    public func transform(xml: String, stylesheet: String) throws -> String {
        let data = try transform(xml: Data(xml.utf8), stylesheet: Data(stylesheet.utf8))
        return String(decoding: data, as: UTF8.self)
    }

    /// Transform in-memory XML data with in-memory stylesheet data, returning
    /// the raw result bytes (honouring the stylesheet's `xsl:output` encoding).
    public func transform(xml: Data, stylesheet: Data) throws -> Data {
        var out: UnsafeMutablePointer<CChar>?
        var outLen: Int = 0
        let rc = xml.withUnsafeBytesCChar { xmlPtr, xmlCount in
            stylesheet.withUnsafeBytesCChar { xslPtr, xslCount in
                cxalan_transform_string(handle,
                                        xmlPtr, xmlCount,
                                        xslPtr, xslCount,
                                        &out, &outLen)
            }
        }
        guard rc == 0, let out else { throw fail(rc) }
        defer { cxalan_free(out) }
        return Data(bytes: out, count: outLen)
    }

    /// Transform a document file with a stylesheet file, writing to `outputFile`.
    public func transformFile(xml xmlFile: String,
                              stylesheet xslFile: String,
                              output outputFile: String) throws {
        let rc = cxalan_transform_file_to_file(handle, xmlFile, xslFile, outputFile)
        if rc != 0 { throw fail(rc) }
    }

    /// Transform a document file with a stylesheet file, returning the result.
    public func transformFile(xml xmlFile: String,
                              stylesheet xslFile: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        var outLen: Int = 0
        let rc = cxalan_transform_file_to_string(handle, xmlFile, xslFile, &out, &outLen)
        guard rc == 0, let out else { throw fail(rc) }
        defer { cxalan_free(out) }
        return String(decoding: Data(bytes: out, count: outLen), as: UTF8.self)
    }

    /// Transform XML using the stylesheet referenced by its own
    /// `<?xml-stylesheet?>` processing instruction.
    public func transformUsingEmbeddedStylesheet(xml: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        var outLen: Int = 0
        let data = Data(xml.utf8)
        let rc = data.withUnsafeBytesCChar { ptr, count in
            cxalan_transform_string_with_pi(handle, ptr, count, &out, &outLen)
        }
        guard rc == 0, let out else { throw fail(rc) }
        defer { cxalan_free(out) }
        return String(decoding: Data(bytes: out, count: outLen), as: UTF8.self)
    }

    // MARK: - Compiled stylesheets & parsed sources (reuse)

    /// Compile a stylesheet from a string so it can be applied many times.
    public func compileStylesheet(_ xsl: String) throws -> CompiledStylesheet {
        var css: cxalan_compiled_stylesheet?
        let data = Data(xsl.utf8)
        let rc = data.withUnsafeBytesCChar { ptr, count in
            cxalan_compile_stylesheet_string(handle, ptr, count, &css)
        }
        guard rc == 0, let css else { throw fail(rc) }
        return CompiledStylesheet(handle: css, processor: self)
    }

    /// Compile a stylesheet from a file so it can be applied many times.
    public func compileStylesheet(contentsOfFile path: String) throws -> CompiledStylesheet {
        var css: cxalan_compiled_stylesheet?
        let rc = cxalan_compile_stylesheet_file(handle, path, &css)
        guard rc == 0, let css else { throw fail(rc) }
        return CompiledStylesheet(handle: css, processor: self)
    }

    /// Parse an XML document from a string so it can be transformed many times.
    public func parse(xml: String) throws -> ParsedSource {
        var ps: cxalan_parsed_source?
        let data = Data(xml.utf8)
        let rc = data.withUnsafeBytesCChar { ptr, count in
            cxalan_parse_source_string(handle, ptr, count, &ps)
        }
        guard rc == 0, let ps else { throw fail(rc) }
        return ParsedSource(handle: ps, processor: self)
    }

    /// Parse an XML document from a file so it can be transformed many times.
    public func parse(contentsOfFile path: String) throws -> ParsedSource {
        var ps: cxalan_parsed_source?
        let rc = cxalan_parse_source_file(handle, path, &ps)
        guard rc == 0, let ps else { throw fail(rc) }
        return ParsedSource(handle: ps, processor: self)
    }

    /// Apply a compiled stylesheet to a parsed source, returning the result.
    public func transform(_ source: ParsedSource,
                          with stylesheet: CompiledStylesheet) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        var outLen: Int = 0
        let rc = cxalan_transform_prebuilt_to_string(handle,
                                                     source.handle,
                                                     stylesheet.handle,
                                                     &out, &outLen)
        guard rc == 0, let out else { throw fail(rc) }
        defer { cxalan_free(out) }
        return String(decoding: Data(bytes: out, count: outLen), as: UTF8.self)
    }

    /// Apply a compiled stylesheet to a parsed source, writing to a file.
    public func transform(_ source: ParsedSource,
                          with stylesheet: CompiledStylesheet,
                          toFile path: String) throws {
        let rc = cxalan_transform_prebuilt_to_file(handle,
                                                   source.handle,
                                                   stylesheet.handle,
                                                   path)
        if rc != 0 { throw fail(rc) }
    }

    // MARK: - Top level stylesheet parameters

    /// Set a top-level `xsl:param`, whose value is the given XPath expression.
    ///
    /// To pass a literal string value, quote it: `setParameter("name", xpath: "'World'")`.
    public func setParameter(_ key: String, xpath expression: String) {
        cxalan_set_param_string(handle, key, expression)
    }

    /// Set a top-level `xsl:param` to a literal string value.
    ///
    /// The value is wrapped in a valid XPath string literal (using `concat()`
    /// when it contains both kinds of quote), so any Swift string is handled.
    public func setParameter(_ key: String, string value: String) {
        cxalan_set_param_string(handle, key, XPathLiteral.encode(value))
    }

    /// Set a top-level `xsl:param` to a numeric value.
    public func setParameter(_ key: String, number value: Double) {
        cxalan_set_param_number(handle, key, value)
    }

    /// Clear all top-level stylesheet parameters previously set.
    public func clearParameters() {
        cxalan_clear_params(handle)
    }

    // MARK: - Options

    /// Whether the source document is validated against its DTD/schema.
    public func setValidation(_ enabled: Bool) {
        cxalan_set_use_validation(handle, enabled ? 1 : 0)
    }

    /// Set output indentation amount; pass a negative value to disable.
    public func setIndent(_ amount: Int) {
        cxalan_set_indent(handle, Int32(amount))
    }

    /// Override the output encoding (e.g. `"UTF-8"`, `"ISO-8859-1"`).
    public func setOutputEncoding(_ encoding: String) {
        cxalan_set_output_encoding(handle, encoding)
    }
}

/// A stylesheet parsed and compiled once for reuse across many transforms.
///
/// Owned by the ``XSLTProcessor`` that created it; it keeps that processor
/// alive for as long as it exists.
public final class CompiledStylesheet {
    let handle: cxalan_compiled_stylesheet
    private let processor: XSLTProcessor

    init(handle: cxalan_compiled_stylesheet, processor: XSLTProcessor) {
        self.handle = handle
        self.processor = processor
    }

    deinit {
        _ = cxalan_destroy_compiled_stylesheet(processor.handle, handle)
    }
}

/// An XML document parsed once for reuse across many transforms.
///
/// Owned by the ``XSLTProcessor`` that created it; it keeps that processor
/// alive for as long as it exists.
public final class ParsedSource {
    let handle: cxalan_parsed_source
    private let processor: XSLTProcessor

    init(handle: cxalan_parsed_source, processor: XSLTProcessor) {
        self.handle = handle
        self.processor = processor
    }

    deinit {
        _ = cxalan_destroy_parsed_source(processor.handle, handle)
    }
}

// MARK: - XPath string literal encoding

/// Encodes an arbitrary string as an XPath 1.0 string literal expression.
enum XPathLiteral {
    static func encode(_ s: String) -> String {
        if !s.contains("'") {
            return "'\(s)'"
        }
        if !s.contains("\"") {
            return "\"\(s)\""
        }
        // Contains both quote kinds: split on single quotes and concat the
        // pieces with literal apostrophes (delimited by double quotes).
        let parts = s.split(separator: "'", omittingEmptySubsequences: false)
        let pieces = parts.map { "'\($0)'" }.joined(separator: ", \"'\", ")
        return "concat(\(pieces))"
    }
}

// MARK: - Data helper

extension Data {
    /// Call `body` with a `const char*` pointer + length view of the bytes,
    /// using a valid (non-nil) pointer even when the data is empty.
    func withUnsafeBytesCChar<R>(_ body: (UnsafePointer<CChar>, Int) -> R) -> R {
        if isEmpty {
            let empty: [CChar] = [0]
            return empty.withUnsafeBufferPointer { body($0.baseAddress!, 0) }
        }
        return withUnsafeBytes { raw in
            body(raw.bindMemory(to: CChar.self).baseAddress!, count)
        }
    }
}
