import CXalan
import Foundation

/// A single node returned by an XPath node-set query.
public struct XPathNode: Equatable, Sendable {
    /// The node name (e.g. element tag name, `#text`, attribute name).
    public let name: String
    /// The node's string value (text content / attribute value).
    public let value: String
}

/// The typed result of evaluating an XPath 1.0 expression.
///
/// XPath produces one of four value kinds.  Every result can still be coerced
/// to the scalar types via ``boolean``, ``number`` and ``string`` following the
/// XPath 1.0 conversion rules.
public struct XPathResult: Sendable {

    public enum Kind: Sendable {
        case null
        case boolean
        case number
        case string
        case nodeSet
        case resultTreeFragment
        case unknown
    }

    /// The natural kind of this result.
    public let kind: Kind
    /// The result coerced to a boolean.
    public let boolean: Bool
    /// The result coerced to a number (may be NaN).
    public let number: Double
    /// The result's string value.
    public let string: String
    /// For node-set results, the matched nodes in document order.
    public let nodes: [XPathNode]
}

/// An XML document parsed into a Xalan source tree, ready for XPath queries.
///
/// This is independent of ``XSLTProcessor`` and is the right tool when you only
/// need to *query* XML rather than transform it.  Namespace prefixes used in
/// expressions are resolved against the namespace declarations in the document.
public final class XalanDocument {

    private let handle: cxalan_document

    /// Parse a document from an in-memory XML string.
    public init(xml: String) throws {
        Xalan.ensureInitialized()
        var err: UnsafeMutablePointer<CChar>?
        let data = Data(xml.utf8)
        let h = data.withUnsafeBytesCChar { ptr, count in
            cxalan_document_parse_string(ptr, count, &err)
        }
        guard let h else { throw XalanDocument.error(from: err, fallback: "failed to parse XML") }
        handle = h
    }

    /// Parse a document from a file path.
    public init(contentsOfFile path: String) throws {
        Xalan.ensureInitialized()
        var err: UnsafeMutablePointer<CChar>?
        let h = cxalan_document_parse_file(path, &err)
        guard let h else { throw XalanDocument.error(from: err, fallback: "failed to parse XML file") }
        handle = h
    }

    deinit {
        cxalan_document_destroy(handle)
    }

    private static func error(from ptr: UnsafeMutablePointer<CChar>?,
                              fallback: String) -> XalanError {
        if let ptr {
            defer { cxalan_free(ptr) }
            return XalanError(message: String(cString: ptr))
        }
        return XalanError(message: fallback)
    }

    /// Evaluate an XPath expression and return the full typed result.
    ///
    /// - Parameters:
    ///   - expression: the XPath 1.0 expression.
    ///   - context: an optional XPath selecting the context node the expression
    ///     is evaluated against; defaults to the document root.
    public func evaluate(_ expression: String, context: String? = nil) throws -> XPathResult {
        var err: UnsafeMutablePointer<CChar>?
        guard let result = cxalan_xpath_evaluate(handle, context, expression, &err) else {
            throw XalanDocument.error(from: err, fallback: "failed to evaluate XPath")
        }
        defer { cxalan_xpath_result_destroy(result) }

        let kind: XPathResult.Kind
        switch cxalan_xpath_result_type(result) {
        case CXALAN_XOBJ_NULL:      kind = .null
        case CXALAN_XOBJ_BOOLEAN:   kind = .boolean
        case CXALAN_XOBJ_NUMBER:    kind = .number
        case CXALAN_XOBJ_STRING:    kind = .string
        case CXALAN_XOBJ_NODESET:   kind = .nodeSet
        case CXALAN_XOBJ_RTREEFRAG: kind = .resultTreeFragment
        default:                    kind = .unknown
        }

        var nodes: [XPathNode] = []
        if kind == .nodeSet {
            let count = Int(cxalan_xpath_result_node_count(result))
            nodes.reserveCapacity(count)
            for i in 0..<count {
                let name = String(cString: cxalan_xpath_result_node_name(result, Int32(i)))
                let value = String(cString: cxalan_xpath_result_node_value(result, Int32(i)))
                nodes.append(XPathNode(name: name, value: value))
            }
        }

        return XPathResult(
            kind: kind,
            boolean: cxalan_xpath_result_boolean(result) != 0,
            number: cxalan_xpath_result_number(result),
            string: String(cString: cxalan_xpath_result_string(result)),
            nodes: nodes
        )
    }

    // MARK: - Convenience coercions

    /// Evaluate and return the string value of the result.
    public func string(_ expression: String, context: String? = nil) throws -> String {
        try evaluate(expression, context: context).string
    }

    /// Evaluate and return the result as a number.
    public func number(_ expression: String, context: String? = nil) throws -> Double {
        try evaluate(expression, context: context).number
    }

    /// Evaluate and return the result as a boolean.
    public func boolean(_ expression: String, context: String? = nil) throws -> Bool {
        try evaluate(expression, context: context).boolean
    }

    /// Evaluate and return the matched nodes (empty unless the result is a node-set).
    public func nodes(_ expression: String, context: String? = nil) throws -> [XPathNode] {
        try evaluate(expression, context: context).nodes
    }
}
