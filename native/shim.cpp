/*
 * shim.cpp — C++ implementation of the flat cxalan.h C API over Apache Xalan-C++.
 *
 * Builds against the Xalan-C 1.12 / Xerces-C 3.2 public headers and links the
 * static libraries.  All exceptions thrown by Xalan/Xerces are trapped at the
 * C boundary and reported through return codes / error out-parameters.
 */

#include "cxalan.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <sstream>
#include <string>
#include <vector>

#include <xalanc/Include/PlatformDefinitions.hpp>

#include <xercesc/util/PlatformUtils.hpp>

#include <xalanc/PlatformSupport/XSLException.hpp>

#include <xalanc/XalanTransformer/XalanTransformer.hpp>

#include <xalanc/XalanDOM/XalanDOMString.hpp>
#include <xalanc/XalanDOM/XalanNode.hpp>
#include <xalanc/XalanDOM/XalanNodeList.hpp>

#include <xalanc/DOMSupport/DOMServices.hpp>
#include <xalanc/DOMSupport/XalanDocumentPrefixResolver.hpp>

#include <xalanc/XPath/NodeRefListBase.hpp>
#include <xalanc/XPath/XObject.hpp>
#include <xalanc/XPath/XPathEvaluator.hpp>
#include <xalanc/XPath/XPathExecutionContext.hpp>

#include <xalanc/XalanSourceTree/XalanSourceTreeInit.hpp>
#include <xalanc/XalanSourceTree/XalanSourceTreeDOMSupport.hpp>
#include <xalanc/XalanSourceTree/XalanSourceTreeParserLiaison.hpp>

#include <xalanc/XSLT/XSLTInputSource.hpp>
#include <xalanc/XSLT/XSLTResultTarget.hpp>

using namespace xercesc;
using namespace xalanc;

/* =================================================================== */
/* Encoding helpers (UTF-16 <-> UTF-8).                                */
/* XalanDOMChar / XMLCh is char16_t in this build.                     */
/* =================================================================== */

