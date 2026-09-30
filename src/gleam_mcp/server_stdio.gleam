//// Foreground stdio ownership for the reusable tools server.
////
//// Legacy lifecycle transitions run in order beside one bounded lookahead.
//// Modern requests use a retained coordinator, one reader, one writer and at
//// most eight witnessed handler scopes, so control traffic remains live while
//// callbacks block. Writer backpressure bounds admission to 128 queued frames.
//// EOF stops admission and drains each admitted callback under its existing
//// deadline; read or write failure cancels and joins all owned scopes.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/internal/ffi_stdio
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc
import gleam_mcp/server.{type Server}
import gleam_mcp/stdio
import gleam_mcp/subscription
import weft
import weft/state_machine as sm

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

/// Overrides the request budget within the native timer range.
///
/// Budgets clamp to 1–4,294,966,295 ms so native timers cannot overflow.
///
/// ## Examples
///
/// ```gleam
/// // server_stdio.options() |> server_stdio.with_request_timeout(5000)
/// ```
pub fn with_request_timeout(_options: Options, ms: Int) -> Options {
  Options(request_timeout_ms: int.clamp(ms, 1, 4_294_966_295))
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
    Some(line) ->
      case modern_line(server, line) {
        True -> modern_run(server.modern(server), line, options, read, write)
        False -> serve_line(server, line, options, read, write)
      }
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

// Modern requests keep transport control live while bounded handlers execute.
// A normal coordinator exit proves every witnessed scope has already retired;
// the outer ledger retains this coordinator before admitting the first line.
type ModernPhase {
  Parked
  Accepting
  Ending
}

type ModernEvent {
  Begin
  Input(Result(Option(String), StdioError), process.Subject(Nil))
  Written(Result(Nil, Nil))
  HandlerReady(jsonrpc.Id, process.Subject(Nil))
  Answer(jsonrpc.Id, Option(JsonValue), process.Subject(Nil))
  ScopeDown(process.Pid, process.ExitReason)
  Stop
}

type Handler {
  Handler(
    id: jsonrpc.Id,
    scope: weft.Witnessed,
    answer: Option(Option(JsonValue)),
  )
}

type ModernState {
  ModernState(
    registry: Server,
    first: String,
    timeout: Int,
    read: fn() -> Result(Option(String), StdioError),
    write: fn(String) -> Result(Nil, Nil),
    events: process.Subject(ModernEvent),
    completion: process.Subject(Result(Nil, StdioError)),
    reader: Option(weft.Witnessed),
    writer: Option(weft.Witnessed),
    writer_inbox: Option(process.Subject(String)),
    handlers: List(Handler),
    queued: Int,
    read_gate: Option(process.Subject(Nil)),
    outcome: Result(Nil, StdioError),
  )
}

fn modern_line(registry: Server, line: String) -> Bool {
  case server.is_modern(registry) {
    True -> True
    False ->
      case jsonrpc.decode_modern(line) {
        Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(_, method, params))) ->
          method == "server/discover"
          || method == "subscriptions/listen"
          || case params {
            Some(json.Object(fields)) ->
              result.is_ok(list.key_find(fields, "_meta"))
            None | Some(_) -> False
          }
        _ -> False
      }
  }
}

fn modern_run(
  registry: Server,
  first: String,
  options: Options,
  read: fn() -> Result(Option(String), StdioError),
  write: fn(String) -> Result(Nil, Nil),
) -> Result(Nil, StdioError) {
  let outcomes =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        let completion = process.new_subject()
        use owner <- result.try(
          modern_owner(
            registry,
            first,
            options.request_timeout_ms,
            read,
            write,
            completion,
          )
          |> result.replace_error(WorkerFailed),
        )

        // The actor starts parked, so publication precedes every I/O callback.
        case
          weft.adopt(ledger, owner: owner.pid, cancel: fn() {
            process.send(owner.data, Stop)
          })
        {
          weft.Refused -> Error(WorkerFailed)
          weft.Adopted -> {
            process.send(owner.data, Begin)
            let watch = process.monitor(owner.pid)
            let selector =
              process.new_selector()
              |> process.select_map(completion, fn(answer) { answer })
              |> process.select_specific_monitor(watch, fn(_) {
                Error(WorkerFailed)
              })
            let answer = process.selector_receive_forever(selector)
            process.demonitor_process(watch)
            answer
          }
        }
      }),
    ])
    |> weft.start
  case outcomes {
    [weft.Completed(_, Nil)] -> Ok(Nil)
    [weft.Failed(_, error)] -> Error(error)
    _ -> Error(WorkerFailed)
  }
}

