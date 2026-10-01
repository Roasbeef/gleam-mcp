//// An endpoint binds request effects to one caller-owned transport.
//// Typed tools hand the transport their compiled input schema, allowing HTTP
//// binding validation before admission. This seam owns no process or socket.
////
//// ## Flow
////
//// options -> outbound carries one request's metadata, timer and observer.
//// endpoint_with_admission binds exchange and schema policy together; client.call
//// uses admit_schema before exchange. The endpoint invokes the supplied callback
//// once and has no resource lifecycle of its own.
////
//// A function value can capture its transport configuration in Gleam. Retaining an
//// Endpoint therefore retains that exact callback and configuration in a client
//// continuation. Custom exchanges must enforce their own timer and cleanup contract;
//// a timeout_ms field alone cannot stop external work.

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
  TransportFailed(
    /// The failed contract or transport diagnostic.
    reason: String,
  )

  /// A correlated JSON-RPC error returned by the peer.
  RpcFailed(
    /// The peer's structured JSON-RPC refusal.
    error: jsonrpc.RpcError,
  )

  /// A successful envelope did not satisfy its bound result contract.
  InvalidResponse(
    /// The failed contract or transport diagnostic.
    reason: String,
  )

  /// Arguments or their transport binding failed before effects began.
  InvalidArguments(
    /// The failed contract or transport diagnostic.
    reason: String,
  )
}

/// The complete request passed to a caller-owned exchange function.
pub type Outbound {
  /// The complete exchange contract passed to the transport.
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
  /// The exchange and schema admission policy retained under one identity.
  Endpoint(
    /// The stable caller-selected label; it grants no transport authority.
    identifier: String,
    /// The exact caller-owned callback invoked for one explicit exchange.
    exchange: fn(Outbound) -> Result(JsonValue, Error),
    /// The schema policy run before a typed call can enter the exchange.
    admit: fn(Schema) -> Result(Nil, Error),
  )
}

/// Options bound to one request rather than inherited from a session.
pub opaque type Options {
  /// The request or startup settings used by this module.
  Options(
    /// The request-scoped metadata, including descriptive client identity.
    meta: metadata.Metadata,
    /// The clamped positive timer budget passed to the transport.
    timeout_ms: Int,
    /// The observer for notifications admitted by the selected transport.
    on_notification: fn(JsonValue) -> Nil,
  )
}

/// Constructs an endpoint whose transport has no schema-specific restrictions.
///
/// ## Examples
///
/// ```gleam
/// let endpoint = request.endpoint("local", fn(outbound) { Ok(outbound.envelope) })
/// assert request.identifier(endpoint) == "local"
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
/// let endpoint = request.endpoint_with_admission(
///   "local", fn(outbound) { Ok(outbound.envelope) },
///   fn(_) { Error(request.InvalidArguments("schema refused")) },
/// )
/// let assert Ok(input) = schema.new(json.Bool(True))
/// assert request.admit_schema(endpoint, input) == Error(request.InvalidArguments("schema refused"))
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
/// let endpoint = request.endpoint("local", fn(outbound) { Ok(outbound.envelope) })
/// assert request.identifier(endpoint) == "local"
/// ```
pub fn identifier(endpoint: Endpoint) -> String {
  endpoint.identifier
}

/// Runs the transport's admission policy on a compiled tool schema.
///
/// ## Examples
///
/// ```gleam
/// let endpoint = request.endpoint("local", fn(outbound) { Ok(outbound.envelope) })
/// let assert Ok(input) = schema.new(json.Bool(True))
/// assert request.admit_schema(endpoint, input) == Ok(Nil)
/// ```
pub fn admit_schema(endpoint: Endpoint, schema: Schema) -> Result(Nil, Error) {
  endpoint.admit(schema)
}

/// Invokes one explicit exchange; it never retries a failed request.
///
/// ## Examples
///
/// ```gleam
/// let endpoint = request.endpoint("local", fn(outbound) { Ok(outbound.envelope) })
/// let outbound = request.outbound(request.options("agent", "1"), json.Null, None)
/// assert request.exchange(endpoint, outbound) == Ok(json.Null)
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
/// assert request.timeout_ms(request.options("agent", "1")) == 60_000
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
/// let options = request.options("agent", "1") |> request.with_version(version.V20250618)
/// assert metadata.revision(request.metadata(options)) == version.V20250618
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
/// let options = request.options("agent", "1") |> request.with_timeout(0)
/// assert request.timeout_ms(options) == 1
/// ```
pub fn with_timeout(options: Options, milliseconds: Int) -> Options {
  Options(..options, timeout_ms: int.clamp(milliseconds, 1, 4_294_966_295))
}

/// Installs the request-local notification observer.
///
/// ## Examples
///
/// ```gleam
/// let options = request.options("agent", "1")
///   |> request.with_notifications(fn(_) { Nil })
/// // -> The observer is attached to this request, not an inherited session.
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
/// assert metadata.revision(request.metadata(request.options("agent", "1"))) == version.V20260728
/// ```
pub fn metadata(options: Options) -> metadata.Metadata {
  options.meta
}

/// Returns the finite request budget used by multi-page callers.
///
/// ## Examples
///
/// ```gleam
/// assert request.timeout_ms(request.options("agent", "1")) == 60_000
/// ```
pub fn timeout_ms(options: Options) -> Int {
  options.timeout_ms
}

/// Packs one explicit request with its effect budget and notification observer.
///
/// ## Examples
///
/// ```gleam
/// let outbound = request.outbound(request.options("agent", "1"), json.Null, None)
/// assert outbound.envelope == json.Null
/// assert outbound.timeout_ms == 60_000
/// ```
pub fn outbound(
  options: Options,
  envelope: JsonValue,
  input_schema: Option(Schema),
) -> Outbound {
  Outbound(envelope, input_schema, options.timeout_ms, options.on_notification)
}
