//// Native stdio bindings for the foreground server loop.
////
//// Gleam's standard I/O API can print but cannot read stdin. Neither
//// gleam_erlang, gleam_otp nor weft exposes a bounded stdin line reader.
//// The shim uses OTP's get_until protocol to stop at a newline or byte cap
//// before constructing a complete String; it starts no process or timer.

import gleam/option.{type Option}

/// Why the bounded native input operation did not produce a line.
pub type ReadError {
  /// The line exceeded the requested byte cap.
  LineTooLong

  /// Input was invalid Unicode or the device failed.
  ReadFailed
}

/// Reads at most `limit` UTF-8 bytes, excluding the newline.
///
/// OTP io:get_until is needed because io:get_line has no size bound and
/// fixed-size get_chars waits for the entire chunk on interactive pipes.
///
/// ## Examples
///
/// ```gleam
/// // ffi_stdio.read_line(16_777_216)
/// ```
@external(erlang, "gleam_mcp_ffi", "stdio_read_line")
pub fn read_line(limit: Int) -> Result(Option(String), ReadError)

/// Writes one already-framed response through OTP io:put_chars.
///
/// A normalized Result keeps a broken output pipe from crashing the server.
///
/// ## Examples
///
/// ```gleam
/// // ffi_stdio.write("{}\n")
/// ```
@external(erlang, "gleam_mcp_ffi", "stdio_write")
pub fn write(line: String) -> Result(Nil, Nil)
