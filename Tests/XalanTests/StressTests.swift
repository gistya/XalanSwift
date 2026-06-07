import XCTest
@testable import Xalan

/// Exercises the wrapper against a deliberately nasty document: multiple
/// namespaces (incl. an unprefixed default namespace), CDATA, mixed content,
/// Unicode, escaped entities, namespace shadowing, deep nesting and recursive
/// structures.
final class StressTests: XCTestCase {

    // MARK: - XPath

    func testNamespacedCounts() throws {
        let d = try XalanDocument(xml: Self.xml)
        // Prefixed elements resolve via the document's own namespace decls.
        XCTAssertEqual(try d.number("count(//a:user)"), 3)
        XCTAssertEqual(try d.number("count(//b:product)"), 3)
        // Default-namespace elements have no prefix in XPath 1.0 — reach them
        // namespace-agnostically with local-name().
        XCTAssertEqual(try d.number("count(//*[local-name()='link'])"), 3)
        XCTAssertEqual(try d.number("count(//*[local-name()='event'])"), 5)
    }

    func testAttributesAndSelfReference() throws {
        let d = try XalanDocument(xml: Self.xml)
        XCTAssertEqual(try d.string("string(//a:user[@id='u1']/@manager)"), "u3")
        // The user who manages themselves.
        XCTAssertEqual(try d.number("count(//a:user[@id = @manager])"), 1)
        XCTAssertEqual(
            try d.string("//a:user[@id = @manager]/*[local-name()='name']"),
            "Recursive Manager")
    }

    func testDeepNesting() throws {
        let d = try XalanDocument(xml: Self.xml)
        XCTAssertEqual(try d.string("normalize-space(//*[local-name()='n10'])"), "Deep value")
    }

    func testUnicodeRoundTrips() throws {
        let d = try XalanDocument(xml: Self.xml)
        let s = try d.string("//*[local-name()='unicode']")
        for needle in ["Ελληνικά", "中文", "日本語", "한국어", "😀", "🚀"] {
            XCTAssertTrue(s.contains(needle), "missing \(needle)")
        }
    }

    func testCDATAAndEscapedEntities() throws {
        let d = try XalanDocument(xml: Self.xml)
        let cdata = try d.string("//*[local-name()='cdata']")
        XCTAssertTrue(cdata.contains("<not-xml>"))
        XCTAssertTrue(cdata.contains("</not-xml>"))

        let escaped = try d.string("//*[local-name()='escaped']")
        XCTAssertTrue(escaped.contains("<tag>"))
        XCTAssertTrue(escaped.contains("&"))
        XCTAssertTrue(escaped.contains("\"quote\""))
        XCTAssertTrue(escaped.contains("'apostrophe'"))
    }

    func testNamespaceShadowing() throws {
        let d = try XalanDocument(xml: Self.xml)
        // Grouping items live in the default namespace.
        XCTAssertEqual(
            try d.number("count(//*[local-name()='item' and namespace-uri()='urn:default'])"), 5)
        // One item is in the shadowed urn:shadow namespace.
        XCTAssertEqual(
            try d.number("count(//*[local-name()='item' and namespace-uri()='urn:shadow'])"), 1)
        // And one is pulled back out into no namespace (xmlns="").
        XCTAssertEqual(
            try d.number("count(//*[local-name()='item' and namespace-uri()=''])"), 1)
    }

    func testNumericAndEmptyHandling() throws {
        let d = try XalanDocument(xml: Self.xml)
        // p3's price is empty, so sum over all prices is NaN; filter it out.
        XCTAssertEqual(try d.number("sum(//*[local-name()='price'][. != ''])"), 109.98, accuracy: 0.0001)
        XCTAssertTrue(try d.number("sum(//*[local-name()='price'])").isNaN)
        // Empty element string value.
        XCTAssertEqual(try d.string("//b:product[@id='p3']/*[local-name()='name']"), "")
        // Non-numeric field coerces to NaN.
        XCTAssertTrue(
            try d.number("//*[local-name()='record'][@id='r3']/*[local-name()='field'][@name='age']").isNaN)
        XCTAssertEqual(
            try d.string("//*[local-name()='record'][@id='r3']/*[local-name()='field'][@name='age']"),
            "not-a-number")
    }