static void appendUTF8(std::string& out, unsigned int cp)
{
    if (cp <= 0x7Fu) {
        out.push_back(static_cast<char>(cp));
    } else if (cp <= 0x7FFu) {
        out.push_back(static_cast<char>(0xC0u | (cp >> 6)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    } else if (cp <= 0xFFFFu) {
        out.push_back(static_cast<char>(0xE0u | (cp >> 12)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    } else {
        out.push_back(static_cast<char>(0xF0u | (cp >> 18)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 12) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    }
}

static std::string utf16ToUTF8(const XalanDOMChar* s, size_t len)
{
    std::string out;
    if (s == 0) {
        return out;
    }
    out.reserve(len);
    for (size_t i = 0; i < len; ++i) {
        unsigned int c = static_cast<unsigned int>(static_cast<unsigned short>(s[i]));
        if (c >= 0xD800u && c <= 0xDBFFu && (i + 1) < len) {
            unsigned int c2 = static_cast<unsigned int>(static_cast<unsigned short>(s[i + 1]));
            if (c2 >= 0xDC00u && c2 <= 0xDFFFu) {
                unsigned int cp = 0x10000u + (((c - 0xD800u) << 10) | (c2 - 0xDC00u));
                appendUTF8(out, cp);
                ++i;
                continue;
            }
        }
        appendUTF8(out, c);
    }
    return out;
}

static std::string toUTF8(const XalanDOMString& s)
{
    return utf16ToUTF8(s.c_str(), static_cast<size_t>(s.length()));
}

/* NUL-terminated UTF-8 -> UTF-16 (XalanDOMChar) vector, NUL terminated. */
static std::vector<XalanDOMChar> utf8ToUTF16(const char* s)
{
    std::vector<XalanDOMChar> out;
    if (s == 0) {
        out.push_back(0);
        return out;
    }
    const unsigned char* p = reinterpret_cast<const unsigned char*>(s);
    while (*p) {
        unsigned int cp;
        unsigned char c = *p++;
        if (c < 0x80u) {
            cp = c;
        } else if ((c >> 5) == 0x6u) {
            cp = (c & 0x1Fu) << 6;
            cp |= (*p++ & 0x3Fu);
        } else if ((c >> 4) == 0xEu) {
            cp = (c & 0x0Fu) << 12;
            cp |= (*p++ & 0x3Fu) << 6;
            cp |= (*p++ & 0x3Fu);
        } else {
            cp = (c & 0x07u) << 18;
            cp |= (*p++ & 0x3Fu) << 12;
            cp |= (*p++ & 0x3Fu) << 6;
            cp |= (*p++ & 0x3Fu);
        }
        if (cp <= 0xFFFFu) {
            out.push_back(static_cast<XalanDOMChar>(cp));
        } else {
            cp -= 0x10000u;
            out.push_back(static_cast<XalanDOMChar>(0xD800u + (cp >> 10)));
            out.push_back(static_cast<XalanDOMChar>(0xDC00u + (cp & 0x3FFu)));
        }
    }
    out.push_back(0);
    return out;
}

static char* dupBytes(const std::string& s)
{
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p == 0) {
        return 0;
    }
    if (!s.empty()) {
        std::memcpy(p, s.data(), s.size());
    }
    p[s.size()] = '\0';
    return p;
}

static void setErr(char** errOut, const std::string& msg)
{
    if (errOut != 0) {
        *errOut = dupBytes(msg);
    }
}

/* =================================================================== */
/* Library lifecycle                                                  */
/* =================================================================== */

static XalanSourceTreeInit* g_sourceTreeInit = 0;

int cxalan_initialize(void)
{
    try {
        XMLPlatformUtils::Initialize();
        XalanTransformer::initialize();
        XPathEvaluator::initialize();
        g_sourceTreeInit = new XalanSourceTreeInit();
        return 0;
    } catch (...) {
        return -1;
    }
}

void cxalan_terminate(int cleanupICU)
{
    try {
        delete g_sourceTreeInit;
        g_sourceTreeInit = 0;
        XPathEvaluator::terminate();
        XalanTransformer::terminate();
        XMLPlatformUtils::Terminate();
        if (cleanupICU) {
            XalanTransformer::ICUCleanUp();
        }
    } catch (...) {
    }
}

const char* cxalan_version(void)
{
    return "1.12.0";
}

void cxalan_free(void* p)
{
    std::free(p);
}

/* =================================================================== */
/* Transformer                                                        */
/* =================================================================== */

cxalan_transformer cxalan_transformer_create(void)
{
    try {
        return new XalanTransformer();
    } catch (...) {
        return 0;
    }
}

void cxalan_transformer_destroy(cxalan_transformer t)
{
    delete static_cast<XalanTransformer*>(t);
}

const char* cxalan_transformer_last_error(cxalan_transformer t)
{
    if (t == 0) {
        return "";
    }
    return static_cast<XalanTransformer*>(t)->getLastError();
}

int cxalan_transform_file_to_file(cxalan_transformer t,
                                  const char* xmlFile,
                                  const char* xslFile,
                                  const char* outFile)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        XSLTInputSource  in(xmlFile);
        XSLTInputSource  ss(xslFile);
        XSLTResultTarget out(outFile);
        return x->transform(in, ss, out);
    } catch (...) {
        return -1;
    }
}

int cxalan_transform_string(cxalan_transformer t,
                            const char* xml, size_t xmlLen,
                            const char* xsl, size_t xslLen,
                            char** out, size_t* outLen)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::istringstream xmlStream(std::string(xml, xmlLen));
        std::istringstream xslStream(std::string(xsl, xslLen));
        std::ostringstream resultStream;
        XSLTInputSource  in(xmlStream);
        XSLTInputSource  ss(xslStream);
        XSLTResultTarget rt(resultStream);
        int rc = x->transform(in, ss, rt);
        if (rc != 0) {
            return rc;
        }
        std::string s = resultStream.str();
        if (out != 0)    { *out = dupBytes(s); }
        if (outLen != 0) { *outLen = s.size(); }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_transform_file_to_string(cxalan_transformer t,
                                    const char* xmlFile,
                                    const char* xslFile,
                                    char** out, size_t* outLen)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::ostringstream resultStream;
        XSLTInputSource  in(xmlFile);
        XSLTInputSource  ss(xslFile);
        XSLTResultTarget rt(resultStream);
        int rc = x->transform(in, ss, rt);
        if (rc != 0) {
            return rc;
        }
        std::string s = resultStream.str();
        if (out != 0)    { *out = dupBytes(s); }
        if (outLen != 0) { *outLen = s.size(); }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_transform_string_with_pi(cxalan_transformer t,
                                    const char* xml, size_t xmlLen,
                                    char** out, size_t* outLen)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::istringstream xmlStream(std::string(xml, xmlLen));
        std::ostringstream resultStream;
        XSLTInputSource  in(xmlStream);
        XSLTResultTarget rt(resultStream);
        int rc = x->transform(in, rt);
        if (rc != 0) {
            return rc;
        }
        std::string s = resultStream.str();
        if (out != 0)    { *out = dupBytes(s); }
        if (outLen != 0) { *outLen = s.size(); }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_transform_prebuilt_to_string(cxalan_transformer t,
                                        cxalan_parsed_source src,
                                        cxalan_compiled_stylesheet css,
                                        char** out, size_t* outLen)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::ostringstream resultStream;
        XSLTResultTarget rt(resultStream);
        int rc = x->transform(
            *static_cast<const XalanParsedSource*>(src),
            static_cast<const XalanCompiledStylesheet*>(css),
            rt);
        if (rc != 0) {
            return rc;
        }
        std::string s = resultStream.str();
        if (out != 0)    { *out = dupBytes(s); }
        if (outLen != 0) { *outLen = s.size(); }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_transform_prebuilt_to_file(cxalan_transformer t,
                                      cxalan_parsed_source src,
                                      cxalan_compiled_stylesheet css,
                                      const char* outFile)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        XSLTResultTarget rt(outFile);
        return x->transform(
            *static_cast<const XalanParsedSource*>(src),
            static_cast<const XalanCompiledStylesheet*>(css),
            rt);
    } catch (...) {
        return -1;
    }
}

