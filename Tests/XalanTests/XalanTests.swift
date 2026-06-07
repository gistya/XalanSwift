import XCTest
@testable import Xalan

final class TransformTests: XCTestCase {

    let xml = """
    <?xml version="1.0"?>
    <catalog>
      <book id="1"><title>XML Basics</title><price>9.99</price></book>
      <book id="2"><title>XSLT Mastery</title><price>19.99</price></book>
      <book id="3"><title>XPath In Depth</title><price>14.50</price></book>
    </catalog>
    """

    let textStylesheet = """
    <?xml version="1.0"?>
    <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
      <xsl:output method="text"/>
      <xsl:template match="/">
        <xsl:for-each select="catalog/book">
          <xsl:value-of select="title"/> = <xsl:value-of select="price"/>
          <xsl:text>&#10;</xsl:text>
        </xsl:for-each>
      </xsl:template>
    </xsl:stylesheet>
    """

    func testStringTransform() throws {
        let p = try XSLTProcessor()
        let out = try p.transform(xml: xml, stylesheet: textStylesheet)
        XCTAssertTrue(out.contains("XML Basics = 9.99"))
        XCTAssertTrue(out.contains("XSLT Mastery = 19.99"))
        XCTAssertTrue(out.contains("XPath In Depth = 14.5"))
    }

    func testParameters() throws {
        let p = try XSLTProcessor()
        let ss = """
        <?xml version="1.0"?>
        <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
          <xsl:output method="text"/>
          <xsl:param name="greeting"/>
          <xsl:param name="count"/>
          <xsl:template match="/"><xsl:value-of select="$greeting"/> x<xsl:value-of select="$count"/></xsl:template>
        </xsl:stylesheet>
        """
        p.setParameter("greeting", string: "Hello")
        p.setParameter("count", number: 3)
        let out = try p.transform(xml: "<root/>", stylesheet: ss)
        XCTAssertEqual(out, "Hello x3")
    }

    func testStringParameterWithQuotes() throws {
        let p = try XSLTProcessor()
        let ss = """
        <?xml version="1.0"?>
        <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
          <xsl:output method="text"/>
          <xsl:param name="v"/>
          <xsl:template match="/"><xsl:value-of select="$v"/></xsl:template>
        </xsl:stylesheet>
        """
        for value in ["plain", "it's", "she said \"hi\"", "both ' and \" here"] {
            p.setParameter("v", string: value)
            XCTAssertEqual(try p.transform(xml: "<root/>", stylesheet: ss), value)
        }
    }

    func testCompiledAndParsedReuse() throws {
        let p = try XSLTProcessor()
        let css = try p.compileStylesheet(textStylesheet)
        let src = try p.parse(xml: xml)
        let a = try p.transform(src, with: css)
        let b = try p.transform(src, with: css)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("XSLT Mastery = 19.99"))
    }

    func testFileTransform() throws {
        let dir = NSTemporaryDirectory()
        let xmlPath = dir + "cat.xml"
        let xslPath = dir + "cat.xsl"
        let outPath = dir + "cat.out"
        try xml.write(toFile: xmlPath, atomically: true, encoding: .utf8)
        try textStylesheet.write(toFile: xslPath, atomically: true, encoding: .utf8)

        let p = try XSLTProcessor()
        try p.transformFile(xml: xmlPath, stylesheet: xslPath, output: outPath)
        let written = try String(contentsOfFile: outPath, encoding: .utf8)
        XCTAssertTrue(written.contains("XML Basics = 9.99"))

        let inMemory = try p.transformFile(xml: xmlPath, stylesheet: xslPath)
        XCTAssertEqual(written, inMemory)
    }

    func testTransformErrorSurfacesMessage() throws {
        let p = try XSLTProcessor()
        XCTAssertThrowsError(try p.transform(xml: "<root/>", stylesheet: "not xml at all")) { error in
            let e = error as! XalanError
            XCTAssertFalse(e.message.isEmpty)
        }
    }

    func testVersion() {
        XCTAssertEqual(Xalan.version, "1.12.0")
    }
}

final class XPathTests: XCTestCase {

    let doc = """
    <?xml version="1.0"?>
    <catalog>
      <book id="1"><title>XML Basics</title><price>9.99</price></book>
      <book id="2"><title>XSLT Mastery</title><price>19.99</price></book>
      <book id="3"><title>XPath In Depth</title><price>14.50</price></book>
    </catalog>
    """

    func testStringValue() throws {
        let d = try XalanDocument(xml: doc)
        XCTAssertEqual(try d.string("/catalog/book[1]/title"), "XML Basics")
    }

    func testNumber() throws {
        let d = try XalanDocument(xml: doc)
        XCTAssertEqual(try d.number("count(/catalog/book)"), 3)
        XCTAssertEqual(try d.number("sum(/catalog/book/price)"), 44.48, accuracy: 0.0001)
    }

    func testBoolean() throws {
        let d = try XalanDocument(xml: doc)
        XCTAssertTrue(try d.boolean("/catalog/book[@id='2']"))
        XCTAssertFalse(try d.boolean("/catalog/book[@id='99']"))
    }

    func testNodeSet() throws {
        let d = try XalanDocument(xml: doc)
        let titles = try d.nodes("/catalog/book/title")
        XCTAssertEqual(titles.count, 3)
        XCTAssertEqual(titles.map(\.value), ["XML Basics", "XSLT Mastery", "XPath In Depth"])
        XCTAssertEqual(titles.first?.name, "title")
    }

    func testContextNode() throws {
        let d = try XalanDocument(xml: doc)
        // Evaluate price relative to the second book.
        let price = try d.string("price", context: "/catalog/book[2]")
        XCTAssertEqual(price, "19.99")
    }

    func testResultKind() throws {
        let d = try XalanDocument(xml: doc)
        XCTAssertEqual(try d.evaluate("1 + 2").kind, .number)
        XCTAssertEqual(try d.evaluate("'hi'").kind, .string)
        XCTAssertEqual(try d.evaluate("true()").kind, .boolean)
        XCTAssertEqual(try d.evaluate("//book").kind, .nodeSet)
    }

    func testParseError() {
        XCTAssertThrowsError(try XalanDocument(xml: "<unclosed>"))
    }
}
