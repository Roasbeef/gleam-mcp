//// Schema compilation validates keyword shapes and indexes resource identities.
//// References resolve exclusively against this immutable registry; a schema never
//// gains network authority from a URI embedded in an untrusted tool definition.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import gleam/uri
import gleam_mcp/internal/schema/metaschema
import gleam_mcp/internal/schema/number
import gleam_mcp/internal/schema/pattern
import gleam_mcp/internal/schema/value
import gleam_mcp/json.{type JsonValue}

/// A schema location and the resource base inherited by references beneath it.
pub type Node {
  Node(
    /// The schema at this location.
    schema: JsonValue,
    /// The absolute resource URI used to resolve relative references.
    base: String,
    /// The pointer used to distinguish locations within the indexed tree.
    location: String,
  )
}

/// A checked schema and the complete offline registry available to evaluation.
pub type Document {
  /// The original root and the registry admitted in the same compilation pass.
  Document(
    /// The original document, including unknown annotations.
    root: JsonValue,
    /// The root location after resolving its identifier.
    entry: Node,
    /// Resource URI lookup; each target is available without I/O.
    resources: Dict(String, Node),
    /// Absolute anchor URI lookup, including dynamic anchors.
    anchors: Dict(String, Node),
    /// Enabled vocabularies for each schema resource.
    vocabularies: Dict(String, List(String)),
  )
}

/// Compilation failures distinguish malformed schemas from unsupported dialects.
pub type Error {
  /// A malformed keyword, ambiguous identity, or unresolved reference.
  Invalid(reason: String)

  /// A dialect absent from the explicitly supplied offline registry.
  Dialect(name: String)

  /// The document exceeded the compilation work allowance.
  Limit
}