int cxalan_compile_stylesheet_file(cxalan_transformer t,
                                   const char* xslFile,
                                   cxalan_compiled_stylesheet* out)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        XSLTInputSource ss(xslFile);
        const XalanCompiledStylesheet* css = 0;
        int rc = x->compileStylesheet(ss, css);
        if (rc != 0) {
            return rc;
        }
        if (out != 0) { *out = css; }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_compile_stylesheet_string(cxalan_transformer t,
                                     const char* xsl, size_t xslLen,
                                     cxalan_compiled_stylesheet* out)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::istringstream xslStream(std::string(xsl, xslLen));
        XSLTInputSource ss(xslStream);
        const XalanCompiledStylesheet* css = 0;
        int rc = x->compileStylesheet(ss, css);
        if (rc != 0) {
            return rc;
        }
        if (out != 0) { *out = css; }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_destroy_compiled_stylesheet(cxalan_transformer t,
                                       cxalan_compiled_stylesheet css)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        return x->destroyStylesheet(static_cast<const XalanCompiledStylesheet*>(css));
    } catch (...) {
        return -1;
    }
}

int cxalan_parse_source_file(cxalan_transformer t,
                             const char* xmlFile,
                             cxalan_parsed_source* out)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        XSLTInputSource in(xmlFile);
        const XalanParsedSource* ps = 0;
        int rc = x->parseSource(in, ps);
        if (rc != 0) {
            return rc;
        }
        if (out != 0) { *out = ps; }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_parse_source_string(cxalan_transformer t,
                               const char* xml, size_t xmlLen,
                               cxalan_parsed_source* out)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::istringstream xmlStream(std::string(xml, xmlLen));
        XSLTInputSource in(xmlStream);
        const XalanParsedSource* ps = 0;
        int rc = x->parseSource(in, ps);
        if (rc != 0) {
            return rc;
        }
        if (out != 0) { *out = ps; }
        return 0;
    } catch (...) {
        return -1;
    }
}

int cxalan_destroy_parsed_source(cxalan_transformer t,
                                 cxalan_parsed_source src)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        return x->destroyParsedSource(static_cast<const XalanParsedSource*>(src));
    } catch (...) {
        return -1;
    }
}

void cxalan_set_param_string(cxalan_transformer t,
                             const char* key, const char* xpathExpr)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::vector<XalanDOMChar> k = utf8ToUTF16(key);
        std::vector<XalanDOMChar> v = utf8ToUTF16(xpathExpr);
        x->setStylesheetParam(XalanDOMString(&k[0]), XalanDOMString(&v[0]));
    } catch (...) {
    }
}

void cxalan_set_param_number(cxalan_transformer t,
                             const char* key, double value)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        std::vector<XalanDOMChar> k = utf8ToUTF16(key);
        x->setStylesheetParam(XalanDOMString(&k[0]), value);
    } catch (...) {
    }
}

