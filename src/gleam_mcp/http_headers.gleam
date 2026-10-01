//// HTTP metadata is a compiled property-path plan, never caller-selected values.
//// Compiling a listing refuses annotations outside statically reachable object
//// properties. Rendering and validating use the same plan before any effect.
////
//// ## Flow
////
//// compile -> walk -> annotation collects reachable properties, then unique
//// rejects case-insensitive header collisions. headers -> at -> primitive renders
//// values with encode_value. validate derives those same values and compares them
//// with get -> decode_value, also refusing a header for a missing or null argument.
////
//// The plan retains property paths rather than user-selected header values. Schema
//// branches, arrays and dynamic properties cannot supply an ambiguous mirror;
//// annotations under those locations are refused during compilation.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/json.{type JsonValue}

/// A validated collection of primitive property paths.
pub opaque type Plan {
  /// The compiled mirror plan, constructed only after annotation admission.
  Plan(
    /// Unique header names tied to statically reachable primitive property paths.
    entries: List(Entry),
  )
}

type Primitive {
  Text
  Integer
  Boolean
}

type Entry {
  Entry(name: String, path: List(String), kind: Primitive)
}

/// Compiles the annotation subset of a tool input schema.
///
/// ## Examples
///
/// ```gleam
/// assert http_headers.compile(json.Object([])) |> result.is_ok
/// ```
pub fn compile(schema: JsonValue) -> Result(Plan, String) {
  use entries <- result.try(walk(schema, [], []))
  use Nil <- result.try(unique(entries, []))
  Ok(Plan(entries))
}

// Only properties add a statically addressable argument path. Other branches
// are inspected for forbidden annotations, not interpreted as header sources.
fn walk(
  value: JsonValue,
  path: List(String),
  entries: List(Entry),
) -> Result(List(Entry), String) {
  case value {
    json.Object(fields) -> {
      use entries <- result.try(annotation(fields, path, entries))
      list.try_fold(fields, entries, fn(acc, field) {
        let #(key, child) = field
        case key, child {
          "properties", json.Object(properties) ->
            list.try_fold(properties, acc, fn(acc, property) {
              let #(name, schema) = property
              walk(schema, list.append(path, [name]), acc)
            })
          "x-mcp-header", _ -> Ok(acc)
          _, child ->
            case contains_annotation(child) {
              True ->
                Error("x-mcp-header must be reachable only through properties")
              False -> Ok(acc)
            }
        }
      })
    }
    _ -> Ok(entries)
  }
}

// A header binding must identify a non-root primitive with one static type.
// Rejecting ambiguous bindings here keeps runtime mirroring deterministic.
fn annotation(
  fields: List(#(String, JsonValue)),
  path: List(String),
  entries: List(Entry),
) -> Result(List(Entry), String) {
  case list.key_find(fields, "x-mcp-header") {
    Error(_) -> Ok(entries)
    Ok(json.String(name)) -> {
      use Nil <- result.try(case path != [] && valid_token(name) {
        True -> Ok(Nil)
        False -> Error("invalid x-mcp-header token or root annotation")
      })
      use kind <- result.try(case list.key_find(fields, "type") {
        Ok(json.String("string")) -> Ok(Text)
        Ok(json.String("integer")) -> Ok(Integer)
        Ok(json.String("boolean")) -> Ok(Boolean)
        _ -> Error("x-mcp-header requires string, integer, or boolean")
      })
      Ok([Entry(name, path, kind), ..entries])
    }
    Ok(_) -> Error("x-mcp-header must be a string")
  }
}

fn contains_annotation(value: JsonValue) -> Bool {
  case value {
    json.Object(fields) ->
      list.any(fields, fn(field) {
        let #(name, value) = field
        name == "x-mcp-header" || contains_annotation(value)
      })
    json.Array(values) -> list.any(values, contains_annotation)
    _ -> False
  }
}

fn unique(entries: List(Entry), seen: List(String)) -> Result(Nil, String) {
  case entries {
    [] -> Ok(Nil)
    [entry, ..rest] -> {
      let name = string.lowercase(entry.name)
      case list.contains(seen, name) {
        True -> Error("duplicate case-insensitive x-mcp-header")
        False -> unique(rest, [name, ..seen])
      }
    }
  }
}

/// Checks RFC 9110 token syntax without accepting non-ASCII text.
///
/// ## Examples
///
/// ```gleam
/// assert http_headers.valid_token("Tenant-Id")
/// assert !http_headers.valid_token("Tenant Id")
/// ```
pub fn valid_token(value: String) -> Bool {
  value != "" && token_bytes(<<value:utf8>>)
}

fn token_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte:8, rest:bytes>> -> {
      let allowed =
        byte >= 48
        && byte <= 57
        || byte >= 65
        && byte <= 90
        || byte >= 97
        && byte <= 122
        || list.contains(
          [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126],
          byte,
        )
      allowed && token_bytes(rest)
    }
    _ -> False
  }
}