fn modern_owner(
  registry: Server,
  first: String,
  timeout: Int,
  read: fn() -> Result(Option(String), StdioError),
  write: fn(String) -> Result(Nil, Nil),
  completion: process.Subject(Result(Nil, StdioError)),
) -> sm.StartResult(process.Subject(ModernEvent)) {
  sm.new_with_initialiser(5000, fn(events) {
    let state =
      ModernState(
        registry,
        first,
        timeout,
        read,
        write,
        events,
        completion,
        None,
        None,
        None,
        [],
        0,
        None,
        Ok(Nil),
      )
    let selector =
      process.new_selector()
      |> process.select(events)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(_, pid, reason) -> ScopeDown(pid, reason)
          process.PortDown(_, _, reason) -> ScopeDown(process.self(), reason)
        }
      })
    Ok(
      sm.initialised(Parked, state)
      |> sm.selecting(selector)
      |> sm.returning(events),
    )
  })
  |> sm.on_event(modern_event)
  |> sm.unlinked
  |> sm.start
}

fn modern_event(
  phase: ModernPhase,
  state: ModernState,
  event: ModernEvent,
) -> sm.Next(ModernPhase, ModernState, ModernEvent) {
  case phase, event {
    Parked, Begin -> {
      let state = begin_writer(state)
      let state = admit_line(state, state.first)
      let reader =
        weft.new([
          fn() {
            read_lines(state.read, state.events)
            Ok(Nil)
          },
        ])
        |> weft.start_witnessed
      let _ = process.monitor(weft.witness_pid(reader))
      sm.transition(Accepting, ModernState(..state, reader: Some(reader)))
    }
    Parked, Stop -> finish_owner(state)
    Accepting, Input(Ok(Some(line)), gate) -> {
      let state = admit_line(state, line)
      sm.keep(resume_reader(ModernState(..state, read_gate: Some(gate))))
    }
    Accepting, Input(Ok(None), gate) -> {
      process.send(gate, Nil)
      let state = close_subscriptions(state)
      settle_modern(Ending, state)
    }
    Accepting, Input(Error(error), gate) -> {
      process.send(gate, Nil)
      abort_owner(state, error)
    }
    Accepting, Written(Ok(Nil)) ->
      sm.keep(resume_reader(ModernState(..state, queued: state.queued - 1)))
    Ending, Written(Ok(Nil)) ->
      settle_modern(Ending, ModernState(..state, queued: state.queued - 1))
    Accepting, Written(Error(Nil)) | Ending, Written(Error(Nil)) ->
      abort_owner(state, WriteFailed)
    Accepting, HandlerReady(id, gate) | Ending, HandlerReady(id, gate) -> {
      case list.any(state.handlers, fn(handler) { handler.id == id }) {
        True -> process.send(gate, Nil)
        False -> Nil
      }
      sm.keep(state)
    }
    Accepting, Answer(id, answer, gate) | Ending, Answer(id, answer, gate) -> {
      let handlers =
        list.map(state.handlers, fn(handler) {
          case handler.id == id {
            True -> Handler(..handler, answer: Some(answer))
            False -> handler
          }
        })
      process.send(gate, Nil)
      sm.keep(ModernState(..state, handlers:))
    }
    Accepting, ScopeDown(pid, reason) | Ending, ScopeDown(pid, reason) ->
      owner_down(phase, state, pid, reason)
    Accepting, Stop -> abort_owner(state, WorkerFailed)
    Ending, Stop -> abort_owner(state, WorkerFailed)
    Parked, Input(_, _)
    | Parked, Written(_)
    | Parked, HandlerReady(_, _)
    | Parked, Answer(_, _, _)
    | Parked, ScopeDown(_, _)
    | Accepting, Begin
    | Ending, Begin
    | Ending, Input(_, _)
    -> sm.keep(state)
  }
}