    func testGraphAndGrouping() throws {
        let d = try XalanDocument(xml: Self.xml)
        XCTAssertEqual(try d.number("count(//*[local-name()='graph']/*[local-name()='node'])"), 4)
        // Edges: A→{B,C}, B→{C,D}, C→{A}, D→{} = 5.
        XCTAssertEqual(
            try d.number("count(//*[local-name()='graph']//*[local-name()='edge'])"), 5)
        XCTAssertEqual(try d.number("count(//*[local-name()='item'][@group='A'])"), 3)
        XCTAssertEqual(try d.number("count(//*[local-name()='item'][@group='B'])"), 2)
    }

    func testNodeSetEnumeration() throws {
        let d = try XalanDocument(xml: Self.xml)
        let names = try d.nodes("//a:user/*[local-name()='name']")
        XCTAssertEqual(names.map(\.value), ["John", "Jane", "Recursive Manager"])

        let sources = try d.nodes("//*[local-name()='link']/@source")
        XCTAssertEqual(sources.map(\.name), ["source", "source", "source"])
        XCTAssertEqual(sources.map(\.value), ["u1", "u1", "u2"])
    }

    func testContextRelativeQuery() throws {
        let d = try XalanDocument(xml: Self.xml)
        // Roles of u1, evaluated relative to that user element.  `roles` is in
        // the default namespace, so reach it via local-name() as well.
        let roles = try d.nodes("*[local-name()='roles']/*[local-name()='role']",
                                context: "//a:user[@id='u1']")
        XCTAssertEqual(roles.map(\.value), ["admin", "editor"])
    }

    // MARK: - XSLT

    func testNamespaceAwareTransform() throws {
        let p = try XSLTProcessor()
        let out = try p.transform(xml: Self.xml, stylesheet: Self.stylesheet)
        XCTAssertTrue(out.contains("USERS=3"), out)
        XCTAssertTrue(out.contains("PRODUCTS=3"), out)
        XCTAssertTrue(out.contains("DEEP=Deep value"), out)
        // xsl:sort with data-type="number" must order numerically, not lexically.
        XCTAssertTrue(out.contains("SORTED: 2 3 50 100 1000"), out)
        XCTAssertTrue(out.contains("PRICESUM=109.98"), out)
        // Muenchian grouping.
        XCTAssertTrue(out.contains("A=3"), out)
        XCTAssertTrue(out.contains("B=2"), out)
    }

    // MARK: - Volume / leak shake-out

    func testRepeatedParseAndEvaluate() throws {
        for _ in 0..<200 {
            let d = try XalanDocument(xml: Self.xml)
            XCTAssertEqual(try d.number("count(//a:user)"), 3)
            XCTAssertEqual(try d.string("normalize-space(//*[local-name()='n10'])"), "Deep value")
        }
    }

    func testRepeatedCompiledTransform() throws {
        let p = try XSLTProcessor()
        let css = try p.compileStylesheet(Self.stylesheet)
        let src = try p.parse(xml: Self.xml)
        let first = try p.transform(src, with: css)
        for _ in 0..<200 {
            XCTAssertEqual(try p.transform(src, with: css), first)
        }
    }

    // MARK: - Fixtures

    static let stylesheet = """
    <?xml version="1.0"?>
    <xsl:stylesheet version="1.0"
        xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
        xmlns:d="urn:default"
        xmlns:a="urn:alpha"
        xmlns:b="urn:beta">
      <xsl:output method="text"/>
      <xsl:key name="byGroup" match="d:item" use="@group"/>
      <xsl:template match="/d:root">
        <xsl:text>USERS=</xsl:text><xsl:value-of select="count(//a:user)"/><xsl:text>&#10;</xsl:text>
        <xsl:text>PRODUCTS=</xsl:text><xsl:value-of select="count(//b:product)"/><xsl:text>&#10;</xsl:text>
        <xsl:text>DEEP=</xsl:text><xsl:value-of select="normalize-space(//d:n10)"/><xsl:text>&#10;</xsl:text>
        <xsl:text>SORTED:</xsl:text><xsl:for-each select="d:ordering-test/d:event"><xsl:sort select="@seq" data-type="number"/><xsl:text> </xsl:text><xsl:value-of select="@seq"/></xsl:for-each><xsl:text>&#10;</xsl:text>
        <xsl:text>PRICESUM=</xsl:text><xsl:value-of select="sum(//d:price[. != ''])"/><xsl:text>&#10;</xsl:text>
        <xsl:text>GROUPS:</xsl:text>
        <xsl:for-each select="//d:item[generate-id() = generate-id(key('byGroup', @group)[1])]">
          <xsl:text> </xsl:text><xsl:value-of select="@group"/><xsl:text>=</xsl:text><xsl:value-of select="count(key('byGroup', @group))"/>
        </xsl:for-each>
      </xsl:template>
    </xsl:stylesheet>
    """