/// Renders present primitive argument values, omitting null and missing paths.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(plan) = http_headers.compile(json.Object([]))
/// assert http_headers.headers(plan, json.Object([])) == Ok([])
/// ```
pub fn headers(
  plan: Plan,
  arguments: JsonValue,
) -> Result(List(#(String, String)), String) {
  use values <- result.try(
    list.try_map(plan.entries, fn(entry) {
      case at(arguments, entry.path) {
        None | Some(json.Null) -> Ok(None)
        Some(value) -> {
          use value <- result.try(primitive(value, entry.kind))
          Ok(Some(#("mcp-param-" <> entry.name, encode_value(value))))
        }
      }
    }),
  )
  Ok(list.filter_map(values, option_to_result))
}

fn option_to_result(value: Option(a)) -> Result(a, Nil) {
  case value {
    Some(value) -> Ok(value)
    None -> Error(Nil)
  }
}

fn at(value: JsonValue, path: List(String)) -> Option(JsonValue) {
  case path, value {
    [], value -> Some(value)
    [name, ..rest], json.Object(fields) ->
      case list.key_find(fields, name) {
        Ok(child) -> at(child, rest)
        Error(_) -> None
      }
    _, _ -> None
  }
}

fn primitive(value: JsonValue, kind: Primitive) -> Result(String, String) {
  case value, kind {
    json.String(value), Text -> Ok(value)
    json.Int(value), Integer
      if value >= -9_007_199_254_740_991 && value <= 9_007_199_254_740_991
    -> Ok(int.to_string(value))
    json.Float(value), Integer -> {
      let integer = float.truncate(value)
      case
        value == int.to_float(integer)
        && integer >= -9_007_199_254_740_991
        && integer <= 9_007_199_254_740_991
      {
        True -> Ok(int.to_string(integer))
        False ->
          Error("mirrored integer must be integral and in the safe range")
      }
    }
    json.Bool(True), Boolean -> Ok("true")
    json.Bool(False), Boolean -> Ok("false")
    _, _ ->
      Error(
        "mirrored argument must have its declared primitive type and safe integer range",
      )
  }
}

/// Encodes unsafe UTF-8 values and sentinel-shaped literals without ambiguity.
///
/// ## Examples
///
/// ```gleam
/// assert http_headers.encode_value("echo") == "echo"
/// ```
pub fn encode_value(value: String) -> String {
  case
    safe_ascii(<<value:utf8>>)
    && value == string.trim(value)
    && !sentinel(value)
  {
    True -> value
    False ->
      "=?base64?" <> bit_array.base64_encode(<<value:utf8>>, True) <> "?="
  }
}

fn sentinel(value: String) -> Bool {
  string.starts_with(value, "=?base64?") && string.ends_with(value, "?=")
}

fn safe_ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte:8, rest:bytes>> -> {
      { byte == 9 || byte >= 32 && byte <= 126 } && safe_ascii(rest)
    }
    _ -> False
  }
}

/// Decodes HTTP field values, rejecting invalid bytes and malformed sentinels.
///
/// ## Examples
///
/// ```gleam
/// assert http_headers.decode_value(" echo ") == Ok("echo")
/// ```
pub fn decode_value(value: String) -> Result(String, String) {
  // The sentinel is decoded only after raw header safety checks. Decoded UTF-8
  // may contain characters that required Base64 on the wire.

  use Nil <- result.try(case safe_ascii(<<value:utf8>>) {
    True -> Ok(Nil)
    False -> Error("invalid HTTP header value")
  })
  let value = string.trim(value)
  case sentinel(value) {
    False -> Ok(value)
    True -> {
      let encoded = string.slice(value, 9, string.length(value) - 11)
      use bytes <- result.try(
        bit_array.base64_decode(encoded)
        |> result.map_error(fn(_) { "invalid base64 header" }),
      )
      bit_array.to_string(bytes)
      |> result.map_error(fn(_) { "invalid UTF-8 header" })
    }
  }
}

/// Reads exactly one case-insensitive field, refusing duplicate ambiguity.
///
/// ## Examples
///
/// ```gleam
/// assert http_headers.get([#("Mcp-Name", "echo")], "mcp-name") == Ok("echo")
/// ```
pub fn get(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, String) {
  case
    list.filter(headers, fn(header) {
      string.lowercase(header.0) == string.lowercase(name)
    })
  {
    [#(_, value)] -> Ok(value)
    [] -> Error("missing " <> name)
    _ -> Error("duplicate " <> name)
  }
}

/// Checks all recognized mirrored arguments before a handler is admitted.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(plan) = http_headers.compile(json.Object([]))
/// assert http_headers.validate(plan, json.Object([]), []) == Ok(Nil)
/// ```
pub fn validate(
  plan: Plan,
  arguments: JsonValue,
  incoming: List(#(String, String)),
) -> Result(Nil, String) {
  // Derive expected values from the JSON arguments, then require exact mirrors.
  // The final pass also rejects headers for null or absent bound properties.

  use expected <- result.try(headers(plan, arguments))
  use Nil <- result.try(
    list.try_fold(expected, Nil, fn(_, header) {
      use actual <- result.try(get(incoming, header.0))
      use actual <- result.try(decode_value(actual))
      use wanted <- result.try(decode_value(header.1))
      case actual == wanted {
        True -> Ok(Nil)
        False -> Error("header mismatch: " <> header.0)
      }
    }),
  )
  list.try_fold(plan.entries, Nil, fn(_, entry) {
    let name = "mcp-param-" <> entry.name
    case at(arguments, entry.path) {
      None | Some(json.Null) ->
        case
          list.any(incoming, fn(header) {
            string.lowercase(header.0) == string.lowercase(name)
          })
        {
          True -> Error("header present for absent argument: " <> name)
          False -> Ok(Nil)
        }
      Some(_) -> Ok(Nil)
    }
  })
}