fn begin_writer(state: ModernState) -> ModernState {
  let ready = process.new_subject()
  let writer =
    weft.new([
      fn() {
        let inbox = process.new_subject()
        process.send(ready, inbox)
        write_lines(state.write, inbox, state.events)
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  let inbox = process.receive_forever(ready)
  let _ = process.monitor(weft.witness_pid(writer))
  ModernState(..state, writer: Some(writer), writer_inbox: Some(inbox))
}

fn read_lines(
  read: fn() -> Result(Option(String), StdioError),
  events: process.Subject(ModernEvent),
) -> Nil {
  let gate = process.new_subject()
  let input = read()
  process.send(events, Input(input, gate))
  let Nil = process.receive_forever(gate)
  case input {
    Ok(Some(_)) -> {
      read_lines(read, events)
    }
    Ok(None) | Error(_) -> Nil
  }
}

fn write_lines(
  write: fn(String) -> Result(Nil, Nil),
  inbox: process.Subject(String),
  events: process.Subject(ModernEvent),
) -> Nil {
  let frame = process.receive_forever(inbox)
  let outcome = write(frame)
  process.send(events, Written(outcome))
  case outcome {
    Ok(Nil) -> write_lines(write, inbox, events)
    Error(Nil) -> Nil
  }
}

fn admit_line(state: ModernState, line: String) -> ModernState {
  case jsonrpc.decode_modern(line) {
    Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(id, "tools/call", _))) ->
      admit_handler(state, id, line)
    Ok(jsonrpc.Correlated(jsonrpc.Notification(
      "notifications/cancelled",
      params,
    ))) -> {
      let state = cancel_handler(state, params)
      let #(registry, _) = server.handle_line(state.registry, line)
      ModernState(..state, registry:)
    }
    _ -> {
      let #(registry, response) = server.handle_line(state.registry, line)
      enqueue(ModernState(..state, registry:), response)
    }
  }
}

fn admit_handler(
  state: ModernState,
  id: jsonrpc.Id,
  line: String,
) -> ModernState {
  case
    list.length(state.handlers) >= 8
    || list.any(state.handlers, fn(handler) { handler.id == id })
  {
    True ->
      enqueue(
        state,
        Some(jsonrpc.error_response(
          Some(id),
          jsonrpc.RpcError(-32_000, "request admission unavailable", None),
        )),
      )
    False -> {
      let scope =
        weft.new([
          fn() {
            let gate = process.new_subject()
            process.send(state.events, HandlerReady(id, gate))
            let Nil = process.receive_forever(gate)
            let #(_, response) = server.handle_line(state.registry, line)
            let settled = process.new_subject()
            process.send(state.events, Answer(id, response, settled))
            let Nil = process.receive_forever(settled)
            Ok(Nil)
          },
        ])
        |> weft.deadline(state.timeout)
        |> weft.start_witnessed
      let _ = process.monitor(weft.witness_pid(scope))

      // The ready event cannot open the callback until this handle is retained.
      ModernState(..state, handlers: [
        Handler(id, scope, None),
        ..state.handlers
      ])
    }
  }
}

fn cancel_handler(
  state: ModernState,
  params: Option(JsonValue),
) -> ModernState {
  let id = case params {
    Some(json.Object(fields)) ->
      case list.key_find(fields, "requestId") {
        Ok(json.Int(id)) -> Some(jsonrpc.IdInt(id))
        Ok(json.String(id)) -> Some(jsonrpc.IdString(id))
        _ -> None
      }
    None | Some(_) -> None
  }
  list.each(state.handlers, fn(handler) {
    case Some(handler.id) == id {
      True -> weft.cancel_witnessed(handler.scope)
      False -> Nil
    }
  })
  state
}

fn enqueue(state: ModernState, response: Option(JsonValue)) -> ModernState {
  case response, state.writer_inbox {
    None, _ | _, None -> state
    Some(response), Some(inbox) -> {
      process.send(inbox, stdio.frame(response))
      ModernState(..state, queued: state.queued + 1)
    }
  }
}

fn close_subscriptions(state: ModernState) -> ModernState {
  list.fold(server.subscriptions(state.registry), state, fn(state, id) {
    enqueue(state, Some(subscription.closed(id)))
  })
}

fn owner_down(
  phase: ModernPhase,
  state: ModernState,
  pid: process.Pid,
  reason: process.ExitReason,
) -> sm.Next(ModernPhase, ModernState, ModernEvent) {
  let reader =
    option.is_some(state.reader)
    && option.map(state.reader, weft.witness_pid) == Some(pid)
  let writer =
    option.is_some(state.writer)
    && option.map(state.writer, weft.witness_pid) == Some(pid)
  let handler =
    list.find(state.handlers, fn(handler) {
      weft.witness_pid(handler.scope) == pid
    })
  case reader, writer, handler {
    True, _, _ ->
      case phase {
        Accepting ->
          abort_owner(ModernState(..state, reader: None), WorkerFailed)
        Ending -> settle_modern(phase, ModernState(..state, reader: None))
        Parked -> sm.keep(state)
      }
    _, True, _ -> {
      let state = ModernState(..state, writer: None, writer_inbox: None)
      case phase, state.queued {
        Ending, 0 -> settle_modern(phase, state)
        _, _ -> abort_owner(state, WriteFailed)
      }
    }
    _, _, Ok(handler) -> {
      let state =
        ModernState(
          ..state,
          handlers: list.filter(state.handlers, fn(entry) {
            entry.id != handler.id
          }),
        )
      let response = case state.outcome, handler.answer {
        Ok(Nil), Some(response) if reason == process.Normal -> response
        Error(_), _ -> None
        _, _ ->
          Some(jsonrpc.error_response(
            Some(handler.id),
            jsonrpc.RpcError(-32_000, "request did not complete", None),
          ))
      }
      settle_modern(phase, enqueue(state, response))
    }
    False, False, Error(Nil) -> sm.keep(state)
  }
}

fn settle_modern(
  phase: ModernPhase,
  state: ModernState,
) -> sm.Next(ModernPhase, ModernState, ModernEvent) {
  case
    phase == Ending
    && state.handlers == []
    && state.reader == None
    && state.queued == 0
  {
    True ->
      case state.writer {
        Some(writer) -> {
          weft.cancel_witnessed(writer)
          sm.transition(Ending, state)
        }
        None -> finish_owner(state)
      }
    False -> sm.transition(phase, state)
  }
}

fn abort_owner(
  state: ModernState,
  error: StdioError,
) -> sm.Next(ModernPhase, ModernState, ModernEvent) {
  option.map(state.reader, weft.cancel_witnessed)
  option.map(state.writer, weft.cancel_witnessed)
  list.each(state.handlers, fn(handler) { weft.cancel_witnessed(handler.scope) })
  let state = ModernState(..state, outcome: Error(error), queued: 0)
  case state.reader == None && state.writer == None && state.handlers == [] {
    True -> finish_owner(state)
    False -> sm.transition(Ending, state)
  }
}

fn finish_owner(
  state: ModernState,
) -> sm.Next(ModernPhase, ModernState, ModernEvent) {
  process.send(state.completion, state.outcome)
  sm.stop()
}

fn resume_reader(state: ModernState) -> ModernState {
  case state.read_gate, state.queued < 128 {
    Some(gate), True -> {
      process.send(gate, Nil)
      ModernState(..state, read_gate: None)
    }
    None, _ | _, False -> state
  }
}
