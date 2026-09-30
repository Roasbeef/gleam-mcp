//// An endpoint binds request effects to one caller-owned transport.
//// Typed tools hand the transport their compiled input schema, allowing HTTP
//// binding validation before admission. This seam owns no process or socket.

import gleam/int
import gleam/option.{type Option}
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc
import gleam_mcp/metadata
import gleam_mcp/schema.{type Schema}
import gleam_mcp/version.{type Version}

/// A request refusal, preserving JSON-RPC error data without reducing it.
pub type Error {
  /// The caller-owned transport could not complete the exchange.
  TransportFailed(reason: String)

  /// A correlated JSON-RPC error returned by the peer.
  RpcFailed(error: jsonrpc.RpcError)

  /// A successful envelope did not satisfy its bound result contract.
  InvalidResponse(reason: String)

  /// Arguments or their transport binding failed before effects began.
  InvalidArguments(reason: String)
}

/// The complete request passed to a caller-owned exchange function.
pub type Outbound {
  Outbound(
    /// The JSON-RPC envelope, including revision-specific request metadata.
    envelope: JsonValue,
    /// The tool input schema, absent on protocol metadata requests.
    input_schema: Option(Schema),
    /// The caller's total exchange deadline in milliseconds.
    timeout_ms: Int,
    /// Notifications observed while this request is outstanding.
    on_notification: fn(JsonValue) -> Nil,
  )
}

/// One transport and its schema-admission policy.
pub opaque type Endpoint {
  Endpoint(
    identifier: String,
    exchange: fn(Outbound) -> Result(JsonValue, Error),
    admit: fn(Schema) -> Result(Nil, Error),
  )
}

/// Options bound to one request rather than inherited from a session.
pub opaque type Options {
  Options(
    meta: metadata.Metadata,
    timeout_ms: Int,
    on_notification: fn(JsonValue) -> Nil,
  )
}

/// Constructs an endpoint whose transport has no schema-specific restrictions.
///
/// ## Examples
///
/// ```gleam
/// // request.endpoint("local", fn(outbound) { exchange(outbound.envelope) })
/// ```
pub fn endpoint(
  identifier: String,
  exchange: fn(Outbound) -> Result(JsonValue, Error),
) -> Endpoint {
  endpoint_with_admission(identifier, exchange, fn(_) { Ok(Nil) })
}

/// Constructs an endpoint that validates transport bindings before tool calls.
///
/// ## Examples
///
/// ```gleam
/// // HTTP endpoints install their compiled x-mcp-header admission check here.
/// ```
pub fn endpoint_with_admission(
  identifier: String,
  exchange: fn(Outbound) -> Result(JsonValue, Error),
  admit: fn(Schema) -> Result(Nil, Error),
) -> Endpoint {
  Endpoint(identifier, exchange, admit)
}

/// Returns the caller's stable endpoint identity for diagnostics and custody.
///
/// ## Examples
///
/// ```gleam
/// // request.identifier(endpoint) returns its construction-time label.
/// ```
pub fn identifier(endpoint: Endpoint) -> String {
  endpoint.identifier
}

/// Runs the transport's admission policy on a compiled tool schema.
///
/// ## Examples
///
/// ```gleam
/// // request.admit_schema(endpoint, input_schema) precedes encoding a call.
/// ```
pub fn admit_schema(endpoint: Endpoint, schema: Schema) -> Result(Nil, Error) {
  endpoint.admit(schema)
}

/// Invokes one explicit exchange; it never retries a failed request.
///
/// ## Examples
///
/// ```gleam
/// // request.exchange(endpoint, outbound) returns a JSON-RPC response envelope.
/// ```
pub fn exchange(
  endpoint: Endpoint,
  outbound: Outbound,
) -> Result(JsonValue, Error) {
  endpoint.exchange(outbound)
}

/// Builds modern request options with descriptive caller identity.
///
/// ## Examples
///
/// ```gleam
/// // request.options("agent", "1") uses revision 2026-07-28 and a 60s budget.
/// ```
pub fn options(name: String, release: String) -> Options {
  Options(
    metadata.new(version.V20260728) |> metadata.with_client(name, release),
    60_000,
    fn(_) { Nil },
  )
}

/// Selects a wire contract without changing the endpoint's transport.
///
/// ## Examples
///
/// ```gleam
/// // options |> request.with_version(version.V20250618)
/// ```
pub fn with_version(options: Options, revision: Version) -> Options {
  let meta = metadata.with_revision(options.meta, revision)
  Options(..options, meta:)
}

/// Sets a finite exchange budget within the native timer range.
///
/// Budgets clamp to 1–4,294,966,295 ms, leaving room for the actor reply margin.
///
/// ## Examples
///
/// ```gleam
/// // options |> request.with_timeout(5000)
/// ```
pub fn with_timeout(options: Options, milliseconds: Int) -> Options {
  Options(..options, timeout_ms: int.clamp(milliseconds, 1, 4_294_966_295))
}

/// Installs the request-local notification observer.
///
/// ## Examples
///
/// ```gleam
/// // options |> request.with_notifications(fn(message) { observe(message) })
/// ```
pub fn with_notifications(
  options: Options,
  observer: fn(JsonValue) -> Nil,
) -> Options {
  Options(..options, on_notification: observer)
}

/// Returns admitted metadata for constructing this request.
///
/// ## Examples
///
/// ```gleam
/// // request.metadata(options) supplies the params._meta object.
/// ```
pub fn metadata(options: Options) -> metadata.Metadata {
  options.meta
}

/// Returns the finite request budget used by multi-page callers.
///
/// ## Examples
///
/// ```gleam
/// // request.timeout_ms(options) is shared across one catalog traversal.
/// ```
pub fn timeout_ms(options: Options) -> Int {
  options.timeout_ms
}

/// Packs one explicit request with its effect budget and notification observer.
///
/// ## Examples
///
/// ```gleam
/// // request.outbound(options, envelope, None) builds a discovery exchange.
/// ```
pub fn outbound(
  options: Options,
  envelope: JsonValue,
  input_schema: Option(Schema),
) -> Outbound {
  Outbound(envelope, input_schema, options.timeout_ms, options.on_notification)
}
