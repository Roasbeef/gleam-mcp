//// Native child-process bindings preserve the client's retirement witness.
////
//// ## Flow
////
//// open_stdio uses erlang:open_port through the shim and returns a port owned by
//// the calling actor. port_send converts closed-port failures into Results.
//// port_os_pid -> kill_os_process requests direct-child termination, retaining
//// the open port so port_event can deliver its later native exit_status.
////
//// Maintained Gleam libraries don't expose this complete stdio spawn/event seam.
//// The Erlang shim normalizes native terms; transport owns selection and client
//// owns lifetime. No port_close binding is provided because destroying the port
//// would discard the exit-status evidence shutdown requires. PID signaling remains
//// best effort, with no atomic lookup or descendant join.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}
import gleam/option.{type Option}

/// One normalized message from a server port, produced by `port_event`.
pub type PortEvent {
  /// A chunk of the server's stdout reached us. Invariant: raw bytes at
  /// whatever boundary the pipe delivered; not yet lines, not yet UTF-8.
  PortBytes(
    /// Raw stdout bytes, before UTF-8 repair and newline framing.
    data: BitArray,
  )

  /// The server process exited with this OS status.
  PortClosed(
    /// The direct child's native exit status, retained as retirement evidence.
    status: Int,
  )

  /// A message matched the port selector but was not a recognised port
  /// message shape; ignored by the client.
  PortJunk
}

/// Spawns an executable with argv, extra environment pairs, and an
/// optional working directory, as an Erlang port in binary stream mode
/// with exit-status reporting. The child's stdin and stdout are the wire;
/// stderr is deliberately left alone (see `gleam_mcp/transport` for why).
///
/// Uses `erlang:open_port/2` with `spawn_executable`; there is no other
/// non-NIF way to stream to a child process from the BEAM. argv is a
/// list, never a shell string, so nothing here is shell-interpretable.
///
/// The error carries the failure's own reason as a short lowercase
/// string — `"enoent"` for a missing executable, `"eacces"` for one that
/// cannot be run, the class and a bounded term for anything else. That
/// distinction is load-bearing rather than cosmetic: the port tests skip
/// on an absent binary, and a blanket `Error(Nil)` let an FFI regression
/// wear the same clothes as a host without `/bin/cat`.
///
/// ## Examples
///
/// ```gleam
/// ffi_port.open_stdio("/bin/cat", [], [], None)
/// // -> Result(Port, String); the caller owns the opened port.
/// ```
@external(erlang, "gleam_mcp_ffi", "open_stdio")
pub fn open_stdio(
  executable: String,
  args: List(String),
  env: List(#(String, String)),
  directory: Option(String),
) -> Result(Port, String)

/// Writes one already-framed line to the server's stdin. Errors once the
/// port is closed, so a dead server settles in-band rather than crashing
/// the writer.
///
/// Uses `erlang:port_command/2` via a shim that converts its badarg on a
/// dead port into `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// ffi_port.port_send(port, "{}\n")
/// // -> Ok(Nil) or Error(Nil); a closed peer is an error value.
/// ```
@external(erlang, "gleam_mcp_ffi", "port_send")
pub fn port_send(port: Port, line: String) -> Result(Nil, Nil)

/// Reports the OS pid of the port's child process, when it is running.
///
/// Uses `erlang:port_info/2` immediately before requesting termination.
/// The caller retains the port for its later native exit-status event.
///
/// ## Examples
///
/// ```gleam
/// ffi_port.port_os_pid(port)
/// // -> The current direct-child pid, or Error(Nil) after exit.
/// ```
@external(erlang, "gleam_mcp_ffi", "port_os_pid")
pub fn port_os_pid(port: Port) -> Result(Int, Nil)

/// Sends SIGKILL to an OS process by pid. No-op for pids `<= 1`.
///
/// Uses `os:cmd/1` running `kill -KILL`; the BEAM offers no direct
/// kill(2) without a NIF. This is best-effort single-process signaling:
/// the pid lookup and signal are not atomic, and descendants are not joined.
///
/// ## Examples
///
/// ```gleam
/// ffi_port.kill_os_process(child_pid)
/// // -> Nil; signaling alone does not prove retirement.
/// ```
@external(erlang, "gleam_mcp_ffi", "kill_os_process")
pub fn kill_os_process(os_pid: Int) -> Nil

/// Normalizes a raw port message (delivered by a record selector on the
/// port) into a `PortEvent`.
///
/// Uses an Erlang shim because the message arrives as a `Dynamic` whose
/// `{Port, {data, Bin}}` shape only Erlang pattern matching can take
/// apart without partial decoders.
///
/// ## Examples
///
/// ```gleam
/// ffi_port.port_event(native_message)
/// // -> PortBytes, PortClosed or PortJunk; selection checks port identity.
/// ```
@external(erlang, "gleam_mcp_ffi", "port_event")
pub fn port_event(message: Dynamic) -> PortEvent
