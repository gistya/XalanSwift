import Xalan

// A small tour of the XalanSwift API.

print("Xalan-C version: \(Xalan.version)\n")

let catalog = """
<?xml version="1.0"?>
<catalog>
  <book id="1" genre="tech"><title>XML Basics</title><price>9.99</price></book>
  <book id="2" genre="tech"><title>XSLT Mastery</title><price>19.99</price></book>
  <book id="3" genre="ref"><title>XPath In Depth</title><price>14.50</price></book>
</catalog>
"""

// ---- XSLT transform -------------------------------------------------------

let stylesheet = """
<?xml version="1.0"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" indent="yes"/>
  <xsl:param name="heading"/>
  <xsl:template match="/">
    <html><body>
      <h1><xsl:value-of select="$heading"/></h1>
      <ul>
        <xsl:for-each select="catalog/book">
          <xsl:sort select="price" data-type="number"/>
          <li><xsl:value-of select="title"/> ($<xsl:value-of select="price"/>)</li>
        </xsl:for-each>
      </ul>
    </body></html>
  </xsl:template>
</xsl:stylesheet>
"""

do {
    let processor = try XSLTProcessor()
    processor.setParameter("heading", string: "Book Catalog")
    let html = try processor.transform(xml: catalog, stylesheet: stylesheet)
    print("=== XSLT output ===")
    print(html)
} catch {
    print("transform failed: \(error)")
}

// ---- XPath queries --------------------------------------------------------

do {
    let doc = try XalanDocument(xml: catalog)

    print("\n=== XPath queries ===")
    print("book count        : \(try doc.number("count(/catalog/book)"))")
    print("total price       : \(try doc.number("sum(/catalog/book/price)"))")
    print("has tech books    : \(try doc.boolean("/catalog/book[@genre='tech']"))")
    print("first title       : \(try doc.string("/catalog/book[1]/title"))")

    print("titles            :")
    for node in try doc.nodes("/catalog/book/title") {
        print("  - \(node.value)")
    }

    // Context-relative evaluation.
    let secondPrice = try doc.string("price", context: "/catalog/book[2]")
    print("2nd book price    : \(secondPrice)")
} catch {
    print("xpath failed: \(error)")
}
