//// Foreground stdio ownership for the reusable tools server.
////
//// One scoped callback runs beside one bounded lookahead read. The next line
//// stays in custody until that callback settles, so pipelining cannot reorder
//// lifecycle transitions or lose input. EOF stops admission and drains the
//// current request under its existing deadline before returning.

import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/internal/ffi_stdio
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/server.{type Server}
import gleam_mcp/stdio
import weft

/// Default budget for one admitted handler, in milliseconds.
pub const default_request_timeout_ms = 60_000

/// Why stdio serving stopped without a clean, fully settled EOF.
pub type StdioError {
  /// A line exceeded the shared MCP framing limit.
  LineTooLong

  /// Standard input failed or contained invalid Unicode.
  ReadFailed

  /// Standard output could not carry a response.
  WriteFailed

  /// The callback exceeded its request budget and its worker was joined.
  RequestTimedOut

  /// A callback or scoped worker crashed without returning a verdict.
  WorkerFailed
}

/// The positive per-request deadline used by the foreground server.
pub opaque type Options {
  Options(
    /// The positive callback budget; it also bounds drain after EOF.
    request_timeout_ms: Int,
  )
}

/// Uses the default per-request deadline.
///
/// ## Examples
///
/// ```gleam
/// // server_stdio.options()
/// ```
pub fn options() -> Options {
  Options(default_request_timeout_ms)
}

/// Overrides the request budget, clamping non-positive values to one millisecond.
///
/// ## Examples
///
/// ```gleam
/// // server_stdio.options() |> server_stdio.with_request_timeout(5000)
/// ```
pub fn with_request_timeout(_options: Options, ms: Int) -> Options {
  Options(request_timeout_ms: int.max(ms, 1))
}

/// Serves stdin until EOF, draining the last admitted request before returning.
///
/// Only responses go to stdout. The caller owns its handler's effect cleanup:
/// joining a canceled callback proves its worker stopped, not that remote effects
/// were rolled back or drained. Requests are never retried automatically.
///
/// ## Examples
///
/// ```gleam
/// // server_stdio.run(server)
/// ```
pub fn run(server: Server) -> Result(Nil, StdioError) {
  run_with_options(server, options())
}

/// Serves native stdio with a caller-selected request budget.
///
/// ## Examples
///
/// ```gleam
/// // server_stdio.run_with_options(server, server_stdio.options())
/// ```
pub fn run_with_options(
  server: Server,
  options: Options,
) -> Result(Nil, StdioError) {
  run_with_io(server, options, native_read, ffi_stdio.write)
}

/// Runs the production custody loop with caller-owned bounded I/O callbacks.
///
/// `read` returns complete lines without their newline and `None` for EOF.
/// `write` receives one complete newline-terminated response. A read callback
/// must enforce the framing cap before constructing an oversized String.
///
/// ## Examples
///
/// ```gleam
/// // server_stdio.run_with_io(server, options, read_line, write_response)
/// ```
pub fn run_with_io(
  server: Server,
  options: Options,
  read: fn() -> Result(Option(String), StdioError),
  write: fn(String) -> Result(Nil, Nil),
) -> Result(Nil, StdioError) {
  use line <- result.try(read())
  case line {
    None -> Ok(Nil)
    Some(line) -> serve_line(server, line, options, read, write)
  }
}

type Event {
  Handled(server: Server, response: Option(JsonValue))
  Read(line: Option(String))
}

type Input {
  Unread
  Next(line: Option(String))
}

type Progress {
  Progress(server: Option(Server), input: Input)
}

fn serve_line(
  server: Server,
  line: String,
  options: Options,
  read: fn() -> Result(Option(String), StdioError),
  write: fn(String) -> Result(Nil, Nil),
) -> Result(Nil, StdioError) {
  let line = case string.ends_with(line, "\r") {
    True -> string.drop_end(line, 1)
    False -> line
  }

  // The dispatch task retains the inner deadline scope before admitting the
  // callback. Reader failure may kill its wrapper, but the outer scope still
  // joins the handler's real owner before returning.
  let run =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        bounded_dispatch(server, line, options, ledger)
      }),
      weft.task(fn() { read() |> result.map(Read) }),
    ])
    |> weft.limit(2)
    |> weft.start_detached
  use next <- result.try(collect(run, Progress(None, Unread), write))
  case next {
    None -> Ok(Nil)
    Some(#(server, line)) -> serve_line(server, line, options, read, write)
  }
}