void cxalan_clear_params(cxalan_transformer t)
{
    XalanTransformer* x = static_cast<XalanTransformer*>(t);
    try {
        x->clearStylesheetParams();
    } catch (...) {
    }
}

void cxalan_set_use_validation(cxalan_transformer t, int enabled)
{
    static_cast<XalanTransformer*>(t)->setUseValidation(enabled != 0);
}

void cxalan_set_indent(cxalan_transformer t, int amount)
{
    static_cast<XalanTransformer*>(t)->setIndent(amount);
}

void cxalan_set_output_encoding(cxalan_transformer t, const char* encoding)
{
    try {
        std::vector<XalanDOMChar> e = utf8ToUTF16(encoding);
        static_cast<XalanTransformer*>(t)->setOutputEncoding(XalanDOMString(&e[0]));
    } catch (...) {
    }
}

/* =================================================================== */
/* XPath                                                              */
/* =================================================================== */

namespace {

struct Document {
    XalanSourceTreeDOMSupport*     domSupport;
    XalanSourceTreeParserLiaison*  liaison;
    XalanDocument*                 document;

    Document() : domSupport(0), liaison(0), document(0) {}
};

struct XPathResult {
    cxalan_xobject_type      type;
    bool                     boolValue;
    double                   numValue;
    std::string              strValue;          /* string value of result   */
    std::vector<std::string> nodeNames;         /* for node sets            */
    std::vector<std::string> nodeValues;        /* for node sets            */

    XPathResult() : type(CXALAN_XOBJ_UNKNOWN), boolValue(false), numValue(0.0) {}
};

cxalan_xobject_type mapType(XObject::eObjectType t)
{
    switch (t) {
    case XObject::eTypeNull:          return CXALAN_XOBJ_NULL;
    case XObject::eTypeBoolean:       return CXALAN_XOBJ_BOOLEAN;
    case XObject::eTypeNumber:        return CXALAN_XOBJ_NUMBER;
    case XObject::eTypeString:        return CXALAN_XOBJ_STRING;
    case XObject::eTypeNodeSet:       return CXALAN_XOBJ_NODESET;
    case XObject::eTypeResultTreeFrag:return CXALAN_XOBJ_RTREEFRAG;
    default:                          return CXALAN_XOBJ_STRING;
    }
}

} /* anonymous namespace */

static cxalan_document parseDocument(XSLTInputSource& in, char** errOut)
{
    Document* d = 0;
    try {
        d = new Document();
        d->domSupport = new XalanSourceTreeDOMSupport();
        d->liaison    = new XalanSourceTreeParserLiaison(*d->domSupport);
        d->domSupport->setParserLiaison(d->liaison);
        d->document   = d->liaison->parseXMLStream(in);
        if (d->document == 0) {
            setErr(errOut, "failed to parse XML document");
            delete d->liaison;
            delete d->domSupport;
            delete d;
            return 0;
        }
        return d;
    } catch (const XSLException& e) {
        XalanDOMString msg;
        e.defaultFormat(msg);
        setErr(errOut, toUTF8(msg));
    } catch (const std::exception& e) {
        setErr(errOut, e.what());
    } catch (...) {
        setErr(errOut, "unknown error parsing document");
    }
    if (d != 0) {
        delete d->liaison;
        delete d->domSupport;
        delete d;
    }
    return 0;
}

cxalan_document cxalan_document_parse_file(const char* xmlFile, char** errOut)
{
    try {
        XSLTInputSource in(xmlFile);
        return parseDocument(in, errOut);
    } catch (...) {
        setErr(errOut, "unknown error opening document");
        return 0;
    }
}

cxalan_document cxalan_document_parse_string(const char* xml, size_t xmlLen,
                                             char** errOut)
{
    try {
        std::istringstream xmlStream(std::string(xml, xmlLen));
        XSLTInputSource in(xmlStream);
        return parseDocument(in, errOut);
    } catch (...) {
        setErr(errOut, "unknown error reading document");
        return 0;
    }
}

void cxalan_document_destroy(cxalan_document doc)
{
    Document* d = static_cast<Document*>(doc);
    if (d == 0) {
        return;
    }
    delete d->liaison;     /* owns and frees the parsed document */
    delete d->domSupport;
    delete d;
}

