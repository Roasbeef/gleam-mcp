//// Gun provides maintained HTTP/TLS parsing and flow-controlled body messages.
//// Neither stdlib, gleam_http, gleam_erlang, gleam_otp nor weft exposes native
//// incremental HTTP response events. This adapter only translates native calls;
//// deadlines, SSE framing, admission and connection custody stay in Gleam.

import gleam/erlang/process.{type Pid}

/// An opaque native Gun stream reference.
pub type Stream

/// The native response completion marker.
pub type Completion {
  /// Further body messages can follow.
  More

  /// The response has ended.
  Finished
}

/// A bounded native response event.
pub type Event {
  /// Metadata precedes body bytes.
  Headers(completion: Completion, status: Int, headers: List(#(String, String)))

  /// One flow-controlled body fragment.
  Data(
    /// Whether this is the last native response fragment.
    completion: Completion,
    /// Bytes whose UTF-8 boundaries are deliberately not assumed.
    bytes: BitArray,
  )

  /// An informational response does not finish the exchange.
  Inform

  /// Trailers terminate a chunked response.
  Trailers
}

/// Opens one non-retrying HTTP connection with verified TLS when requested.
///
/// ## Examples
///
/// `open("localhost", 8000, "http", 5000)` owns one plain connection.
@external(erlang, "gleam_mcp_http_ffi", "open")
pub fn open(
  host: String,
  port: Int,
  scheme: String,
  timeout: Int,
) -> Result(Pid, String)

/// Sends the single request after connection custody has been adopted.
///
/// ## Examples
///
/// `post(connection, "/mcp", headers, body, 5000)` starts one stream.
@external(erlang, "gleam_mcp_http_ffi", "post")
pub fn post(
  connection: Pid,
  path: String,
  headers: List(#(String, String)),
  body: String,
  timeout: Int,
) -> Result(Stream, String)

/// Receives one response fragment within the remaining request deadline.
///
/// ## Examples
///
/// `next(connection, stream, 1000)` grants no implicit extra body credit.
@external(erlang, "gleam_mcp_http_ffi", "next")
pub fn next(
  connection: Pid,
  stream: Stream,
  timeout: Int,
) -> Result(Event, String)

/// Grants one additional body-message credit.
///
/// ## Examples
///
/// `credit(connection, stream)` follows consumption of the previous fragment.
@external(erlang, "gleam_mcp_http_ffi", "credit")
pub fn credit(connection: Pid, stream: Stream) -> Nil

/// Stops and joins the native connection owner.
///
/// ## Examples
///
/// `close(connection)` cancels an unfinished response without replay.
@external(erlang, "gleam_mcp_http_ffi", "close")
pub fn close(connection: Pid) -> Nil

/// Reads a monotonic clock for total request deadlines.
///
/// ## Examples
///
/// `now()` is meaningful only for elapsed-time comparisons.
@external(erlang, "gleam_mcp_http_ffi", "now")
pub fn now() -> Int