    static let xml = #"""
    <?xml version="1.0" encoding="UTF-8"?>

    <?processing-instruction target="test" mode="complex"?>

    <root
        xmlns="urn:default"
        xmlns:a="urn:alpha"
        xmlns:b="urn:beta"
        xmlns:c="urn:gamma"
        generated="2026-06-06T10:15:30Z">

        <!-- Top-level comment -->

        <metadata>
            <title>Extremely Difficult XML Dataset</title>
            <description>
                Mixed content
                <emphasis>inside</emphasis>
                text nodes.
            </description>

            <unicode>
                Ελληνικά 中文 日本語 한국어 😀 🚀
            </unicode>

            <escaped>
                &lt;tag&gt;
                &amp;
                &quot;quote&quot;
                &apos;apostrophe&apos;
            </escaped>

            <empty-element />

            <cdata>
                <![CDATA[
                    <not-xml>
                        This would break a parser if not wrapped.
                    </not-xml>
                ]]>
            </cdata>
        </metadata>

        <a:users>

            <a:user id="u1" manager="u3">
                <name>John</name>
                <roles>
                    <role>admin</role>
                    <role>editor</role>
                </roles>
            </a:user>

            <a:user id="u2" manager="u1">
                <name>Jane</name>
                <roles>
                    <role>editor</role>
                </roles>
            </a:user>

            <a:user id="u3" manager="u3">
                <name>Recursive Manager</name>
            </a:user>

        </a:users>

        <b:products>

            <b:product id="p1" category="books">
                <name>XML Mastery</name>
                <price currency="USD">49.99</price>
                <tags>
                    <tag>xpath</tag>
                    <tag>xslt</tag>
                    <tag>xpath</tag>
                </tags>
            </b:product>

            <b:product id="p2" category="books">
                <name>XSLT Nightmares</name>
                <price currency="EUR">59.99</price>
            </b:product>

            <b:product id="p3" category="software">
                <name />
                <price currency="USD" />
            </b:product>

        </b:products>

        <relationships>

            <link source="u1" target="p1" type="purchased"/>
            <link source="u1" target="p2" type="purchased"/>
            <link source="u2" target="p1" type="wishlist"/>

        </relationships>

        <grouping-test>

            <item group="A" value="1"/>
            <item group="A" value="2"/>
            <item group="B" value="3"/>
            <item group="B" value="4"/>
            <item group="A" value="5"/>

        </grouping-test>

        <ordering-test>

            <event seq="100"/>
            <event seq="3"/>
            <event seq="50"/>
            <event seq="2"/>
            <event seq="1000"/>

        </ordering-test>

        <mixed-content>

            Some text.

            <bold>Bold text</bold>

            More text.

            <italic>Italic text</italic>

            End text.

        </mixed-content>

        <namespace-shadowing>

            <child xmlns="urn:shadow">

                <item>Shadow namespace</item>

                <inner xmlns="">
                    <item>No namespace</item>
                </inner>

            </child>

        </namespace-shadowing>

        <deep-nesting>

            <n1>
                <n2>
                    <n3>
                        <n4>
                            <n5>
                                <n6>
                                    <n7>
                                        <n8>
                                            <n9>
                                                <n10>
                                                    Deep value
                                                </n10>
                                            </n9>
                                        </n8>
                                    </n7>
                                </n6>
                            </n5>
                        </n4>
                    </n3>
                </n2>
            </n1>

        </deep-nesting>

        <graph>

            <node id="A">
                <edge to="B"/>
                <edge to="C"/>
            </node>

            <node id="B">
                <edge to="C"/>
                <edge to="D"/>
            </node>

            <node id="C">
                <edge to="A"/>
            </node>

            <node id="D"/>

        </graph>

        <records>

            <record id="r1">
                <field name="name">Alice</field>
                <field name="age">31</field>
                <field name="city">Seattle</field>
            </record>

            <record id="r2">
                <field name="name">Bob</field>
                <field name="city"/>
            </record>

            <record id="r3">
                <field name="name">Charlie</field>
                <field name="age">not-a-number</field>
            </record>

        </records>

        <recursive-tree id="root-node">

            <node id="tree-1">

                <node id="tree-1-1">
                    <node id="tree-1-1-1"/>
                </node>

                <node id="tree-1-2"/>

            </node>

        </recursive-tree>

    </root>
    """#
}