cxalan_xpath_result cxalan_xpath_evaluate(cxalan_document doc,
                                          const char* contextPath,
                                          const char* expr,
                                          char** errOut)
{
    Document* d = static_cast<Document*>(doc);
    if (d == 0 || d->document == 0) {
        setErr(errOut, "invalid document handle");
        return 0;
    }
    try {
        XalanDocumentPrefixResolver prefixResolver(d->document);
        XPathEvaluator evaluator;

        XalanNode* contextNode = d->document;
        if (contextPath != 0 && contextPath[0] != '\0') {
            std::vector<XalanDOMChar> cp = utf8ToUTF16(contextPath);
            contextNode = evaluator.selectSingleNode(
                *d->domSupport,
                d->document,
                &cp[0],
                prefixResolver);
            if (contextNode == 0) {
                setErr(errOut, "context path matched no node");
                return 0;
            }
        }

        std::vector<XalanDOMChar> ex = utf8ToUTF16(expr);
        const XObjectPtr result = evaluator.evaluate(
            *d->domSupport,
            contextNode,
            &ex[0],
            prefixResolver);

        if (result.null()) {
            setErr(errOut, "expression produced a null result");
            return 0;
        }

        XPathExecutionContext& ctx = evaluator.getExecutionContext();

        XPathResult* out = new XPathResult();
        out->type      = mapType(result->getType());
        out->boolValue = result->boolean(ctx);
        out->numValue  = result->num(ctx);
        out->strValue  = toUTF8(result->str(ctx));

        if (out->type == CXALAN_XOBJ_NODESET) {
            const NodeRefListBase& nodes = result->nodeset();
            const NodeRefListBase::size_type n = nodes.getLength();
            out->nodeNames.reserve(n);
            out->nodeValues.reserve(n);
            for (NodeRefListBase::size_type i = 0; i < n; ++i) {
                XalanNode* node = nodes.item(i);
                if (node == 0) {
                    out->nodeNames.push_back(std::string());
                    out->nodeValues.push_back(std::string());
                    continue;
                }
                out->nodeNames.push_back(toUTF8(node->getNodeName()));
                XalanDOMString value;
                DOMServices::getNodeData(*node, value);
                out->nodeValues.push_back(toUTF8(value));
            }
        }
        return out;
    } catch (const XSLException& e) {
        XalanDOMString msg;
        e.defaultFormat(msg);
        setErr(errOut, toUTF8(msg));
    } catch (const std::exception& e) {
        setErr(errOut, e.what());
    } catch (...) {
        setErr(errOut, "unknown error evaluating XPath");
    }
    return 0;
}

void cxalan_xpath_result_destroy(cxalan_xpath_result r)
{
    delete static_cast<XPathResult*>(r);
}

cxalan_xobject_type cxalan_xpath_result_type(cxalan_xpath_result r)
{
    if (r == 0) { return CXALAN_XOBJ_UNKNOWN; }
    return static_cast<XPathResult*>(r)->type;
}

int cxalan_xpath_result_boolean(cxalan_xpath_result r)
{
    if (r == 0) { return 0; }
    return static_cast<XPathResult*>(r)->boolValue ? 1 : 0;
}

double cxalan_xpath_result_number(cxalan_xpath_result r)
{
    if (r == 0) { return 0.0; }
    return static_cast<XPathResult*>(r)->numValue;
}

const char* cxalan_xpath_result_string(cxalan_xpath_result r)
{
    if (r == 0) { return ""; }
    return static_cast<XPathResult*>(r)->strValue.c_str();
}

int cxalan_xpath_result_node_count(cxalan_xpath_result r)
{
    if (r == 0) { return 0; }
    return static_cast<int>(static_cast<XPathResult*>(r)->nodeValues.size());
}

const char* cxalan_xpath_result_node_name(cxalan_xpath_result r, int index)
{
    if (r == 0) { return ""; }
    XPathResult* res = static_cast<XPathResult*>(r);
    if (index < 0 || index >= static_cast<int>(res->nodeNames.size())) {
        return "";
    }
    return res->nodeNames[index].c_str();
}

const char* cxalan_xpath_result_node_value(cxalan_xpath_result r, int index)
{
    if (r == 0) { return ""; }
    XPathResult* res = static_cast<XPathResult*>(r);
    if (index < 0 || index >= static_cast<int>(res->nodeValues.size())) {
        return "";
    }
    return res->nodeValues[index].c_str();
}
