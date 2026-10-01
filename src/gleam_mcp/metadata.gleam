//// Per-request metadata replaces initialized session state in modern MCP.
//// Client identity is descriptive data, never authorization. Unknown metadata
//// remains intact while required protocol fields are decoded at this boundary.
////
//// ## Flow
////
//// new and with_client build descriptive request metadata; with_revision updates
//// the wire key and the stored revision together. decode -> version.decode ->
//// validate_identity admits required fields while retaining unknown extension
//// fields. value serializes that same field list. Metadata validates structure;
//// authorization belongs to the host's transport and tool admission policy.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/version.{type Version}

/// The protocol revision key reserved by MCP.
pub const protocol_version_key = "io.modelcontextprotocol/protocolVersion"

/// The request-scoped client capability key reserved by MCP.
pub const capabilities_key = "io.modelcontextprotocol/clientCapabilities"

/// The request-scoped client identity key reserved by MCP.
pub const client_info_key = "io.modelcontextprotocol/clientInfo"

/// Metadata admitted for one request, with no inherited connection state.
pub opaque type Metadata {
  /// The parsed metadata or revision and preserved fields for this module.
  Metadata(
    /// The decoded contract, kept consistent with its wire field.
    revision: Version,
    /// The admitted field list, including unknown metadata extensions.
    fields: List(#(String, JsonValue)),
  )
}

/// A refusal at the request metadata boundary.
pub type Fault {
  /// A required field was absent or had the wrong shape.
  InvalidMetadata(
    /// The required metadata shape that failed.
    reason: String,
  )

  /// The requested contract is not implemented.
  UnsupportedVersion(
    /// The unsupported revision string received from the peer.
    requested: String,
  )
}

/// Builds metadata with no optional client capabilities.
///
/// ## Examples
///
/// ```gleam
/// assert metadata.capabilities(metadata.new(version.V20260728)) == json.Object([])
/// ```
pub fn new(revision: Version) -> Metadata {
  Metadata(revision, [
    #(protocol_version_key, json.String(version.name(revision))),
    #(capabilities_key, json.Object([])),
  ])
}

/// Adds descriptive caller identity to a request.
///
/// ## Examples
///
/// ```gleam
/// let meta = metadata.new(version.V20260728) |> metadata.with_client("agent", "1")
/// assert metadata.revision(meta) == version.V20260728
/// ```
pub fn with_client(
  metadata: Metadata,
  name: String,
  release: String,
) -> Metadata {
  Metadata(
    ..metadata,
    fields: list.append(
      list.filter(metadata.fields, fn(pair) { pair.0 != client_info_key }),
      [
        #(
          client_info_key,
          json.Object([
            #("name", json.String(name)),
            #("version", json.String(release)),
          ]),
        ),
      ],
    ),
  )
}

/// Returns the validated revision associated with this request.
///
/// ## Examples
///
/// ```gleam
/// assert metadata.revision(metadata.new(version.V20260728)) == version.V20260728
/// ```
pub fn revision(metadata: Metadata) -> Version {
  metadata.revision
}

/// Selects a revision while retaining the caller identity and extension fields.
///
/// ## Examples
///
/// ```gleam
/// let meta = metadata.new(version.V20260728) |> metadata.with_revision(version.V20250618)
/// assert metadata.revision(meta) == version.V20250618
/// ```
pub fn with_revision(metadata: Metadata, revision: Version) -> Metadata {
  Metadata(
    revision,
    list.append(
      list.filter(metadata.fields, fn(pair) { pair.0 != protocol_version_key }),
      [#(protocol_version_key, json.String(version.name(revision)))],
    ),
  )
}

/// Returns the exact metadata object for request construction.
///
/// ## Examples
///
/// ```gleam
/// assert metadata.value(metadata.new(version.V20260728)) == json.Object([
///   #(metadata.protocol_version_key, json.String("2026-07-28")),
///   #(metadata.capabilities_key, json.Object([])),
/// ])
/// ```
pub fn value(metadata: Metadata) -> JsonValue {
  json.Object(metadata.fields)
}

/// Decodes required modern metadata and preserves extension fields.
///
/// ## Examples
///
/// ```gleam
/// assert metadata.decode(json.Object([])) |> result.is_error
/// ```
pub fn decode(value: JsonValue) -> Result(Metadata, Fault) {
  // The stored revision is decoded from the preserved wire object in the same
  // pass, so later dispatch cannot use a different contract from its metadata.

  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(InvalidMetadata("_meta must be an object"))
  })
  use label <- result.try(case list.key_find(fields, protocol_version_key) {
    Ok(json.String(label)) -> Ok(label)
    _ -> Error(InvalidMetadata("protocol version metadata must be a string"))
  })
  use revision <- result.try(
    version.decode(label) |> result.map_error(UnsupportedVersion),
  )
  use Nil <- result.try(case list.key_find(fields, capabilities_key) {
    Ok(json.Object(_)) -> Ok(Nil)
    _ ->
      Error(InvalidMetadata("client capabilities metadata must be an object"))
  })
  use Nil <- result.try(
    validate_identity(
      option.from_result(list.key_find(fields, client_info_key)),
    ),
  )
  Ok(Metadata(revision, fields))
}

fn validate_identity(value: Option(JsonValue)) -> Result(Nil, Fault) {
  case value {
    None -> Ok(Nil)
    Some(json.Object(fields)) ->
      case list.key_find(fields, "name"), list.key_find(fields, "version") {
        Ok(json.String(_)), Ok(json.String(_)) -> Ok(Nil)
        _, _ ->
          Error(InvalidMetadata(
            "client identity requires name and version strings",
          ))
      }
    Some(_) ->
      Error(InvalidMetadata("client identity metadata must be an object"))
  }
}

/// Returns the client-declared capability object for this request.
///
/// ## Examples
///
/// ```gleam
/// assert metadata.capabilities(metadata.new(version.V20260728)) == json.Object([])
/// ```
pub fn capabilities(meta: Metadata) -> JsonValue {
  list.key_find(meta.fields, capabilities_key) |> result.unwrap(json.Object([]))
}
