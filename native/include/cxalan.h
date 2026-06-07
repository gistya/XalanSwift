/*
 * cxalan.h — a flat C bridging API over Apache Xalan-C++ (XSLT 1.0 + XPath 1.0).
 *
 * This header is intentionally pure C (no C++ types leak through) so it can be
 * imported directly by Swift's Clang importer.  The implementation (shim.cpp)
 * is C++ and links against the static Xalan-C / Xerces-C libraries.
 *
 * Conventions:
 *   - Functions returning `int` return 0 on success and non-zero on failure,
 *     unless documented otherwise.  Use the relevant *_last_error / errOut
 *     channel to retrieve a human readable message.
 *   - Strings handed back through `char**` out-parameters are heap allocated
 *     and must be released with cxalan_free().
 *   - Input byte buffers are treated as UTF-8 (or whatever encoding the XML
 *     declaration specifies, since Xerces sniffs the document prolog).
 */
#ifndef CXALAN_H
#define CXALAN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* Library lifecycle                                                  */
/* ------------------------------------------------------------------ */

/* Initialise Xerces, the Xalan transformer subsystem, the XPath engine and
 * the source-tree DOM.  Must be called once per process before any other
 * call.  Returns 0 on success. */
int  cxalan_initialize(void);

/* Tear everything down.  Pass non-zero to additionally clean up ICU (only do
 * this if ICU will no longer be used anywhere in the process). */
void cxalan_terminate(int cleanupICU);

/* The Xalan-C version string this shim was built against, e.g. "1.12.0". */
const char* cxalan_version(void);

/* Free a buffer returned by any cxalan_* function via a char** out-param. */
void cxalan_free(void* p);

/* ------------------------------------------------------------------ */
/* Opaque handles                                                     */
/* ------------------------------------------------------------------ */

typedef void*       cxalan_transformer;            /* a XalanTransformer        */
typedef const void* cxalan_compiled_stylesheet;    /* a XalanCompiledStylesheet */
typedef const void* cxalan_parsed_source;          /* a XalanParsedSource       */
typedef void*       cxalan_document;               /* parsed doc for XPath      */
typedef void*       cxalan_xpath_result;           /* an evaluated XPath result */

/* ------------------------------------------------------------------ */
/* Transformer                                                        */
/* ------------------------------------------------------------------ */

cxalan_transformer cxalan_transformer_create(void);
void               cxalan_transformer_destroy(cxalan_transformer t);

/* Message describing the most recent failure on this transformer (UTF-8,
 * owned by the transformer, valid until the next call).  Never NULL. */
const char* cxalan_transformer_last_error(cxalan_transformer t);

/* --- One-shot transforms --- */

/* Apply xslFile to xmlFile, writing the result to outFile. 0 == success. */
int cxalan_transform_file_to_file(cxalan_transformer t,
                                  const char* xmlFile,
                                  const char* xslFile,
                                  const char* outFile);

/* Apply an in-memory stylesheet to an in-memory document.
 * *out receives a heap buffer of length *outLen (free with cxalan_free). */
int cxalan_transform_string(cxalan_transformer t,
                            const char* xml, size_t xmlLen,
                            const char* xsl, size_t xslLen,
                            char** out, size_t* outLen);

/* Apply xslFile to xmlFile, returning the result in memory. */
int cxalan_transform_file_to_string(cxalan_transformer t,
                                    const char* xmlFile,
                                    const char* xslFile,
                                    char** out, size_t* outLen);

/* Apply the stylesheet referenced by the document's xml-stylesheet PI. */
int cxalan_transform_string_with_pi(cxalan_transformer t,
                                    const char* xml, size_t xmlLen,
                                    char** out, size_t* outLen);

/* --- Prebuilt (compiled stylesheet + parsed source) transforms --- */

int cxalan_transform_prebuilt_to_string(cxalan_transformer t,
                                        cxalan_parsed_source src,
                                        cxalan_compiled_stylesheet css,
                                        char** out, size_t* outLen);

int cxalan_transform_prebuilt_to_file(cxalan_transformer t,
                                      cxalan_parsed_source src,
                                      cxalan_compiled_stylesheet css,
                                      const char* outFile);

/* --- Compiled stylesheets (reuse across many transforms) --- */

