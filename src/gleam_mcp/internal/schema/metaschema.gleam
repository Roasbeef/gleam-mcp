//// Official Draft 2020-12 metaschemas, embedded as immutable offline resources.
//// Source: https://github.com/json-schema-org/json-schema-spec/tree/2020-12.
//// These literals retain the official documents without runtime file or network I/O.
//// Source commit: 601a66c8b0f25246bf0e1fb488c5b5f030a79b72.
////
//// Copyright (c) 2022 IETF Trust and the persons identified as authors of
//// draft-bhutton-json-schema-01. All rights reserved.
////
//// Redistribution and use in source and binary forms, with or without
//// modification, are permitted provided that the following conditions are met:
////
//// 1. Redistributions of source code must retain the above copyright notice,
////    this list of conditions and the following disclaimer.
//// 2. Redistributions in binary form must reproduce the above copyright notice,
////    this list of conditions and the following disclaimer in the documentation
////    and/or other materials provided with the distribution.
//// 3. Neither the name of Internet Society, IETF or IETF Trust, nor the names of
////    specific contributors, may be used to endorse or promote products derived
////    from this software without specific prior written permission.
////
//// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
//// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//// POSSIBILITY OF SUCH DAMAGE.

import gleam_mcp/json.{type JsonValue}

/// Returns the standard dialect and vocabulary metaschemas.
///
/// ## Examples
///
/// ```gleam
/// // metaschema.resources() supplies the official https://json-schema.org identities.
/// ```
pub fn resources() -> List(#(String, JsonValue)) {
  [
    #(
      "https://json-schema.org/draft/2020-12/meta/applicator",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #(
          "$id",
          json.String("https://json-schema.org/draft/2020-12/meta/applicator"),
        ),
        #("$dynamicAnchor", json.String("meta")),
        #("title", json.String("Applicator vocabulary meta-schema")),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "properties",
          json.Object([
            #(
              "prefixItems",
              json.Object([#("$ref", json.String("#/$defs/schemaArray"))]),
            ),
            #("items", json.Object([#("$dynamicRef", json.String("#meta"))])),
            #("contains", json.Object([#("$dynamicRef", json.String("#meta"))])),
            #(
              "additionalProperties",
              json.Object([#("$dynamicRef", json.String("#meta"))]),
            ),
            #(
              "properties",
              json.Object([
                #("type", json.String("object")),
                #(
                  "additionalProperties",
                  json.Object([#("$dynamicRef", json.String("#meta"))]),
                ),
                #("default", json.Object([])),
              ]),
            ),
            #(
              "patternProperties",
              json.Object([
                #("type", json.String("object")),
                #(
                  "additionalProperties",
                  json.Object([#("$dynamicRef", json.String("#meta"))]),
                ),
                #(
                  "propertyNames",
                  json.Object([#("format", json.String("regex"))]),
                ),
                #("default", json.Object([])),
              ]),
            ),
            #(
              "dependentSchemas",
              json.Object([
                #("type", json.String("object")),
                #(
                  "additionalProperties",
                  json.Object([#("$dynamicRef", json.String("#meta"))]),
                ),
                #("default", json.Object([])),
              ]),
            ),
            #(
              "propertyNames",
              json.Object([#("$dynamicRef", json.String("#meta"))]),
            ),
            #("if", json.Object([#("$dynamicRef", json.String("#meta"))])),
            #("then", json.Object([#("$dynamicRef", json.String("#meta"))])),
            #("else", json.Object([#("$dynamicRef", json.String("#meta"))])),
            #(
              "allOf",
              json.Object([#("$ref", json.String("#/$defs/schemaArray"))]),
            ),
            #(
              "anyOf",
              json.Object([#("$ref", json.String("#/$defs/schemaArray"))]),
            ),
            #(
              "oneOf",
              json.Object([#("$ref", json.String("#/$defs/schemaArray"))]),
            ),
            #("not", json.Object([#("$dynamicRef", json.String("#meta"))])),
          ]),
        ),
        #(
          "$defs",
          json.Object([
            #(
              "schemaArray",
              json.Object([
                #("type", json.String("array")),
                #("minItems", json.Int(1)),
                #(
                  "items",
                  json.Object([#("$dynamicRef", json.String("#meta"))]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "https://json-schema.org/draft/2020-12/meta/content",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #(
          "$id",
          json.String("https://json-schema.org/draft/2020-12/meta/content"),
        ),
        #("$dynamicAnchor", json.String("meta")),
        #("title", json.String("Content vocabulary meta-schema")),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "properties",
          json.Object([
            #(
              "contentEncoding",
              json.Object([#("type", json.String("string"))]),
            ),
            #(
              "contentMediaType",
              json.Object([#("type", json.String("string"))]),
            ),
            #(
              "contentSchema",
              json.Object([#("$dynamicRef", json.String("#meta"))]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "https://json-schema.org/draft/2020-12/meta/core",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #("$id", json.String("https://json-schema.org/draft/2020-12/meta/core")),
        #("$dynamicAnchor", json.String("meta")),
        #("title", json.String("Core vocabulary meta-schema")),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "properties",
          json.Object([
            #(
              "$id",
              json.Object([
                #("$ref", json.String("#/$defs/uriReferenceString")),
                #("$comment", json.String("Non-empty fragments not allowed.")),
                #("pattern", json.String("^[^#]*#?$")),
              ]),
            ),
            #(
              "$schema",
              json.Object([#("$ref", json.String("#/$defs/uriString"))]),
            ),
            #(
              "$ref",
              json.Object([#("$ref", json.String("#/$defs/uriReferenceString"))]),
            ),
            #(
              "$anchor",
              json.Object([#("$ref", json.String("#/$defs/anchorString"))]),
            ),
            #(
              "$dynamicRef",
              json.Object([#("$ref", json.String("#/$defs/uriReferenceString"))]),
            ),
            #(
              "$dynamicAnchor",
              json.Object([#("$ref", json.String("#/$defs/anchorString"))]),
            ),
            #(
              "$vocabulary",
              json.Object([
                #("type", json.String("object")),
                #(
                  "propertyNames",
                  json.Object([#("$ref", json.String("#/$defs/uriString"))]),
                ),
                #(
                  "additionalProperties",
                  json.Object([#("type", json.String("boolean"))]),
                ),
              ]),
            ),
            #("$comment", json.Object([#("type", json.String("string"))])),
            #(
              "$defs",
              json.Object([
                #("type", json.String("object")),
                #(
                  "additionalProperties",
                  json.Object([#("$dynamicRef", json.String("#meta"))]),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "$defs",
          json.Object([
            #(
              "anchorString",
              json.Object([
                #("type", json.String("string")),
                #("pattern", json.String("^[A-Za-z_][-A-Za-z0-9._]*$")),
              ]),
            ),
            #(
              "uriString",
              json.Object([
                #("type", json.String("string")),
                #("format", json.String("uri")),
              ]),
            ),
            #(
              "uriReferenceString",
              json.Object([
                #("type", json.String("string")),
                #("format", json.String("uri-reference")),
              ]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "https://json-schema.org/draft/2020-12/meta/format-annotation",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #(
          "$id",
          json.String(
            "https://json-schema.org/draft/2020-12/meta/format-annotation",
          ),
        ),
        #("$dynamicAnchor", json.String("meta")),
        #(
          "title",
          json.String("Format vocabulary meta-schema for annotation results"),
        ),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "properties",
          json.Object([
            #("format", json.Object([#("type", json.String("string"))])),
          ]),
        ),
      ]),
    ),
    #(
      "https://json-schema.org/draft/2020-12/meta/meta-data",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #(
          "$id",
          json.String("https://json-schema.org/draft/2020-12/meta/meta-data"),
        ),
        #("$dynamicAnchor", json.String("meta")),
        #("title", json.String("Meta-data vocabulary meta-schema")),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "properties",
          json.Object([
            #("title", json.Object([#("type", json.String("string"))])),
            #("description", json.Object([#("type", json.String("string"))])),
            #("default", json.Bool(True)),
            #(
              "deprecated",
              json.Object([
                #("type", json.String("boolean")),
                #("default", json.Bool(False)),
              ]),
            ),
            #(
              "readOnly",
              json.Object([
                #("type", json.String("boolean")),
                #("default", json.Bool(False)),
              ]),
            ),
            #(
              "writeOnly",
              json.Object([
                #("type", json.String("boolean")),
                #("default", json.Bool(False)),
              ]),
            ),
            #(
              "examples",
              json.Object([
                #("type", json.String("array")),
                #("items", json.Bool(True)),
              ]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "https://json-schema.org/draft/2020-12/meta/unevaluated",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #(
          "$id",
          json.String("https://json-schema.org/draft/2020-12/meta/unevaluated"),
        ),
        #("$dynamicAnchor", json.String("meta")),
        #("title", json.String("Unevaluated applicator vocabulary meta-schema")),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "properties",
          json.Object([
            #(
              "unevaluatedItems",
              json.Object([#("$dynamicRef", json.String("#meta"))]),
            ),
            #(
              "unevaluatedProperties",
              json.Object([#("$dynamicRef", json.String("#meta"))]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "https://json-schema.org/draft/2020-12/meta/validation",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #(
          "$id",
          json.String("https://json-schema.org/draft/2020-12/meta/validation"),
        ),
        #("$dynamicAnchor", json.String("meta")),
        #("title", json.String("Validation vocabulary meta-schema")),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "properties",
          json.Object([
            #(
              "type",
              json.Object([
                #(
                  "anyOf",
                  json.Array([
                    json.Object([#("$ref", json.String("#/$defs/simpleTypes"))]),
                    json.Object([
                      #("type", json.String("array")),
                      #(
                        "items",
                        json.Object([
                          #("$ref", json.String("#/$defs/simpleTypes")),
                        ]),
                      ),
                      #("minItems", json.Int(1)),
                      #("uniqueItems", json.Bool(True)),
                    ]),
                  ]),
                ),
              ]),
            ),
            #("const", json.Bool(True)),
            #(
              "enum",
              json.Object([
                #("type", json.String("array")),
                #("items", json.Bool(True)),
              ]),
            ),
            #(
              "multipleOf",
              json.Object([
                #("type", json.String("number")),
                #("exclusiveMinimum", json.Int(0)),
              ]),
            ),
            #("maximum", json.Object([#("type", json.String("number"))])),
            #(
              "exclusiveMaximum",
              json.Object([#("type", json.String("number"))]),
            ),
            #("minimum", json.Object([#("type", json.String("number"))])),
            #(
              "exclusiveMinimum",
              json.Object([#("type", json.String("number"))]),
            ),
            #(
              "maxLength",
              json.Object([#("$ref", json.String("#/$defs/nonNegativeInteger"))]),
            ),
            #(
              "minLength",
              json.Object([
                #("$ref", json.String("#/$defs/nonNegativeIntegerDefault0")),
              ]),
            ),
            #(
              "pattern",
              json.Object([
                #("type", json.String("string")),
                #("format", json.String("regex")),
              ]),
            ),
            #(
              "maxItems",
              json.Object([#("$ref", json.String("#/$defs/nonNegativeInteger"))]),
            ),
            #(
              "minItems",
              json.Object([
                #("$ref", json.String("#/$defs/nonNegativeIntegerDefault0")),
              ]),
            ),
            #(
              "uniqueItems",
              json.Object([
                #("type", json.String("boolean")),
                #("default", json.Bool(False)),
              ]),
            ),
            #(
              "maxContains",
              json.Object([#("$ref", json.String("#/$defs/nonNegativeInteger"))]),
            ),
            #(
              "minContains",
              json.Object([
                #("$ref", json.String("#/$defs/nonNegativeInteger")),
                #("default", json.Int(1)),
              ]),
            ),
            #(
              "maxProperties",
              json.Object([#("$ref", json.String("#/$defs/nonNegativeInteger"))]),
            ),
            #(
              "minProperties",
              json.Object([
                #("$ref", json.String("#/$defs/nonNegativeIntegerDefault0")),
              ]),
            ),
            #(
              "required",
              json.Object([#("$ref", json.String("#/$defs/stringArray"))]),
            ),
            #(
              "dependentRequired",
              json.Object([
                #("type", json.String("object")),
                #(
                  "additionalProperties",
                  json.Object([#("$ref", json.String("#/$defs/stringArray"))]),
                ),
              ]),
            ),
          ]),
        ),
        #(
          "$defs",
          json.Object([
            #(
              "nonNegativeInteger",
              json.Object([
                #("type", json.String("integer")),
                #("minimum", json.Int(0)),
              ]),
            ),
            #(
              "nonNegativeIntegerDefault0",
              json.Object([
                #("$ref", json.String("#/$defs/nonNegativeInteger")),
                #("default", json.Int(0)),
              ]),
            ),
            #(
              "simpleTypes",
              json.Object([
                #(
                  "enum",
                  json.Array([
                    json.String("array"),
                    json.String("boolean"),
                    json.String("integer"),
                    json.String("null"),
                    json.String("number"),
                    json.String("object"),
                    json.String("string"),
                  ]),
                ),
              ]),
            ),
            #(
              "stringArray",
              json.Object([
                #("type", json.String("array")),
                #("items", json.Object([#("type", json.String("string"))])),
                #("uniqueItems", json.Bool(True)),
                #("default", json.Array([])),
              ]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "https://json-schema.org/draft/2020-12/schema",
      json.Object([
        #(
          "$schema",
          json.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        #("$id", json.String("https://json-schema.org/draft/2020-12/schema")),
        #(
          "$vocabulary",
          json.Object([
            #(
              "https://json-schema.org/draft/2020-12/vocab/core",
              json.Bool(True),
            ),
            #(
              "https://json-schema.org/draft/2020-12/vocab/applicator",
              json.Bool(True),
            ),
            #(
              "https://json-schema.org/draft/2020-12/vocab/unevaluated",
              json.Bool(True),
            ),
            #(
              "https://json-schema.org/draft/2020-12/vocab/validation",
              json.Bool(True),
            ),
            #(
              "https://json-schema.org/draft/2020-12/vocab/meta-data",
              json.Bool(True),
            ),
            #(
              "https://json-schema.org/draft/2020-12/vocab/format-annotation",
              json.Bool(True),
            ),
            #(
              "https://json-schema.org/draft/2020-12/vocab/content",
              json.Bool(True),
            ),
          ]),
        ),
        #("$dynamicAnchor", json.String("meta")),
        #(
          "title",
          json.String("Core and Validation specifications meta-schema"),
        ),
        #(
          "allOf",
          json.Array([
            json.Object([#("$ref", json.String("meta/core"))]),
            json.Object([#("$ref", json.String("meta/applicator"))]),
            json.Object([#("$ref", json.String("meta/unevaluated"))]),
            json.Object([#("$ref", json.String("meta/validation"))]),
            json.Object([#("$ref", json.String("meta/meta-data"))]),
            json.Object([#("$ref", json.String("meta/format-annotation"))]),
            json.Object([#("$ref", json.String("meta/content"))]),
          ]),
        ),
        #("type", json.Array([json.String("object"), json.String("boolean")])),
        #(
          "$comment",
          json.String(
            "This meta-schema also defines keywords that have appeared in previous drafts in order to prevent incompatible extensions as they remain in common use.",
          ),
        ),
        #(
          "properties",
          json.Object([
            #(
              "definitions",
              json.Object([
                #(
                  "$comment",
                  json.String("\"definitions\" has been replaced by \"$defs\"."),
                ),
                #("type", json.String("object")),
                #(
                  "additionalProperties",
                  json.Object([#("$dynamicRef", json.String("#meta"))]),
                ),
                #("deprecated", json.Bool(True)),
                #("default", json.Object([])),
              ]),
            ),
            #(
              "dependencies",
              json.Object([
                #(
                  "$comment",
                  json.String(
                    "\"dependencies\" has been split and replaced by \"dependentSchemas\" and \"dependentRequired\" in order to serve their differing semantics.",
                  ),
                ),
                #("type", json.String("object")),
                #(
                  "additionalProperties",
                  json.Object([
                    #(
                      "anyOf",
                      json.Array([
                        json.Object([#("$dynamicRef", json.String("#meta"))]),
                        json.Object([
                          #(
                            "$ref",
                            json.String("meta/validation#/$defs/stringArray"),
                          ),
                        ]),
                      ]),
                    ),
                  ]),
                ),
                #("deprecated", json.Bool(True)),
                #("default", json.Object([])),
              ]),
            ),
            #(
              "$recursiveAnchor",
              json.Object([
                #(
                  "$comment",
                  json.String(
                    "\"$recursiveAnchor\" has been replaced by \"$dynamicAnchor\".",
                  ),
                ),
                #("$ref", json.String("meta/core#/$defs/anchorString")),
                #("deprecated", json.Bool(True)),
              ]),
            ),
            #(
              "$recursiveRef",
              json.Object([
                #(
                  "$comment",
                  json.String(
                    "\"$recursiveRef\" has been replaced by \"$dynamicRef\".",
                  ),
                ),
                #("$ref", json.String("meta/core#/$defs/uriReferenceString")),
                #("deprecated", json.Bool(True)),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ]
}
