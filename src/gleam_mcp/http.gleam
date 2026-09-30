//// Stateless HTTP metadata mirrors the same envelope that the handler receives.
//// This module owns admission ordering but no socket. HTTP stack integrations
//// reuse the boundary so malformed headers cannot select one operation while
//// the JSON body executes another.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/http_headers
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/metadata

/// The method, optional tool name, and revision bound to one request.
pub type Metadata {
  Metadata(
    /// The body method mirrored verbatim, with case-sensitive values.
    method: String,
    /// The tool name or other named primitive, absent for metadata requests.
    name: Option(String),
    /// The body's declared revision, retained before version admission.
    revision: String,
  )
}

/// Reads required modern metadata from a JSON-RPC request envelope.
///
/// ## Examples
///
/// `metadata(envelope)` reads params._meta and the request method.
pub fn metadata(envelope: JsonValue) -> Result(Metadata, String) {
  use fields <- result.try(object(envelope))
  use method <- result.try(text(fields, "method"))
  use params <- result.try(field(fields, "params") |> result.try(object))
  use meta <- result.try(field(params, "_meta") |> result.try(object))
  use revision <- result.try(text(meta, metadata.protocol_version_key))
  use name <- result.try(case method {
    "tools/call" | "prompts/get" -> text(params, "name") |> result.map(Some)
    "resources/read" -> text(params, "uri") |> result.map(Some)
    _ -> Ok(None)
  })
  Ok(Metadata(method, name, revision))
}

/// Derives the standard request headers from the complete JSON envelope.
///
/// ## Examples
///
/// `headers(envelope)` includes both JSON and SSE in Accept.
pub fn headers(envelope: JsonValue) -> Result(List(#(String, String)), String) {
  use meta <- result.try(metadata(envelope))
  use Nil <- result.try(safe_method(meta.method))
  use Nil <- result.try(safe_method(meta.revision))
  let headers = [
    #("accept", "application/json, text/event-stream"),
    #("content-type", "application/json"),
    #("mcp-protocol-version", meta.revision),
    #("mcp-method", meta.method),
  ]
  Ok(case meta.name {
    None -> headers
    Some(name) ->
      list.append(headers, [#("mcp-name", http_headers.encode_value(name))])
  })
}

fn safe_method(method: String) -> Result(Nil, String) {
  case http_headers.decode_value(method) {
    Ok(value) if value == method -> Ok(Nil)
    _ -> Error("unsafe MCP method")
  }
}

/// Validates standard metadata before dispatch or custom header validation.
///
/// ## Examples
///
/// `validate(envelope, incoming)` refuses any missing or mismatched mirror.
pub fn validate(
  envelope: JsonValue,
  incoming: List(#(String, String)),
) -> Result(Metadata, String) {
  use meta <- result.try(metadata(envelope))
  use Nil <- result.try(equal(incoming, "mcp-protocol-version", meta.revision))
  use Nil <- result.try(equal(incoming, "mcp-method", meta.method))
  use Nil <- result.try(case meta.name {
    None -> Ok(Nil)
    Some(name) -> {
      use value <- result.try(http_headers.get(incoming, "mcp-name"))
      use value <- result.try(http_headers.decode_value(value))
      case value == name {
        True -> Ok(Nil)
        False -> Error("header mismatch: mcp-name")
      }
    }
  })
  Ok(meta)
}

fn equal(
  incoming: List(#(String, String)),
  name: String,
  wanted: String,
) -> Result(Nil, String) {
  use actual <- result.try(http_headers.get(incoming, name))
  case actual == wanted {
    True -> Ok(Nil)
    False -> Error("header mismatch: " <> name)
  }
}

/// Reads tool arguments with an empty object default.
///
/// ## Examples
///
/// `arguments(envelope)` supplies the mirrored tool parameter source.
pub fn arguments(envelope: JsonValue) -> Result(JsonValue, String) {
  use fields <- result.try(object(envelope))
  use params <- result.try(field(fields, "params") |> result.try(object))
  case list.key_find(params, "arguments") {
    Error(_) -> Ok(json.Object([]))
    Ok(arguments) -> Ok(arguments)
  }
}

fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected object")
  }
}

fn field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(JsonValue, String) {
  list.key_find(fields, name) |> result.map_error(fn(_) { "missing " <> name })
}

fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  use value <- result.try(field(fields, name))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error(name <> " must be a string")
  }
}