int cxalan_compile_stylesheet_file(cxalan_transformer t,
                                   const char* xslFile,
                                   cxalan_compiled_stylesheet* out);

int cxalan_compile_stylesheet_string(cxalan_transformer t,
                                     const char* xsl, size_t xslLen,
                                     cxalan_compiled_stylesheet* out);

int cxalan_destroy_compiled_stylesheet(cxalan_transformer t,
                                       cxalan_compiled_stylesheet css);

/* --- Parsed sources (reuse one parse across many transforms) --- */

int cxalan_parse_source_file(cxalan_transformer t,
                             const char* xmlFile,
                             cxalan_parsed_source* out);

int cxalan_parse_source_string(cxalan_transformer t,
                               const char* xml, size_t xmlLen,
                               cxalan_parsed_source* out);

int cxalan_destroy_parsed_source(cxalan_transformer t,
                                 cxalan_parsed_source src);

/* --- Top level stylesheet parameters (xsl:param) --- */

/* Set a parameter whose value is an XPath expression string.
 * NOTE: to pass a literal string, wrap it in quotes, e.g. "'hello'". */
void cxalan_set_param_string(cxalan_transformer t,
                             const char* key, const char* xpathExpr);

void cxalan_set_param_number(cxalan_transformer t,
                             const char* key, double value);

void cxalan_clear_params(cxalan_transformer t);

/* --- Processor options --- */

void cxalan_set_use_validation(cxalan_transformer t, int enabled);
void cxalan_set_indent(cxalan_transformer t, int amount);       /* <0 disables */
void cxalan_set_output_encoding(cxalan_transformer t, const char* encoding);

/* ------------------------------------------------------------------ */
/* XPath                                                              */
/* ------------------------------------------------------------------ */

/* Parse an XML document into a reusable source tree for XPath queries.
 * On failure returns NULL and, if errOut is non-NULL, sets *errOut to a heap
 * message (free with cxalan_free). */
cxalan_document cxalan_document_parse_file(const char* xmlFile, char** errOut);
cxalan_document cxalan_document_parse_string(const char* xml, size_t xmlLen,
                                             char** errOut);
void            cxalan_document_destroy(cxalan_document doc);

/* XObject result kinds, mirroring xalanc::XObject::eObjectType. */
typedef enum {
    CXALAN_XOBJ_UNKNOWN   = -1,
    CXALAN_XOBJ_NULL      = 0,
    CXALAN_XOBJ_BOOLEAN   = 2,
    CXALAN_XOBJ_NUMBER    = 3,
    CXALAN_XOBJ_STRING    = 4,
    CXALAN_XOBJ_NODESET   = 5,
    CXALAN_XOBJ_RTREEFRAG = 6
} cxalan_xobject_type;

/* Evaluate an XPath expression against doc.  `contextPath` selects the context
 * node (an XPath itself); pass NULL/"" to use the document root.  Namespace
 * prefixes are resolved against the namespaces declared in the document.
 *
 * Returns a result handle (free with cxalan_xpath_result_destroy) or NULL on
 * error (errOut, if non-NULL, receives a heap message). */
cxalan_xpath_result cxalan_xpath_evaluate(cxalan_document doc,
                                          const char* contextPath,
                                          const char* expr,
                                          char** errOut);

void                cxalan_xpath_result_destroy(cxalan_xpath_result r);

cxalan_xobject_type cxalan_xpath_result_type(cxalan_xpath_result r);

/* Scalar coercions (defined for every result type, per XPath 1.0 rules). */
int    cxalan_xpath_result_boolean(cxalan_xpath_result r);
double cxalan_xpath_result_number(cxalan_xpath_result r);
/* String value of the whole result (UTF-8, owned by the result). */
const char* cxalan_xpath_result_string(cxalan_xpath_result r);

/* For node-set results: number of nodes, and per-node accessors.
 * Returned strings are UTF-8 and owned by the result (valid until destroy). */
int         cxalan_xpath_result_node_count(cxalan_xpath_result r);
const char* cxalan_xpath_result_node_name(cxalan_xpath_result r, int index);
const char* cxalan_xpath_result_node_value(cxalan_xpath_result r, int index);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CXALAN_H */