type Build {
  Build(
    resources: Dict(String, Node),
    anchors: Dict(String, Node),
    refs: List(#(Node, String)),
    remaining: Int,
    indexed: Dict(#(String, String), Nil),
    dialects: Dict(String, JsonValue),
    vocabularies: Dict(String, List(String)),
  )
}

const default_base = "https://gleam-mcp.invalid/root"

const dialect = "https://json-schema.org/draft/2020-12/schema"

/// Compiles a document with no caller-provided external resources.
///
/// ## Examples
///
/// ```gleam
/// assert document.new(json.Bool(True)) |> result.is_ok
/// ```
pub fn new(root: JsonValue) -> Result(Document, Error) {
  new_with_resources(root, [])
}

/// Compiles with an explicit offline registry, used by the conformance harness.
///
/// ## Examples
///
/// ```gleam
/// // document.new_with_resources(root, [(uri, resource)]) never fetches a URI.
/// ```
pub fn new_with_resources(
  root: JsonValue,
  resources: List(#(String, JsonValue)),
) -> Result(Document, Error) {
  let resources = list.append(metaschema.resources(), resources)
  use _ <- result.try(bounded(root, 0, 100_000))

  // Only explicit resources contribute custom dialects. A URI in the root
  // cannot cause compilation to retrieve a metaschema or change authority.
  let dialects =
    resources
    |> list.filter_map(fn(pair) {
      value.get(pair.1, "$vocabulary")
      |> result.map(fn(vocabularies) { #(pair.0, vocabularies) })
    })
    |> dict.from_list
  let state =
    Build(dict.new(), dict.new(), [], 10_000, dict.new(), dialects, dict.new())
  let entry = Node(root, default_base, "")
  use state <- result.try(index(entry, state, 0))

  // References may point into otherwise unknown annotation values. Resolve
  // and compile that reachable closure after indexing ordinary subschemas.
  use state <- result.try(load_references(state, resources, state.refs))
  let entry = enter(entry)
  let document =
    Document(root, entry, state.resources, state.anchors, state.vocabularies)
  use _ <- result.try(
    list.try_each(state.refs, fn(reference) {
      resolve(document, reference.0, reference.1) |> result.map(fn(_) { Nil })
    }),
  )
  Ok(document)
}

fn load_references(
  state: Build,
  available: List(#(String, JsonValue)),
  pending: List(#(Node, String)),
) -> Result(Build, Error) {
  case pending {
    [] -> Ok(state)
    [reference, ..rest] -> {
      use uri <- result.try(absolute(reference.0.base, reference.1))
      let resource = strip_fragment(uri)
      use loaded <- result.try(ensure_resource(state, available, resource))
      let document =
        Document(
          reference.0.schema,
          reference.0,
          loaded.resources,
          loaded.anchors,
          loaded.vocabularies,
        )
      use target <- result.try(resolve(document, reference.0, reference.1))
      use indexed <- result.try(index_effective(target, target, loaded, 0))
      let added =
        list.take(
          indexed.refs,
          list.length(indexed.refs) - list.length(state.refs),
        )
      load_references(indexed, available, list.append(added, rest))
    }
  }
}

fn ensure_resource(
  state: Build,
  available: List(#(String, JsonValue)),
  resource: String,
) -> Result(Build, Error) {
  case dict.has_key(state.resources, resource) {
    True -> Ok(state)
    False -> {
      use schema <- result.try(
        list.key_find(available, resource)
        |> result.map_error(fn(_) {
          Invalid("unresolved schema resource: " <> resource)
        }),
      )
      use _ <- result.try(bounded(schema, 0, 100_000))
      index(Node(schema, resource, ""), state, 0)
    }
  }
}

/// Bounds all input data, including unknown annotation values and instances.
///
/// ## Examples
///
/// ```gleam
/// assert document.bounded(json.Null, 0, 10) == Ok(9)
/// ```
pub fn bounded(
  data: JsonValue,
  depth: Int,
  remaining: Int,
) -> Result(Int, Error) {
  case depth > 128 || remaining <= 0 {
    True -> Error(Limit)
    False -> bounded_value(data, depth, remaining - 1)
  }
}

fn bounded_value(
  data: JsonValue,
  depth: Int,
  remaining: Int,
) -> Result(Int, Error) {
  case data {
    json.Array(items) ->
      list.try_fold(items, remaining, fn(left, item) {
        bounded(item, depth + 1, left)
      })
    json.Object(fields) -> {
      let names = list.map(fields, fn(pair) { pair.0 })
      case list.length(list.unique(names)) == list.length(names) {
        False -> Error(Invalid("duplicate object field"))
        True ->
          list.try_fold(fields, remaining, fn(left, pair) {
            use left <- result.try(bounded(json.String(pair.0), depth + 1, left))
            bounded(pair.1, depth + 1, left)
          })
      }
    }
    json.String(text) -> charge(remaining, string.byte_size(text))
    json.Int(n) -> charge(remaining, string.byte_size(int.to_string(n)))
    _ -> Ok(remaining)
  }
}

fn charge(remaining: Int, bytes: Int) -> Result(Int, Error) {
  case remaining - bytes / 32 {
    left if left >= 0 -> Ok(left)
    _ -> Error(Limit)
  }
}

fn index(node: Node, state: Build, depth: Int) -> Result(Build, Error) {
  case depth > 128 || state.remaining <= 0 {
    True -> Error(Limit)
    False ->
      index_node(node, Build(..state, remaining: state.remaining - 1), depth)
  }
}

fn index_node(
  original: Node,
  state: Build,
  depth: Int,
) -> Result(Build, Error) {
  use _ <- result.try(case value.get(original.schema, "$id") {
    Ok(json.String(id)) ->
      absolute(original.base, id) |> result.map(fn(_) { Nil })
    _ -> Ok(Nil)
  })
  index_effective(original, enter(original), state, depth)
}

fn index_effective(
  original: Node,
  node: Node,
  state: Build,
  depth: Int,
) -> Result(Build, Error) {
  let key = #(node.base, node.location)

  // The schema graph may be cyclic even though the JSON tree is finite. Each
  // location is compiled once; recursive instance evaluation has its own budget.
  case dict.has_key(state.indexed, key) {
    True -> Ok(state)
    False ->
      index_new(
        original,
        node,
        Build(..state, indexed: dict.insert(state.indexed, key, Nil)),
        depth,
      )
  }
}

fn index_new(
  original: Node,
  node: Node,
  state: Build,
  depth: Int,
) -> Result(Build, Error) {
  use _ <- result.try(case value.get(original.schema, "$schema") {
    Ok(_) if original.location != "" ->
      require(
        fn() { result.is_ok(value.get(original.schema, "$id")) },
        "$schema outside a resource root",
      )
    _ -> Ok(Nil)
  })
  use vocabularies <- result.try(node_vocabularies(original, state))
  use _ <- result.try(check_schema(original.schema, vocabularies))
  let state =
    Build(
      ..state,
      vocabularies: dict.insert(state.vocabularies, node.base, vocabularies),
    )
  use _ <- result.try(
    case value.get(node.schema, "$id"), dict.get(state.resources, node.base) {
      Ok(_), Ok(existing) if existing != node && existing.base == node.base ->
        Error(Invalid("duplicate schema resource identifier"))
      _, _ -> Ok(Nil)
    },
  )

  // A retrieval URI is an alias for a root with its own $id. Keeping both
  // makes external registry names and canonical resource names interchangeable.
  let resources = case original.location == "" || node.base != original.base {
    True -> dict.insert(state.resources, node.base, node)
    False -> state.resources
  }
  let resources = case original.location == "" {
    True -> dict.insert(resources, original.base, node)
    False -> resources
  }
  let state = Build(..state, resources: resources)
  use state <- result.try(
    list.try_fold(["$anchor", "$dynamicAnchor"], state, fn(state, keyword) {
      register_anchor(state, node, keyword)
    }),
  )
  let refs =
    list.filter_map(["$ref", "$dynamicRef"], fn(keyword) {
      case value.get(node.schema, keyword) {
        Ok(json.String(reference)) -> Ok(#(node, reference))
        _ -> Error(Nil)
      }
    })
  let state = Build(..state, refs: list.append(refs, state.refs))
  list.try_fold(children(node, vocabularies), state, fn(state, child) {
    index(child, state, depth + 1)
  })
}

fn register_anchor(
  state: Build,
  node: Node,
  keyword: String,
) -> Result(Build, Error) {
  case value.get(node.schema, keyword) {
    Ok(json.String(anchor)) -> {
      let key = node.base <> "#" <> anchor
      case dict.get(state.anchors, key) {
        Ok(existing) if existing != node ->
          Error(Invalid("duplicate schema anchor: " <> anchor))
        _ -> Ok(Build(..state, anchors: dict.insert(state.anchors, key, node)))
      }
    }
    _ -> Ok(state)
  }
}

/// Applies a location's resource identifier before evaluating its keywords.
///
/// ## Examples
///
/// ```gleam
/// // document.enter(node) resolves a local $id against the inherited base.
/// ```
pub fn enter(node: Node) -> Node {
  case value.get(node.schema, "$id") {
    Ok(json.String(id)) -> {
      let base = absolute(node.base, id) |> result.unwrap(node.base)
      Node(node.schema, strip_fragment(base), node.location)
    }
    _ -> node
  }
}

/// Creates a child location while preserving the current resource's scope.
///
/// ## Examples
///
/// ```gleam
/// // document.child(parent, schema, "/properties/name") inherits parent.base.
/// ```
pub fn child(parent: Node, schema: JsonValue, suffix: String) -> Node {
  Node(schema, parent.base, parent.location <> suffix)
}

fn children(node: Node, vocabularies: List(String)) -> List(Node) {
  let singles = [
    "items",
    "contains",
    "additionalProperties",
    "propertyNames",
    "unevaluatedProperties",
    "unevaluatedItems",
    "not",
    "if",
    "then",
    "else",
    "contentSchema",
  ]
  let maps = [
    "properties",
    "patternProperties",
    "dependentSchemas",
    "$defs",
    "definitions",
  ]
  let arrays = ["prefixItems", "allOf", "anyOf", "oneOf"]
  let first =
    list.filter_map(singles, fn(key) {
      value.get(node.schema, key)
      |> result.map(fn(schema) { child(node, schema, "/" <> key) })
    })
  let second =
    list.flat_map(maps, fn(key) {
      value.field(node.schema, key, json.Object([]))
      |> value.fields
      |> list.map(fn(pair) {
        child(node, pair.1, "/" <> key <> "/" <> escape(pair.0))
      })
    })
  let third =
    list.flat_map(arrays, fn(key) {
      value.field(node.schema, key, json.Array([]))
      |> value.items
      |> list.index_map(fn(schema, index) {
        child(node, schema, "/" <> key <> "/" <> int.to_string(index))
      })
    })
  list.flatten([first, second, third])
  |> list.filter(fn(child) {
    let keyword =
      string.drop_start(child.location, string.length(node.location) + 1)
      |> string.split("/")
      |> list.first
      |> result.unwrap("")
    list.contains(vocabularies, vocabulary_for(keyword))
  })
}

/// Encodes one JSON Pointer segment.
///
/// ## Examples
///
/// ```gleam
/// assert document.escape("a/b") == "a~1b"
/// ```
pub fn escape(segment: String) -> String {
  segment |> string.replace("~", "~0") |> string.replace("/", "~1")
}

/// Resolves a reference from the immutable offline registry.
///
/// ## Examples
///
/// ```gleam
/// // document.resolve(compiled, compiled.entry, "#/$defs/value") returns its node.
/// ```
pub fn resolve(
  document: Document,
  from: Node,
  reference: String,
) -> Result(Node, Error) {
  use absolute <- result.try(absolute(from.base, reference))
  let resource = strip_fragment(absolute)
  let fragment = string.split(absolute, "#") |> value.at(1) |> result.unwrap("")
  use fragment <- result.try(
    uri.percent_decode(fragment)
    |> result.map_error(fn(_) { Invalid("invalid reference escape") }),
  )
  case fragment {
    "" ->
      dict.get(document.resources, resource)
      |> result.map_error(fn(_) {
        Invalid("unresolved schema resource: " <> resource)
      })
    "/" <> path -> {
      use root <- result.try(
        dict.get(document.resources, resource)
        |> result.map_error(fn(_) {
          Invalid("unresolved schema resource: " <> resource)
        }),
      )
      pointer(root, string.split(path, "/"))
    }
    _ ->
      dict.get(document.anchors, resource <> "#" <> fragment)
      |> result.map_error(fn(_) {
        Invalid("unresolved schema anchor: " <> fragment)
      })
  }
}

fn pointer(node: Node, segments: List(String)) -> Result(Node, Error) {
  case segments {
    [] ->
      case node.schema {
        json.Object(_) | json.Bool(_) -> Ok(node)
        _ -> Error(Invalid("reference target is not a schema"))
      }
    [segment, ..rest] -> {
      use _ <- result.try(require(
        fn() {
          segment
          |> string.replace("~1", "")
          |> string.replace("~0", "")
          |> string.contains("~")
          |> fn(invalid) { !invalid }
        },
        "JSON Pointer escape",
      ))
      let key =
        segment |> string.replace("~1", "/") |> string.replace("~0", "~")
      use schema <- result.try(pointer_member(node.schema, key))
      pointer(enter(child(node, schema, "/" <> segment)), rest)
    }
  }
}

fn pointer_member(schema: JsonValue, key: String) -> Result(JsonValue, Error) {
  let found = case schema {
    json.Object(fields) -> list.key_find(fields, key)
    json.Array(items) -> {
      use index <- result.try(int.parse(key))
      case int.to_string(index) == key && index >= 0 {
        True -> value.at(items, index)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
  found |> result.map_error(fn(_) { Invalid("unresolved schema pointer") })
}

/// Resolves a URI reference without performing I/O.
///
/// ## Examples
///
/// ```gleam
/// assert document.absolute("https://example.com/a", "#x") == Ok("https://example.com/a#x")
/// ```
pub fn absolute(base: String, reference: String) -> Result(String, Error) {
  use parsed <- result.try(
    uri.parse(reference)
    |> result.map_error(fn(_) { Invalid("invalid schema URI") }),
  )
  case parsed.scheme, reference {
    Some(_), _ -> Ok(reference)
    None, "#" <> _ -> Ok(strip_fragment(base) <> reference)
    None, "" -> Ok(strip_fragment(base))
    None, _ -> {
      use base <- result.try(
        uri.parse(base)
        |> result.map_error(fn(_) { Invalid("invalid schema base URI") }),
      )
      uri.merge(base, parsed)
      |> result.map(fn(merged) {
        let path = case
          string.ends_with(parsed.path, "/")
          && !string.ends_with(merged.path, "/")
        {
          True -> merged.path <> "/"
          False -> merged.path
        }
        uri.to_string(uri.Uri(..merged, path: path))
      })
      |> result.map_error(fn(_) {
        Invalid("cannot resolve relative schema URI")
      })
    }
  }
}

fn strip_fragment(uri: String) -> String {
  string.split(uri, "#") |> list.first |> result.unwrap(uri)
}

fn check_schema(
  schema: JsonValue,
  vocabularies: List(String),
) -> Result(Nil, Error) {
  case schema {
    json.Bool(_) -> Ok(Nil)
    json.Object(fields) ->
      list.try_each(fields, fn(pair) {
        case list.contains(vocabularies, vocabulary_for(pair.0)) {
          True -> check_keyword(pair.0, pair.1)
          False -> Ok(Nil)
        }
      })
    _ -> Error(Invalid("schema must be an object or boolean"))
  }
}

fn check_keyword(key: String, data: JsonValue) -> Result(Nil, Error) {
  case key {
    "$schema" -> require_string(key, data)
    "$id" -> check_id(data)
    "$anchor" | "$dynamicAnchor" -> check_anchor(data)
    "$ref"
    | "$dynamicRef"
    | "$comment"
    | "title"
    | "description"
    | "format"
    | "contentEncoding"
    | "contentMediaType" -> require_string(key, data)
    "pattern" -> check_pattern(data)
    "type" -> check_type(data)
    "enum" ->
      case data {
        json.Array(_) -> Ok(Nil)
        _ -> invalid(key)
      }
    "multipleOf" ->
      require(fn() { number.compare(data, json.Int(0)) == Ok(1) }, key)
    "minimum" | "maximum" | "exclusiveMinimum" | "exclusiveMaximum" ->
      require(fn() { result.is_ok(number.from_json(data)) }, key)
    "minLength"
    | "maxLength"
    | "minItems"
    | "maxItems"
    | "minContains"
    | "maxContains"
    | "minProperties"
    | "maxProperties" ->
      require(
        fn() {
          number.is_integer(data) && number.compare(data, json.Int(0)) != Ok(-1)
        },
        key,
      )
    "required" -> check_strings(data, key)
    "uniqueItems" | "deprecated" | "readOnly" | "writeOnly" ->
      case data {
        json.Bool(_) -> Ok(Nil)
        _ -> invalid(key)
      }
    "properties" | "patternProperties" | "$defs" | "dependentSchemas" ->
      check_map(data, key)
    "dependentRequired" ->
      case data {
        json.Object(fields) ->
          list.try_each(fields, fn(pair) { check_strings(pair.1, key) })
        _ -> invalid(key)
      }
    "prefixItems" | "allOf" | "anyOf" | "oneOf" ->
      case data {
        json.Array([_, ..]) -> Ok(Nil)
        _ -> invalid(key)
      }
    "$vocabulary" -> check_vocabulary(data)
    "examples" ->
      case data {
        json.Array(_) -> Ok(Nil)
        _ -> invalid(key)
      }
    _ -> Ok(Nil)
  }
}

fn check_map(data: JsonValue, key: String) -> Result(Nil, Error) {
  case data {
    json.Object(fields) if key == "patternProperties" ->
      list.try_each(fields, fn(pair) { check_pattern(json.String(pair.0)) })
    json.Object(_) -> Ok(Nil)
    _ -> invalid(key)
  }
}

fn check_id(data: JsonValue) -> Result(Nil, Error) {
  case data {
    json.String(id) -> {
      use parsed <- result.try(
        uri.parse(id) |> result.map_error(fn(_) { Invalid("invalid $id URI") }),
      )
      require(
        fn() { parsed.fragment == None || parsed.fragment == Some("") },
        "$id",
      )
    }
    _ -> invalid("$id")
  }
}

fn check_anchor(data: JsonValue) -> Result(Nil, Error) {
  case data {
    json.String(anchor) -> {
      use regex <- result.try(
        regexp.from_string("^[A-Za-z_][-A-Za-z0-9._]*$")
        |> result.map_error(fn(_) { Invalid("anchor grammar unavailable") }),
      )
      require(fn() { regexp.check(regex, anchor) }, "$anchor")
    }
    _ -> invalid("$anchor")
  }
}

fn check_pattern(data: JsonValue) -> Result(Nil, Error) {
  case data {
    json.String(pattern) ->
      pattern.compile(pattern)
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(_) { Invalid("invalid regular expression") })
    _ -> invalid("pattern")
  }
}

fn check_type(data: JsonValue) -> Result(Nil, Error) {
  case data {
    json.String(name) ->
      require(
        fn() {
          list.contains(
            [
              "null",
              "boolean",
              "object",
              "array",
              "number",
              "integer",
              "string",
            ],
            name,
          )
        },
        "type",
      )
    json.Array([_, ..] as types) -> {
      use _ <- result.try(require(fn() { value.unique(types) }, "type"))
      list.try_each(types, fn(data) {
        case data {
          json.String(_) -> check_type(data)
          _ -> invalid("type")
        }
      })
    }
    _ -> invalid("type")
  }
}

fn check_strings(data: JsonValue, key: String) -> Result(Nil, Error) {
  case data {
    json.Array(items) -> {
      use _ <- result.try(require(fn() { value.unique(items) }, key))
      list.try_each(items, require_string(key, _))
    }
    _ -> invalid(key)
  }
}

fn require_string(key: String, data: JsonValue) -> Result(Nil, Error) {
  case data {
    json.String(_) -> Ok(Nil)
    _ -> invalid(key)
  }
}

fn check_vocabulary(data: JsonValue) -> Result(Nil, Error) {
  let supported = [
    "core",
    "applicator",
    "validation",
    "meta-data",
    "format-annotation",
    "content",
    "unevaluated",
  ]
  case data {
    json.Object(fields) ->
      list.try_each(fields, fn(pair) {
        case pair.1 {
          json.Bool(False) -> Ok(Nil)
          json.Bool(True) ->
            require(
              fn() {
                list.any(supported, fn(name) {
                  pair.0
                  == "https://json-schema.org/draft/2020-12/vocab/" <> name
                })
              },
              "$vocabulary",
            )
          _ -> invalid("$vocabulary")
        }
      })
    _ -> invalid("$vocabulary")
  }
}

fn require(condition: fn() -> Bool, keyword: String) -> Result(Nil, Error) {
  case condition() {
    True -> Ok(Nil)
    False -> invalid(keyword)
  }
}

fn invalid(keyword: String) -> Result(a, Error) {
  Error(Invalid("invalid schema keyword: " <> keyword))
}

/// Builds a serializable array schema with a separate element resource.
///
/// ## Examples
///
/// ```gleam
/// // document.array_schema(compiled) preserves compiled.entry.base for local references.
/// ```
pub fn array_schema(document: Document) -> JsonValue {
  case document.root {
    json.Bool(_) ->
      json.Object([#("type", json.String("array")), #("items", document.root)])
    json.Object(fields) -> {
      let fields = list.filter(fields, fn(pair) { pair.0 != "$id" })
      let element =
        json.Object([#("$id", json.String(document.entry.base)), ..fields])
      let root_id = unused_array_id(document.resources, 0)
      json.Object([
        #("$id", json.String(root_id)),
        #("type", json.String("array")),
        #("items", json.Object([#("$ref", json.String(document.entry.base))])),
        #("$defs", json.Object([#("element", element)])),
      ])
    }
    _ -> json.Bool(False)
  }
}

fn unused_array_id(resources: Dict(String, Node), index: Int) -> String {
  let candidate = default_base <> "/array/" <> int.to_string(index)
  case dict.has_key(resources, candidate) {
    True -> unused_array_id(resources, index + 1)
    False -> candidate
  }
}

const default_vocabularies = [
  "core",
  "applicator",
  "validation",
  "meta-data",
  "format-annotation",
  "content",
  "unevaluated",
]

fn node_vocabularies(node: Node, state: Build) -> Result(List(String), Error) {
  case value.get(node.schema, "$schema") {
    Error(_) ->
      Ok(
        dict.get(state.vocabularies, node.base)
        |> result.unwrap(default_vocabularies),
      )
    Ok(json.String(name)) if name == dialect || name == dialect <> "#" ->
      Ok(default_vocabularies)
    Ok(json.String(name)) -> {
      use vocabularies <- result.try(
        dict.get(state.dialects, name)
        |> result.map_error(fn(_) { Dialect(name) }),
      )
      use _ <- result.try(check_vocabulary(vocabularies))
      Ok(
        value.fields(vocabularies)
        |> list.filter_map(fn(pair) {
          let short =
            string.replace(
              pair.0,
              "https://json-schema.org/draft/2020-12/vocab/",
              "",
            )
          case list.contains(default_vocabularies, short) {
            True -> Ok(short)
            False -> Error(Nil)
          }
        }),
      )
    }
    _ -> invalid("$schema")
  }
}

fn vocabulary_for(keyword: String) -> String {
  case keyword {
    "type"
    | "const"
    | "enum"
    | "multipleOf"
    | "maximum"
    | "minimum"
    | "exclusiveMaximum"
    | "exclusiveMinimum"
    | "maxLength"
    | "minLength"
    | "pattern"
    | "maxItems"
    | "minItems"
    | "uniqueItems"
    | "maxContains"
    | "minContains"
    | "maxProperties"
    | "minProperties"
    | "required"
    | "dependentRequired" -> "validation"
    "prefixItems"
    | "items"
    | "contains"
    | "additionalProperties"
    | "properties"
    | "patternProperties"
    | "dependentSchemas"
    | "propertyNames"
    | "if"
    | "then"
    | "else"
    | "allOf"
    | "anyOf"
    | "oneOf"
    | "not" -> "applicator"
    "unevaluatedItems" | "unevaluatedProperties" -> "unevaluated"
    "title"
    | "description"
    | "default"
    | "deprecated"
    | "readOnly"
    | "writeOnly"
    | "examples" -> "meta-data"
    "format" -> "format-annotation"
    "contentEncoding" | "contentMediaType" | "contentSchema" -> "content"
    _ -> "core"
  }
}

/// Reports whether a resource's declared dialect enables a known vocabulary.
///
/// ## Examples
///
/// ```gleam
/// // document.enabled(compiled, compiled.entry, "validation") checks assertions.
/// ```
pub fn enabled(document: Document, node: Node, vocabulary: String) -> Bool {
  dict.get(document.vocabularies, node.base)
  |> result.unwrap(default_vocabularies)
  |> list.contains(vocabulary)
}