fn bounded_dispatch(
  server: Server,
  line: String,
  options: Options,
  ledger: weft.Ledger,
) -> Result(Event, StdioError) {
  let ready = process.new_subject()
  let request =
    weft.new([
      fn() {
        let admit = process.new_subject()
        process.send(ready, admit)
        let Nil = process.receive_forever(admit)
        Ok(server.handle_line(server, line))
      },
    ])
    |> weft.deadline(options.request_timeout_ms)
    |> weft.start_detached

  // The callback is parked until publication transfers its scope's custody.
  // A refusal never opens the gate; cancellation still retains that scope.
  case
    weft.adopt(ledger, owner: weft.scope_pid(request), cancel: fn() {
      weft.cancel_detached(request)
    })
  {
    weft.Refused -> Error(WorkerFailed)
    weft.Adopted -> {
      use admit <- result.try(
        process.receive(ready, options.request_timeout_ms)
        |> result.map_error(fn(_) {
          weft.cancel_detached(request)
          RequestTimedOut
        }),
      )
      process.send(admit, Nil)
      await_dispatch(request, Error(WorkerFailed))
    }
  }
}

fn await_dispatch(
  request: weft.Detached(#(Server, Option(JsonValue)), Nil),
  answer: Result(Event, StdioError),
) -> Result(Event, StdioError) {
  case weft.pull(request, within: 1000) {
    weft.NotYet -> await_dispatch(request, answer)
    weft.RunLost(_) -> Error(WorkerFailed)
    weft.AllDelivered -> answer
    weft.PulledOutcome(weft.Completed(_, #(server, response))) ->
      await_dispatch(request, Ok(Handled(server, response)))
    weft.PulledOutcome(weft.Abandoned(_))
    | weft.PulledOutcome(weft.NeverStarted(_)) ->
      await_dispatch(request, Error(RequestTimedOut))
    weft.PulledOutcome(weft.Failed(_, _))
    | weft.PulledOutcome(weft.Crashed(_, _))
    | weft.PulledOutcome(weft.DrainProofLost(_, _))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(_)) ->
      await_dispatch(request, Error(WorkerFailed))
  }
}

fn collect(
  run: weft.Detached(Event, StdioError),
  progress: Progress,
  write: fn(String) -> Result(Nil, Nil),
) -> Result(Option(#(Server, String)), StdioError) {
  case weft.pull(run, within: 1000) {
    weft.NotYet -> collect(run, progress, write)
    weft.RunLost(_) -> Error(WorkerFailed)
    weft.AllDelivered ->
      case progress.server, progress.input {
        Some(server), Next(Some(line)) -> Ok(Some(#(server, line)))
        Some(_), Next(None) -> Ok(None)
        None, _ | _, Unread -> Error(WorkerFailed)
      }
    weft.PulledOutcome(weft.Completed(_, Read(line))) ->
      collect(run, Progress(..progress, input: Next(line)), write)
    weft.PulledOutcome(weft.Completed(_, Handled(server, response))) ->
      case write_response(response, write) {
        Ok(Nil) ->
          collect(run, Progress(..progress, server: Some(server)), write)
        Error(error) -> cancel_and_drain(run, error)
      }
    weft.PulledOutcome(weft.Failed(_, error)) -> cancel_and_drain(run, error)
    weft.PulledOutcome(weft.Abandoned(_))
    | weft.PulledOutcome(weft.NeverStarted(_))
    | weft.PulledOutcome(weft.Crashed(_, _))
    | weft.PulledOutcome(weft.DrainProofLost(_, _))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(_)) ->
      cancel_and_drain(run, WorkerFailed)
  }
}

fn cancel_and_drain(
  run: weft.Detached(Event, StdioError),
  error: StdioError,
) -> Result(a, StdioError) {
  weft.cancel_detached(run)
  drain(run)
  Error(error)
}

fn drain(run: weft.Detached(Event, StdioError)) -> Nil {
  case weft.pull(run, within: 1000) {
    weft.AllDelivered | weft.RunLost(_) -> Nil
    weft.NotYet | weft.PulledOutcome(_) -> drain(run)
  }
}

fn write_response(
  response: Option(JsonValue),
  write: fn(String) -> Result(Nil, Nil),
) -> Result(Nil, StdioError) {
  case response {
    None -> Ok(Nil)
    Some(value) ->
      write(stdio.frame(value)) |> result.map_error(fn(_) { WriteFailed })
  }
}

fn native_read() -> Result(Option(String), StdioError) {
  ffi_stdio.read_line(stdio.max_line_bytes)
  |> result.map_error(fn(error) {
    case error {
      ffi_stdio.LineTooLong -> LineTooLong
      ffi_stdio.ReadFailed -> ReadFailed
    }
  })
}
