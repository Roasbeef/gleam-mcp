//// Mist exposes its socket but not typed close messages for SSE selectors.
//// Neither stdlib nor gleam_erlang can decode the opaque native socket term.
//// This single adapter compares socket identity and classifies lifecycle events;
//// actor selection, cancellation and worker custody remain in Gleam and weft.
////
//// ## Flow
////
//// classify compares the exact Mist socket in TCP/TLS close, error and data
//// messages. server_http selects these messages alongside weft scope outcomes;
//// Closed and UnexpectedData request cancellation, while Unrelated preserves the
//// stream. Classification has no authority to cancel or stop a process itself.

import gleam/dynamic.{type Dynamic}
import glisten/socket.{type Socket}

/// The lifecycle interpretation of one native socket message.
pub type Event {
  /// The owning connection closed or errored.
  Closed

  /// Bytes arrived after the single request body and cannot be admitted.
  UnexpectedData

  /// The message does not belong to this socket.
  Unrelated
}

/// Classifies native TCP or TLS messages for exactly this socket.
///
/// ## Examples
///
/// `classify(socket, message)` never treats another connection's close as ours.
@external(erlang, "gleam_mcp_http_socket_ffi", "classify")
pub fn classify(socket: Socket, message: Dynamic) -> Event
