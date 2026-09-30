//// The MCP client actor: one explicitly owned long-lived process owning one
//// MCP server peer over the stdio transport, driving the initialize
//// lifecycle and serving typed calls — list every tool, call a tool.
////
//// The actor is written against `gleam_mcp/transport.Transport`, so whether
//// the server process is a real child on an Erlang port or an
//// in-process test peer is the injector's decision; see that module for
//// why the seam exists and for the security posture of spawning.
////
//// ## The v1 posture (issue #106)
////
//// **No restart, no reconnect.** A dead peer — the process exited, the
//// transport closed, a framing fault poisoned the line stream — settles
//// every in-flight call as `Unavailable` and latches the client dead
//// for the session; later calls answer `Unavailable` in-band without
//// crashing anything. The supervised substrate grows reconnection teeth
//// in phase 5 (the LSP client, issue #25), not here.
////
//// **No server-initiated anything.** This client declares an empty
//// capabilities object (see `gleam_mcp/protocol.initialize_request` for why
//// that is a security decision), so a server-initiated *request* —
//// sampling, roots, elicitation, whatever else — is answered in-band
//// with JSON-RPC method-not-found (-32601), and a server *notification*
//// is decoded and dropped.
////
//// ## Faults are values, and the envelope decides which are fatal
////
//// The posture mirrors the cap channel's: a line that is not a
//// well-formed JSON-RPC message, a byte stream that is not UTF-8, and a
//// line past `gleam_mcp/stdio.max_line_bytes` are channel-fatal — every
//// in-flight call settles at once and the client latches dead — while
//// well-formed messages this client merely does not act on (an unknown
//// or forgotten response id, a notification) are dropped and the
//// channel stays open. Nothing here panics; every fault is a value.
////
//// ## Callers are never killed by a slow or dead actor
////
//// Every public call is a monitored send-and-select (the
//// `broker/internal/call.try_call` shape), never `process.call`, which
//// panics on a timeout and on a dead callee. A dead client answers
//// `Unavailable`; a wedged one answers `Unavailable` after the call's
//// own deadline plus a small margin. Each in-flight call carries its
//// own deadline inside the actor too: at expiry the caller gets a typed
//// `CallTimedOut` and the actor forgets the id, so a late response to a
//// forgotten id is dropped silently.
////
//// `prepare` parks the owner before transport opening. After external custody
//// is published, `connect` opens the transport in that same owner. Stopping
//// settles calls immediately but retains the exact port until native exit.
//// Typed `shutdown` then consumes explicit retirement proof and observes the
//// original normal actor DOWN. A deadline or unexpected owner death cannot
//// substitute for either proof.

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam_mcp/codec
import gleam_mcp/corruption
import gleam_mcp/discovery
import gleam_mcp/internal/ffi_request
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc.{type Id}
import gleam_mcp/metadata
import gleam_mcp/mrtr
import gleam_mcp/protocol.{type CallToolResult, type ToolDescriptor}
import gleam_mcp/request as requests
import gleam_mcp/schema
import gleam_mcp/stdio
import gleam_mcp/subscription
import gleam_mcp/tool as definition
import gleam_mcp/transport.{type Transport}
import gleam_mcp/version
import weft
import weft/poll
import weft/state_machine as sm

/// How long parked actor preparation or transport opening may take before
/// the caller reports startup failure.
///
/// Preparation and opening each use this budget; the handshake uses
/// `Options.handshake_timeout_ms`. The convenience `start` wrapper also
/// spends this budget verifying cleanup when startup fails.
pub const init_timeout_ms = 5000

/// Slack added to a call's own deadline before the caller gives up
/// waiting for the actor to answer: the actor enforces the real deadline
/// with a typed `CallTimedOut`, so this only guards against a wholly
/// wedged client.
const reply_margin_ms = 1000

/// The default `initialize` → `initialized` handshake budget.
pub const default_handshake_timeout_ms = 10_000

/// The most `tools/list` pages `list_tools` will follow before refusing
/// with `TooManyPages`: a hostile server re-issuing a `nextCursor`
/// forever must not loop the harness.
pub const max_tool_pages = 64

/// JSON-RPC's method-not-found code, the in-band answer to every
/// server-initiated request.
pub const method_not_found_code = -32_601

/// An opaque handle to a started client actor. Sendable across
/// processes; every public function takes one.
pub opaque type Client {
  Client(subject: Subject(Msg), owner: process.Pid)
}

/// Why a shutdown could not establish both transport retirement and actor exit.
pub type RetirementError {
  /// The caller's reporting budget elapsed; the owner still retains custody.
  RetirementTimedOut

  /// The owner disappeared before returning explicit retirement evidence.
  RetirementUnconfirmed
}

type RetirementProof {
  NoNativeResource
  NativeExited(reason: String)
}

type Phase {
  Prepared
  Serving
  Closing
  Retired(proof: RetirementProof)
}

type Custody {
  Held
  Lost
}

/// Options for `start`.
///
/// Constructor invariants: `handshake_timeout_ms` is a positive
/// millisecond budget for the whole `initialize` round trip;
/// `client_version` is the caller's version, carried verbatim in
/// `clientInfo`.
pub type Options {
  Options(
    /// The caller-owned name advertised in clientInfo.
    client_name: String,
    /// The caller-owned version advertised in clientInfo.
    client_version: String,
    /// The positive budget for initialize.
    handshake_timeout_ms: Int,
  )
}

/// Options with the default handshake budget.
///
/// ## Examples
///
/// ```gleam
/// assert client.options("0.1.0").handshake_timeout_ms
///   == client.default_handshake_timeout_ms
/// ```
///
pub fn options(client_version: String) -> Options {
  Options(
    client_name: "gleam-mcp",
    client_version:,
    handshake_timeout_ms: default_handshake_timeout_ms,
  )
}

/// Sets the caller-owned name sent in the initialize exchange.
///
/// ## Examples
///
/// ```gleam
/// assert client.options("1.0.0") |> client.with_client_name("loom")
///   |> fn(options) { options.client_name } == "loom"
/// ```
pub fn with_client_name(options: Options, name: String) -> Options {
  Options(..options, client_name: name)
}

/// Overrides the handshake budget.
///
/// ## Examples
///
/// ```gleam
/// assert client.options("0.1.0")
///   |> client.with_handshake_timeout(500)
///   == client.Options(client_version: "0.1.0", handshake_timeout_ms: 500)
/// ```
///
pub fn with_handshake_timeout(options: Options, ms: Int) -> Options {
  // Clamped to at least one millisecond: a non-positive delay would
  // reach process.send_after, which raises on negatives.
  Options(..options, handshake_timeout_ms: int.max(ms, 1))
}

/// Why a call produced no usable result. Plain data, always in-band:
/// no variant here is ever a caller's crash.
pub type ClientError {
  /// The client (or the server it owned) is not available: the peer
  /// died, the transport closed, a framing fault latched the client
  /// dead, or the actor itself is gone. `reason` names which.
  Unavailable(reason: String)

  /// The call did not complete within its own deadline. The id is
  /// forgotten; a response arriving later is dropped silently.
  CallTimedOut(after_ms: Int)

  /// The server answered the call with a JSON-RPC error.
  ServerError(code: Int, message: String)

  /// The server's result was well-formed JSON-RPC but not the shape the
  /// method promises; `reason` names the field that broke it.
  ResultMalformed(reason: String)

  /// `tools/list` pagination did not exhaust within `max_tool_pages`
  /// pages; `cap` restates the ceiling that was hit.
  TooManyPages(cap: Int)
}

/// Why startup produced no serving client. Staged startup retains the owner
/// after a refusal so its published custodian can verify native retirement.
pub type StartError {
  /// The transport could not open — the server executable did not
  /// spawn, or the actor could not start.
  TransportFailed(reason: String)

  /// The `initialize` exchange itself failed: a server error, a
  /// malformed result, a closed transport, or the handshake deadline.
  HandshakeFailed(error: ClientError)

  /// The server negotiated a protocol revision this client cannot
  /// speak. Carries both sides so the refusal can be worded without
  /// re-asking.
  VersionUnsupported(server: String, supported: List(String))

  /// The server did not declare the tools capability, and tools are the
  /// only thing this client exists to reach.
  ToolsNotDeclared

  /// Startup failed and retirement is uncertain; retain this client's custody.
  CleanupUnconfirmed(client: Client)
}

/// The client actor's message set. Opaque: only this module constructs
/// these, so nothing can inject a forged response or expiry.
pub opaque type Msg {
  /// Opens the already-published client transport, exactly once.
  Open(reply: Subject(Result(Nil, StartError)))

  /// The preparer disappeared before admitting native work.
  PreparerGone

  /// The published cleanup owner can no longer claim retirement evidence.
  CustodianGone

  /// Requests retirement proof before the owning actor may stop normally.
  Retire(reply: Subject(RetirementProof))

  /// One outbound request: `build` receives the actor-minted id and
  /// returns the full JSON-RPC message; the correlated result (or the
  /// typed error) is sent to `reply`.
  Request(
    build: fn(Id) -> JsonValue,
    deadline_ms: Int,
    reply: Subject(Result(JsonValue, ClientError)),
  )

  /// A modern request retains its exact envelope correlation and observer.
  RawRequest(outbound: requests.Outbound, reply: Subject(RawEvent))

  /// The owner of a modern request disappeared before its response settled.
  RawCallerGone(monitor: process.Monitor)

  /// Explicit cancellation identifies the caller's original request id.
  CancelRaw(id: Id)

  /// One outbound notification, fire-and-forget.
  Notify(message: JsonValue)

  /// Inbound bytes or the close, from the port selector or a test peer.
  FromTransport(event: transport.TransportEvent)

  /// A call's deadline lapsed; if the id is still in flight the caller
  /// is answered `CallTimedOut` and the id is forgotten.
  Expire(id: Int)

  /// Requests termination and settles calls, retaining the native-exit proof
  /// until `Retire` transfers it to the custodian.
  Shutdown
}

type InFlight {
  InFlight(reply: Reply, deadline_ms: Int)
}

type Reply {
  LegacyReply(Subject(Result(JsonValue, ClientError)))
  ModernReply(
    original_id: Id,
    reply: Subject(RawEvent),
    monitor: process.Monitor,
    stream: Option(subscription.Stream),
  )
}

type RawEvent {
  RawNotification(JsonValue)
  RawResult(Result(JsonValue, requests.Error))
}

type State {
  State(
    transport_spec: Option(Transport),
    inbound: Subject(transport.TransportEvent),
    selector: process.Selector(Msg),
    connection: transport.Connection,
    buffer: stdio.Buffer,
    // The held tail of an incomplete UTF-8 sequence between chunks; at
    // most `transport.max_held_tail_bytes` bytes.
    tail: BitArray,
    next_id: Int,
    inflight: Dict(Int, InFlight),
    // `Some(reason)` once the peer is gone: no response can arrive, so
    // new calls are refused in-band rather than waiting out deadlines.
    dead: Option(String),
    commands: Subject(Msg),
    custody: Custody,
  )
}

// --- public API -------------------------------------------------------------

/// Starts the client: opens the transport (spawning the server, for a
/// port transport), performs `initialize` → `notifications/initialized`
/// against `protocol.requested_version`, and refuses a server negotiating a version outside
/// `protocol.supported_versions()` or one not declaring the tools
/// capability. The whole handshake is bounded by
/// `options.handshake_timeout_ms`. Refusal retires the actor only after
/// explicit transport evidence; otherwise `CleanupUnconfirmed` returns its
/// handle so the caller cannot discard uncertain cleanup ownership.
///
/// ## Examples
///
/// ```gleam
/// // client.start(transport.PortTransport(spawn), client.options("0.1.0"))
/// ```
///
pub fn start(
  transport_spec: Transport,
  options: Options,
) -> Result(Client, StartError) {
  use client <- result.try(prepare(transport_spec))
  case connect(client, options) {
    Ok(Nil) -> Ok(client)
    Error(error) -> {
      case shutdown(client, within: init_timeout_ms) {
        Ok(Nil) -> Error(error)
        Error(_) -> Error(CleanupUnconfirmed(client))
      }
    }
  }
}

/// Prepares an actor without opening a transport or executing third-party code.
/// Publish its cleanup capability before calling `connect`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(client) = client.prepare(transport)
/// // publish(fn() { client.shutdown(client, within: 5000) })
/// ```
@internal
pub fn prepare(transport_spec: Transport) -> Result(Client, StartError) {
  prepare_owned(transport_spec, process.self())
}

/// Prepares a client whose cleanup lifetime belongs to a separate custodian.
/// A dead builder cannot discard the parked client's no-resource proof.
///
/// ## Examples
///
/// ```gleam
/// // client.prepare_owned(transport, instance_owner)
/// ```
@internal
pub fn prepare_owned(
  transport_spec: Transport,
  custodian: process.Pid,
) -> Result(Client, StartError) {
  start_actor(transport_spec, custodian)
  |> result.map_error(fn(error) {
    TransportFailed(reason: describe_start_error(error))
  })
}

/// Opens a published client and negotiates its MCP handshake.
/// A refusal leaves the client in the caller's cleanup census.
///
/// ## Examples
///
/// ```gleam
/// // client.connect(prepared, client.options("0.1.0"))
/// ```
@internal
pub fn connect(client: Client, options: Options) -> Result(Nil, StartError) {
  use Nil <- result.try(
    exchange(client.subject, init_timeout_ms, Open)
    |> result.map_error(fn(error) { HandshakeFailed(error) })
    |> result.flatten,
  )
  case handshake(client, options) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      stop(client)
      Error(error)
    }
  }
}

/// Returns the actor whose normal retirement follows explicit transport proof.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(client.pid(prepared))
/// ```
@internal
pub fn pid(client: Client) -> process.Pid {
  client.owner
}

/// Retires a client after explicit no-resource or native-exit evidence.
/// The monitor is installed before requesting proof, so a later normal DOWN
/// belongs to this retirement attempt. Missing evidence never becomes success.
/// Both receives share one monotonic deadline.
///
/// ## Examples
///
/// ```gleam
/// // client.shutdown(prepared, within: 5000)
/// ```
@internal
pub fn shutdown(
  client: Client,
  within within: Int,
) -> Result(Nil, RetirementError) {
  let clock = poll.monotonic()
  let deadline = clock.now() + int.max(within, 0)
  let watch = process.monitor(client.owner)
  let proofs = process.new_subject()
  process.send(client.subject, Retire(proofs))

  // The first event must carry the owner's explicit resource evidence.
  // Actor death by itself says nothing about the native process it owned.
  let proof =
    process.new_selector()
    |> process.select_map(proofs, Ok)
    |> process.select_specific_monitor(watch, fn(_) {
      Error(RetirementUnconfirmed)
    })
    |> process.selector_receive(int.max(deadline - clock.now(), 0))
    |> result.replace_error(RetirementTimedOut)
    |> result.flatten
  let answer = case proof {
    Error(error) -> Error(error)
    Ok(NoNativeResource) | Ok(NativeExited(_)) -> {
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) {
        case down.reason {
          process.Normal -> Ok(Nil)
          process.Abnormal(_) | process.Killed -> Error(RetirementUnconfirmed)
        }
      })
      |> process.selector_receive(int.max(deadline - clock.now(), 0))
      |> result.replace_error(RetirementTimedOut)
      |> result.flatten
    }
  }
  process.demonitor_process(watch)
  answer
}

/// Lists every tool the server declares, following `nextCursor`
/// pagination to exhaustion. `timeout_ms` bounds each page's round
/// trip; the page count is bounded by `max_tool_pages`, so the whole
/// listing is bounded even against a hostile server.
///
/// ## Examples
///
/// ```gleam
/// // client.list_tools(client, 5000)
/// ```
///
pub fn list_tools(
  client: Client,
  timeout_ms: Int,
) -> Result(List(ToolDescriptor), ClientError) {
  // Transient memory is bounded but not small: up to `max_tool_pages`
  // pages of up to `stdio.max_line_bytes` each accumulate before the
  // listing flattens — a ceiling near a gigabyte, documented as the
  // decision rather than hidden. `timeout_ms` is clamped to at least
  // one millisecond; process.send_after raises on negatives.
  list_pages(client, int.max(timeout_ms, 1), None, [], max_tool_pages)
}

/// Calls one tool by its server-declared name. `arguments` is passed
/// through raw; the caller owns conformance to the tool's input schema.
///
/// ## Examples
///
/// ```gleam
/// // client.call_tool(client, "echo", json.Object([]), 5000)
/// ```
///
pub fn call_tool(
  client: Client,
  name: String,
  arguments: JsonValue,
  timeout_ms: Int,
) -> Result(CallToolResult, ClientError) {
  // Clamped for the same reason as list_tools: send_after raises on a
  // negative delay, and a config typo should not kill the client.
  use value <- result.try(
    request(client, int.max(timeout_ms, 1), protocol.call_tool_request(
      _,
      name,
      arguments,
    )),
  )
  protocol.decode_call_tool_result(value)
  |> result.map_error(malformed)
}

/// Requests transport termination and settles calls as `Unavailable`.
/// The actor retains native-exit evidence until typed `shutdown` retires it.
/// Sending this request alone does not establish cleanup completion.
///
/// ## Examples
///
/// ```gleam
/// // client.stop(client)
/// // client.shutdown(client, within: 5000)
/// ```
pub fn stop(client: Client) -> Nil {
  process.send(client.subject, Shutdown)
}

// --- the handshake ----------------------------------------------------------

fn handshake(client: Client, options: Options) -> Result(Nil, StartError) {
  use value <- result.try(
    request(
      client,
      options.handshake_timeout_ms,
      protocol.initialize_request_with_name(
        _,
        options.client_name,
        options.client_version,
      ),
    )
    |> result.map_error(fn(error) { HandshakeFailed(error:) }),
  )
  use init <- result.try(accept_initialize(value))
  use _tools <- result.try(case init.tools {
    Some(tools) -> Ok(tools)
    None -> Error(ToolsNotDeclared)
  })
  process.send(client.subject, Notify(message: protocol.initialized()))
  Ok(Nil)
}

fn accept_initialize(
  value: JsonValue,
) -> Result(protocol.InitializeResult, StartError) {
  case protocol.decode_initialize_result(value) {
    Ok(init) -> Ok(init)
    Error(protocol.UnsupportedVersion(server:, supported:)) ->
      Error(VersionUnsupported(server:, supported:))
    Error(protocol.BadResult(reason:)) ->
      Error(HandshakeFailed(error: ResultMalformed(reason:)))
  }
}

// --- the caller side --------------------------------------------------------

// Follows tools/list pagination, newest page prepended, flattened once
// at exhaustion. `remaining` counts down from `max_tool_pages`.
fn list_pages(
  client: Client,
  timeout_ms: Int,
  cursor: Option(String),
  pages: List(List(ToolDescriptor)),
  remaining: Int,
) -> Result(List(ToolDescriptor), ClientError) {
  use <- bool.guard(
    when: remaining <= 0,
    return: Error(TooManyPages(cap: max_tool_pages)),
  )
  use value <- result.try(
    request(client, timeout_ms, protocol.list_tools_request(_, cursor)),
  )
  use page <- result.try(
    protocol.decode_tools_page(value)
    |> result.map_error(malformed),
  )
  let pages = [page.tools, ..pages]
  case page.next_cursor {
    None -> Ok(list.flatten(list.reverse(pages)))
    Some(next) ->
      list_pages(client, timeout_ms, Some(next), pages, remaining - 1)
  }
}

// One correlated request through the actor. The wait is the call's own
// deadline plus a margin: the actor answers `CallTimedOut` at the
// deadline itself, so the margin only guards against a wedged actor.
fn request(
  client: Client,
  timeout_ms: Int,
  build: fn(Id) -> JsonValue,
) -> Result(JsonValue, ClientError) {
  exchange(client.subject, timeout_ms + reply_margin_ms, fn(reply) {
    Request(build:, deadline_ms: timeout_ms, reply:)
  })
  |> result.flatten
}

// A `process.call` that answers instead of crashing — the
// `broker/internal/call.try_call` shape, reproduced here because this
// package deliberately does not depend on the broker. The caller of a
// tool call holds a verdict its death would lose; a dead or wedged
// client must answer `Unavailable`, never exit the asker. The cost of
// not crashing is one stale message: a reply arriving after the wait
// sits in the caller's mailbox as an inert term, bounded by the number
// of faulty exchanges.
fn exchange(
  subject: Subject(Msg),
  waiting: Int,
  make: fn(Subject(reply)) -> Msg,
) -> Result(reply, ClientError) {
  // A subject whose owner is gone has nobody to answer; the monitor
  // below covers the owner dying after this check.
  case process.subject_owner(subject) {
    Error(Nil) -> Error(Unavailable(reason: "mcp client is not running"))
    Ok(owner) -> {
      let reply_subject = process.new_subject()
      let monitor = process.monitor(owner)
      process.send(subject, make(reply_subject))
      let answer =
        process.new_selector()
        |> process.select_map(reply_subject, Ok)
        |> process.select_specific_monitor(monitor, fn(_down) {
          Error(Unavailable(reason: "mcp client is not running"))
        })
        |> process.selector_receive(waiting)

      // Demonitoring flushes a DOWN that arrived after the wait, so the
      // only thing this exchange can leave behind is a late reply.
      process.demonitor_process(monitor)
      result.lazy_unwrap(answer, fn() {
        Error(Unavailable(reason: "mcp client did not answer"))
      })
    }
  }
}

fn malformed(fault: protocol.ProtocolFault) -> ClientError {
  case fault {
    protocol.BadResult(reason:) -> ResultMalformed(reason:)

    // Unreachable outside `initialize` (only its decoder checks the
    // version), but the type is shared, so it settles as data too.
    protocol.UnsupportedVersion(server:, ..) ->
      ResultMalformed(reason: "unsupported protocol version " <> server)
  }
}

fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "mcp client initialiser timed out"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "mcp client exited during initialisation"
  }
}

// --- the actor --------------------------------------------------------------

fn start_actor(
  transport_spec: Transport,
  custodian: process.Pid,
) -> Result(Client, actor.StartError) {
  let preparer = process.self()
  sm.new_with_initialiser(init_timeout_ms, fn(commands) {
    let inbound = process.new_subject()
    let base =
      process.new_selector()
      |> process.select(commands)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(monitor, _, _)
          | process.PortDown(monitor, _, _) -> RawCallerGone(monitor)
        }
      })
      |> process.select_map(inbound, FromTransport)
      |> process.select_specific_monitor(process.monitor(preparer), fn(_) {
        PreparerGone
      })
      |> process.select_specific_monitor(process.monitor(custodian), fn(_) {
        CustodianGone
      })
    let state =
      State(
        transport_spec: Some(transport_spec),
        inbound:,
        selector: base,
        connection: inert_connection(),
        buffer: stdio.new(),
        tail: <<>>,
        next_id: 1,
        inflight: dict.new(),
        dead: None,
        commands:,
        custody: Held,
      )
    sm.initialised(Prepared, state)
    |> sm.selecting(base)
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(handle)
  |> sm.unlinked
  |> sm.start
  |> result.map(fn(started) {
    Client(subject: started.data, owner: started.pid)
  })
}

fn handle(phase: Phase, state: State, msg: Msg) -> sm.Next(Phase, State, Msg) {
  case phase, msg {
    Prepared, Open(reply) -> open_transport(state, reply)
    Prepared, PreparerGone | Prepared, Shutdown ->
      sm.transition(
        Retired(NoNativeResource),
        State(..state, transport_spec: None, dead: Some("mcp client stopped")),
      )

    // A parked client owns no native process. Once neither builder nor
    // custodian can use it, retaining its empty proof would leak an actor.
    Prepared, CustodianGone | Retired(_), CustodianGone -> sm.stop()
    Serving, CustodianGone ->
      begin_close(State(..state, custody: Lost), "mcp custodian stopped")
    Closing, CustodianGone -> sm.keep(State(..state, custody: Lost))
    Prepared, Retire(reply) -> {
      process.send(reply, NoNativeResource)
      sm.stop()
    }
    Serving, PreparerGone | Closing, PreparerGone | Retired(_), PreparerGone ->
      sm.keep(state)
    Serving, Open(reply) | Closing, Open(reply) | Retired(_), Open(reply) -> {
      process.send(reply, Error(TransportFailed("mcp client already opened")))
      sm.keep(state)
    }
    Serving, Shutdown -> begin_close(state, "mcp client stopped")
    Closing, Shutdown | Retired(_), Shutdown -> sm.keep(state)
    Serving, Retire(_) ->
      begin_close(state, "mcp client stopped") |> sm.postpone
    Closing, Retire(_) -> sm.keep(state) |> sm.postpone
    Retired(proof), Retire(reply) -> {
      process.send(reply, proof)
      sm.stop()
    }
    Prepared, Request(reply:, ..) -> {
      process.send(reply, Error(Unavailable("mcp client has not opened")))
      sm.keep(state)
    }
    Prepared, RawRequest(reply:, ..) -> {
      process.send(
        reply,
        RawResult(Error(requests.TransportFailed("mcp client has not opened"))),
      )
      sm.keep(state)
    }
    Prepared, Notify(_)
    | Prepared, FromTransport(_)
    | Prepared, Expire(_)
    | Prepared, RawCallerGone(_)
    | Prepared, CancelRaw(_)
    -> sm.keep(state)
    Serving, other | Closing, other | Retired(_), other ->
      handle_opened(state, other)
  }
}

// The actor owns the port from its first native instruction. This handler
// runs only after the caller has published custody for every parked client.
fn open_transport(
  state: State,
  reply: Subject(Result(Nil, StartError)),
) -> sm.Next(Phase, State, Msg) {
  let opened = case state.transport_spec {
    Some(spec) ->
      transport.open(spec, state.inbound, state.selector, FromTransport)
    None -> Error("mcp transport specification already consumed")
  }

  // Environment values are needed only for spawn. Do not retain the original
  // specification in the resident client after success or failure.
  let state = State(..state, transport_spec: None)
  case opened {
    Error(reason) -> {
      process.send(reply, Error(TransportFailed(reason)))
      sm.transition(
        Retired(NoNativeResource),
        State(..state, dead: Some(reason)),
      )
    }
    Ok(#(connection, selector)) -> {
      process.send(reply, Ok(Nil))
      sm.transition(Serving, State(..state, connection:))
      |> sm.with_selector(selector)
    }
  }
}

fn handle_opened(state: State, msg: Msg) -> sm.Next(Phase, State, Msg) {
  case msg {
    Request(build:, deadline_ms:, reply:) ->
      handle_request(state, build, deadline_ms, reply)
    RawRequest(outbound, reply) -> handle_raw_request(state, outbound, reply)
    RawCallerGone(monitor) ->
      cancel_matching(state, fn(reply) {
        case reply {
          ModernReply(monitor: found, ..) -> found == monitor
          LegacyReply(_) -> False
        }
      })
    CancelRaw(id) ->
      cancel_matching(state, fn(reply) {
        case reply {
          ModernReply(original_id: found, ..) -> found == id
          LegacyReply(_) -> False
        }
      })
    Notify(message:) -> handle_notify(state, message)
    FromTransport(transport.TransportData(bytes:)) -> handle_data(state, bytes)
    FromTransport(transport.TransportClosed(reason:)) ->
      handle_closed(state, reason)
    Expire(id:) -> handle_expire(state, id)
    Open(_) | PreparerGone | CustodianGone | Retire(_) | Shutdown ->
      sm.keep(state)
  }
}

// A caller asked for one request. A dead client refuses in-band at
// once; otherwise the id is minted, the call tracked with its own
// deadline, and the frame written — a failed write is the peer gone.
fn handle_request(
  state: State,
  build: fn(Id) -> JsonValue,
  deadline_ms: Int,
  reply: Subject(Result(JsonValue, ClientError)),
) -> sm.Next(Phase, State, Msg) {
  case state.dead {
    Some(reason) -> {
      process.send(reply, Error(Unavailable(reason:)))
      sm.keep(state)
    }
    None -> {
      let id = state.next_id
      let message = build(jsonrpc.IdInt(id))
      let inflight =
        dict.insert(
          state.inflight,
          id,
          InFlight(reply: LegacyReply(reply), deadline_ms:),
        )
      let state = State(..state, next_id: id + 1, inflight:)
      case state.connection.send(stdio.frame(message)) {
        Ok(Nil) -> {
          let _ = process.send_after(state.commands, deadline_ms, Expire(id:))
          sm.keep(state)
        }

        // The call was tracked before the write, so `die` settles this
        // caller along with every other in-flight one.
        Error(Nil) -> begin_close(state, "mcp transport write failed")
      }
    }
  }
}

fn handle_notify(
  state: State,
  message: JsonValue,
) -> sm.Next(Phase, State, Msg) {
  case state.dead {
    Some(_) -> sm.keep(state)
    None ->
      case state.connection.send(stdio.frame(message)) {
        Ok(Nil) -> sm.keep(state)
        Error(Nil) -> begin_close(state, "mcp transport write failed")
      }
  }
}

// Inbound bytes: reassemble UTF-8 across chunk boundaries, frame into
// lines, and act on each complete line. A stream that is not UTF-8 or a
// line past the framing cap is channel-fatal. A dead client drains the
// wire without acting on it.
fn handle_data(state: State, bytes: BitArray) -> sm.Next(Phase, State, Msg) {
  case state.dead {
    Some(_) -> sm.keep(state)
    None -> feed_chunk(state, bytes)
  }
}

fn feed_chunk(state: State, bytes: BitArray) -> sm.Next(Phase, State, Msg) {
  case transport.utf8_prefix(bit_array.append(state.tail, bytes)) {
    Error(Nil) -> begin_close(state, "mcp server bytes are not utf-8")
    Ok(#(text, tail)) -> {
      let state = State(..state, tail:)
      case stdio.push(state.buffer, text) {
        Error(stdio.LineTooLong(limit:, seen:)) ->
          begin_close(
            state,
            "mcp server line exceeded "
              <> int.to_string(limit)
              <> " bytes ("
              <> int.to_string(seen)
              <> " seen)",
          )
        Ok(#(buffer, lines)) -> feed_lines(State(..state, buffer:), lines)
      }
    }
  }
}

fn handle_closed(state: State, reason: String) -> sm.Next(Phase, State, Msg) {
  // The peer is already gone: replace the connection with an inert one
  // before `die` closes it, so a port close never chases the exited
  // child's (possibly recycled) OS pid with a kill.
  let state = die(State(..state, connection: inert_connection()), reason)
  case state.custody {
    Held -> sm.transition(Retired(NativeExited(reason)), state)
    Lost -> sm.stop()
  }
}

fn inert_connection() -> transport.Connection {
  transport.Connection(send: fn(_) { Error(Nil) }, close: fn() { Nil })
}

fn begin_close(state: State, reason: String) -> sm.Next(Phase, State, Msg) {
  sm.transition(Closing, die(state, reason))
}

fn handle_expire(state: State, id: Int) -> sm.Next(Phase, State, Msg) {
  case dict.get(state.inflight, id) {
    // Already answered (or already settled by a death) — the timer is
    // stale and the expiry means nothing.
    Error(Nil) -> sm.keep(state)
    Ok(call) -> {
      settle_failure(call.reply, CallTimedOut(after_ms: call.deadline_ms))
      cancel_modern_wire(state, id, call.reply)
      sm.keep(State(..state, inflight: dict.delete(state.inflight, id)))
    }
  }
}

fn feed_lines(state: State, lines: List(String)) -> sm.Next(Phase, State, Msg) {
  case lines {
    [] -> sm.keep(state)
    [line, ..rest] ->
      case handle_line(state, line) {
        Ok(state) -> feed_lines(state, rest)
        Error(reason) -> begin_close(state, reason)
      }
  }
}

// One complete line. `Error(reason)` is channel-fatal; everything the
// client merely does not act on settles as `Ok` with the line dropped.
fn handle_line(state: State, line: String) -> Result(State, String) {
  case jsonrpc.decode_modern(line) {
    Error(jsonrpc.MalformedMessage(report:)) ->
      Error("mcp server sent a malformed line: " <> corruption.describe(report))
    Error(jsonrpc.BadMessage(reason:)) ->
      Error("mcp server sent a line that is not json-rpc: wanted " <> reason)
    Ok(jsonrpc.Correlated(jsonrpc.Response(id:, outcome:))) ->
      Ok(settle_response(state, id, outcome))
    Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(id:, ..))) ->
      refuse_server_request(state, id)
    Ok(jsonrpc.UncorrelatedError(_)) -> Ok(state)

    // v1 subscribes to nothing, so every notification is decoded (so
    // nothing hostile hides in one) and dropped.
    Ok(jsonrpc.Correlated(jsonrpc.Notification(method, params))) -> {
      route_notification(state, method, params)
    }
  }
}

// A response arrived. Correlation is by the exact minted integer id; a
// string id (never minted here) or an id no longer in flight — already
// expired, already settled — is dropped silently.
fn settle_response(
  state: State,
  id: Id,
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> State {
  case id {
    jsonrpc.IdString(_) -> state
    jsonrpc.IdInt(id) ->
      case dict.get(state.inflight, id) {
        Error(Nil) -> state
        Ok(call) -> {
          settle_answer(call.reply, validate_stream_result(call.reply, outcome))
          State(..state, inflight: dict.delete(state.inflight, id))
        }
      }
  }
}

// A server-initiated request is answered in-band with method-not-found:
// this client declared no capabilities, so nothing a server asks of it
// is a thing it does. The write can fail only when the peer is gone,
// which is channel-fatal like any other failed write.
fn refuse_server_request(state: State, id: Id) -> Result(State, String) {
  case state.connection.send(stdio.frame(method_not_found_response(id))) {
    Ok(Nil) -> Ok(state)
    Error(Nil) -> Error("mcp transport write failed")
  }
}

// The JSON-RPC error response `gleam_mcp/jsonrpc` has no encoder for, built
// here because answering server requests is the client actor's job
// (the protocol layer only decodes them).
fn method_not_found_response(id: Id) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String(jsonrpc.version)),
    #("id", encode_id(id)),
    #(
      "error",
      json.Object([
        #("code", json.Int(method_not_found_code)),
        #("message", json.String("method not found")),
      ]),
    ),
  ])
}

fn encode_id(id: Id) -> JsonValue {
  case id {
    jsonrpc.IdInt(value:) -> json.Int(value)
    jsonrpc.IdString(value:) -> json.String(value)
  }
}

fn outcome_to_result(
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Result(JsonValue, ClientError) {
  case outcome {
    Ok(value) -> Ok(value)
    Error(jsonrpc.RpcError(code:, message:, data: _)) ->
      Error(ServerError(code:, message:))
  }
}

// Latches the client dead: answers every in-flight caller
// `Unavailable(reason)`, closes the transport, and records the reason
// so later calls fail fast the same way. Idempotent — a client already
// dead stays dead with its first reason.
fn die(state: State, reason: String) -> State {
  case state.dead {
    Some(_) -> state
    None -> {
      list.each(dict.to_list(state.inflight), fn(entry) {
        let InFlight(reply:, ..) = entry.1
        settle_failure(reply, Unavailable(reason:))
      })
      state.connection.close()
      State(..state, inflight: dict.new(), dead: Some(reason))
    }
  }
}

/// The typed outcome of one explicit tools/call exchange.
pub type CallOutcome(output) {
  /// The original definition decoded successful structured output.
  Complete(output: output)

  /// The tool returned a visible failure without satisfying its output schema.
  ToolFailed(result: protocol.CallToolResult)

  /// The request paused; only this continuation can resume its original call.
  InputRequired(continuation: Continuation(output))
}

/// An endpoint, arguments, decoder and opaque state retained as one value.
pub opaque type Continuation(output) {
  Continuation(
    endpoint: requests.Endpoint,
    name: String,
    arguments: JsonValue,
    input_schema: schema.Schema,
    decoder: codec.Codec(output),
    revision: version.Version,
    required: mrtr.Required,
  )
}

/// Calls a tool through its definition without accepting raw args or a decoder.
///
/// ## Examples
///
/// ```gleam
/// // client.call(endpoint, definition, typed_args, request.options("agent", "1"))
/// ```
pub fn call(
  endpoint: requests.Endpoint,
  definition: definition.Tool(args, output),
  args: args,
  options: requests.Options,
) -> Result(CallOutcome(output), requests.Error) {
  use Nil <- result.try(admit_profile(
    definition.output_schema(definition),
    options,
  ))
  let input_schema = definition.input_schema(definition)
  use Nil <- result.try(requests.admit_schema(endpoint, input_schema))
  use arguments <- result.try(
    definition.encode_arguments(definition, args)
    |> result.map_error(requests.InvalidArguments),
  )
  perform_call(
    endpoint,
    definition.name(definition),
    arguments,
    input_schema,
    definition.result_codec(definition, args),
    None,
    options,
  )
}

/// Returns the suspension that supplies exact response keys and opaque state.
///
/// ## Examples
///
/// ```gleam
/// // mrtr.responses(client.continuation_required(continuation), explicit_inputs)
/// ```
pub fn continuation_required(
  continuation: Continuation(output),
) -> mrtr.Required {
  continuation.required
}

/// Resumes the retained call explicitly, without changing endpoint or args.
///
/// It never replays an effect automatically. The caller owns provider work and
/// must supply the exact input response keys requested by this continuation.
///
/// ## Examples
///
/// ```gleam
/// // client.resume(continuation, validated_responses, options)
/// ```
pub fn resume(
  continuation: Continuation(output),
  responses: mrtr.Responses,
  options: requests.Options,
) -> Result(CallOutcome(output), requests.Error) {
  use Nil <- result.try(
    case
      metadata.revision(requests.metadata(options)) == continuation.revision
    {
      True -> Ok(Nil)
      False ->
        Error(requests.InvalidArguments(
          "continuation protocol version cannot change",
        ))
    },
  )
  let pairs = case mrtr.responses_value(responses) {
    json.Object(pairs) -> pairs
    _ -> []
  }
  use _ <- result.try(
    mrtr.responses(continuation.required, pairs)
    |> result.map_error(requests.InvalidArguments),
  )
  perform_call(
    continuation.endpoint,
    continuation.name,
    continuation.arguments,
    continuation.input_schema,
    continuation.decoder,
    Some(#(continuation.required, responses)),
    options,
  )
}

fn perform_call(
  endpoint: requests.Endpoint,
  name: String,
  arguments: JsonValue,
  input_schema: schema.Schema,
  decoder: codec.Codec(output),
  resume: Option(#(mrtr.Required, mrtr.Responses)),
  options: requests.Options,
) -> Result(CallOutcome(output), requests.Error) {
  let params = [#("name", json.String(name)), #("arguments", arguments)]
  let params = case resume {
    None -> params
    Some(#(required, responses)) -> {
      let params =
        list.append(params, [
          #("inputResponses", mrtr.responses_value(responses)),
        ])
      case mrtr.request_state(required) {
        None -> params
        Some(state) ->
          list.append(params, [#("requestState", json.String(state))])
      }
    }
  }
  let revision = metadata.revision(requests.metadata(options))
  use value <- result.try(send_request(
    endpoint,
    "tools/call",
    params,
    Some(input_schema),
    options,
  ))
  use result_type <- result.try(decode_result_type(value, revision))
  case result_type {
    "input_required" -> {
      use required <- result.try(
        mrtr.decode(value) |> result.map_error(requests.InvalidResponse),
      )
      Ok(
        InputRequired(Continuation(
          endpoint,
          name,
          arguments,
          input_schema,
          decoder,
          revision,
          required,
        )),
      )
    }
    "complete" -> {
      use result <- result.try(
        protocol.decode_call_tool_result(value)
        |> result.map_error(fn(error) {
          requests.InvalidResponse(protocol_fault(error))
        }),
      )
      case result.is_error {
        True -> Ok(ToolFailed(result))
        False -> {
          use structured <- result.try(case result.structured_content {
            Some(value) -> Ok(value)
            None ->
              Error(requests.InvalidResponse(
                "typed tool result is missing structuredContent",
              ))
          })
          codec.decode(decoder, structured)
          |> result.map(Complete)
          |> result.map_error(requests.InvalidResponse)
        }
      }
    }
    other -> Error(requests.InvalidResponse("unsupported resultType " <> other))
  }
}

/// Discovers modern server behavior without initializing a session.
///
/// ## Examples
///
/// ```gleam
/// // client.discover(endpoint, options) preserves cache freshness and scope.
/// ```
pub fn discover(
  endpoint: requests.Endpoint,
  options: requests.Options,
) -> Result(discovery.Discovery, requests.Error) {
  use value <- result.try(send_request(
    endpoint,
    "server/discover",
    [],
    None,
    options,
  ))
  discovery.decode(value) |> result.map_error(requests.InvalidResponse)
}

/// Builds an explicit subscription request for a transport-owned listen handle.
///
/// ## Examples
///
/// ```gleam
/// // client.listen_outbound(options, subscription.tools()) |> client_http.listen(config)
/// ```
pub fn listen_outbound(
  options: requests.Options,
  filter: subscription.Filter,
) -> requests.Outbound {
  listen_with_id(options, filter, jsonrpc.IdInt(ffi_request.next_id()))
}

fn listen_with_id(
  options: requests.Options,
  filter: subscription.Filter,
  id: Id,
) -> requests.Outbound {
  requests.outbound(
    options,
    jsonrpc.request(
      id,
      "subscriptions/listen",
      Some(
        json.Object([
          #("_meta", metadata.value(requests.metadata(options))),
          #("notifications", subscription.value(filter)),
        ]),
      ),
    ),
    None,
  )
}

fn send_request(
  endpoint: requests.Endpoint,
  method: String,
  params: List(#(String, JsonValue)),
  input_schema: Option(schema.Schema),
  options: requests.Options,
) -> Result(JsonValue, requests.Error) {
  let id = jsonrpc.IdInt(ffi_request.next_id())
  let params = case
    version.is_modern(metadata.revision(requests.metadata(options)))
  {
    True -> [#("_meta", metadata.value(requests.metadata(options))), ..params]
    False -> params
  }
  let message = jsonrpc.request(id, method, Some(json.Object(params)))
  use response <- result.try(requests.exchange(
    endpoint,
    requests.outbound(options, message, input_schema),
  ))
  use inbound <- result.try(
    jsonrpc.decode_value(response)
    |> result.map_error(fn(_) {
      requests.InvalidResponse("invalid JSON-RPC response envelope")
    }),
  )
  case inbound {
    jsonrpc.Correlated(jsonrpc.Response(found, outcome)) if found == id ->
      outcome |> result.map_error(requests.RpcFailed)
    jsonrpc.UncorrelatedError(error) -> Error(requests.RpcFailed(error))
    jsonrpc.Correlated(_) ->
      Error(requests.InvalidResponse("response id does not match this request"))
  }
}

fn decode_result_type(
  value: JsonValue,
  revision: version.Version,
) -> Result(String, requests.Error) {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "resultType") {
        Ok(json.String(value)) -> Ok(value)
        Error(Nil) ->
          case version.is_modern(revision) {
            True ->
              Error(requests.InvalidResponse("modern resultType is required"))
            False -> Ok("complete")
          }
        _ -> Error(requests.InvalidResponse("resultType must be a string"))
      }
    _ -> Error(requests.InvalidResponse("result must be an object"))
  }
}

fn protocol_fault(error: protocol.ProtocolFault) -> String {
  case error {
    protocol.BadResult(reason) -> reason
    protocol.UnsupportedVersion(server, _) ->
      "unsupported protocol version " <> server
  }
}

/// Opens a published stdio client without initialization or ping traffic.
///
/// ## Examples
///
/// ```gleam
/// // client.prepare_owned(transport, custodian) |> result.then(client.connect_modern)
/// ```
@internal
pub fn connect_modern(client: Client) -> Result(Nil, StartError) {
  exchange(client.subject, init_timeout_ms, Open)
  |> result.map_error(HandshakeFailed)
  |> result.flatten
}

/// Starts the native request-oriented client while retaining retirement custody.
///
/// ## Examples
///
/// ```gleam
/// // client.start_modern(transport.PortTransport(spawn)) sends no initialize.
/// ```
pub fn start_modern(transport: Transport) -> Result(Client, StartError) {
  use client <- result.try(prepare(transport))
  case connect_modern(client) {
    Ok(Nil) -> Ok(client)
    Error(error) ->
      case shutdown(client, within: init_timeout_ms) {
        Ok(Nil) -> Error(error)
        Error(_) -> Error(CleanupUnconfirmed(client))
      }
  }
}

/// Adapts the native client actor to the shared typed request interface.
///
/// Each callback result remains correlated to its original envelope, while the
/// actor allocates independent wire ids for concurrent callers on one pipe.
///
/// ## Examples
///
/// ```gleam
/// // client.call(client.endpoint(native_client), definition, args, options)
/// ```
pub fn endpoint(client: Client) -> requests.Endpoint {
  requests.endpoint("stdio", fn(outbound) { raw_exchange(client, outbound) })
}

/// Cancels an explicit outbound request identified by its original wire id.
///
/// ## Examples
///
/// ```gleam
/// // client.cancel(native_client, listen_request_id)
/// ```
pub fn cancel(client: Client, id: Id) -> Nil {
  process.send(client.subject, CancelRaw(id))
}

fn raw_exchange(
  client: Client,
  outbound: requests.Outbound,
) -> Result(JsonValue, requests.Error) {
  use owner <- result.try(
    process.subject_owner(client.subject)
    |> result.replace_error(requests.TransportFailed(
      "mcp client is not running",
    )),
  )
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) {
      Error(requests.TransportFailed("mcp client stopped"))
    })
  process.send(client.subject, RawRequest(outbound, reply))
  let answer = receive_raw(selector, outbound)
  process.demonitor_process(monitor)
  answer
}

fn receive_raw(
  selector: process.Selector(Result(RawEvent, requests.Error)),
  outbound: requests.Outbound,
) -> Result(JsonValue, requests.Error) {
  let clock = poll.monotonic()
  let budget = outbound.timeout_ms + reply_margin_ms
  let deadline = clock.now() + budget
  case
    poll.fold_until(
      clock:,
      within: budget,
      every: poll.Fixed(1),
      from: Nil,
      attempt: fn(_) {
        let remaining = deadline - clock.now()
        case remaining > 0 {
          False ->
            poll.Broken(requests.TransportFailed(
              "mcp actor did not settle the exchange",
            ))
          True ->
            case process.selector_receive(selector, remaining) {
              Error(Nil) ->
                poll.Broken(requests.TransportFailed(
                  "mcp actor did not settle the exchange",
                ))
              Ok(Error(error)) -> poll.Broken(error)
              Ok(Ok(RawResult(Ok(value)))) -> poll.Settled(value)
              Ok(Ok(RawResult(Error(error)))) -> poll.Broken(error)
              Ok(Ok(RawNotification(value))) -> {
                // Observer time consumes the same monotonic exchange budget.
                outbound.on_notification(value)
                poll.Pending(Nil)
              }
            }
        }
      },
    )
  {
    poll.Answer(value) -> Ok(value)
    poll.Failure(error) -> Error(error)
    poll.RanOut(_) ->
      Error(requests.TransportFailed("mcp actor did not settle the exchange"))
  }
}

fn handle_raw_request(
  state: State,
  outbound: requests.Outbound,
  reply: Subject(RawEvent),
) -> sm.Next(Phase, State, Msg) {
  let admitted = {
    use Nil <- result.try(
      case outbound.timeout_ms >= 1 && outbound.timeout_ms <= 4_294_966_295 {
        True -> Ok(Nil)
        False ->
          Error(requests.InvalidArguments(
            "outbound timeout is outside supported timer bounds",
          ))
      },
    )
    use original <- result.try(
      jsonrpc.decode_value(outbound.envelope)
      |> result.map_error(fn(_) {
        requests.InvalidArguments("invalid outbound envelope")
      }),
    )
    use id <- result.try(case original {
      jsonrpc.Correlated(jsonrpc.ServerRequest(id, _, _)) -> Ok(id)
      _ ->
        Error(requests.InvalidArguments("outbound exchange must be a request"))
    })
    use caller <- result.try(
      process.subject_owner(reply)
      |> result.replace_error(requests.TransportFailed(
        "request owner disappeared",
      )),
    )
    use Nil <- result.try(case state.dead, dict.size(state.inflight) < 128 {
      None, True -> Ok(Nil)
      Some(reason), _ -> Error(requests.TransportFailed(reason))
      None, False ->
        Error(requests.TransportFailed("too many outstanding stdio requests"))
    })
    Ok(#(id, caller))
  }
  case admitted {
    Error(error) -> {
      process.send(reply, RawResult(Error(error)))
      sm.keep(state)
    }
    Ok(#(original_id, caller)) -> {
      let id = state.next_id
      let stream = outbound_stream(outbound, jsonrpc.IdInt(id))
      let reply =
        ModernReply(original_id, reply, process.monitor(caller), stream)
      let inflight =
        dict.insert(state.inflight, id, InFlight(reply, outbound.timeout_ms))
      let state = State(..state, next_id: id + 1, inflight:)
      let message = replace_request_id(outbound.envelope, jsonrpc.IdInt(id))
      case state.connection.send(stdio.frame(message)) {
        Ok(Nil) -> {
          let _ =
            process.send_after(state.commands, outbound.timeout_ms, Expire(id))
          sm.keep(state)
        }
        Error(Nil) -> begin_close(state, "mcp transport write failed")
      }
    }
  }
}

fn replace_request_id(value: JsonValue, id: Id) -> JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(pair) {
          case pair.0 {
            "id" -> #("id", encode_id(id))
            _ -> pair
          }
        }),
      )
    _ -> value
  }
}

fn settle_answer(
  reply: Reply,
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Nil {
  case reply {
    LegacyReply(subject) -> process.send(subject, outcome_to_result(outcome))
    ModernReply(original, subject, monitor, _) -> {
      process.demonitor_process(monitor)
      let envelope = case outcome {
        Ok(result) ->
          jsonrpc.response(
            original,
            replace_result_subscription_id(result, original),
          )
        Error(error) -> jsonrpc.error_response(Some(original), error)
      }
      process.send(subject, RawResult(Ok(envelope)))
    }
  }
}

fn settle_failure(reply: Reply, error: ClientError) -> Nil {
  case reply {
    LegacyReply(subject) -> process.send(subject, Error(error))
    ModernReply(_, subject, monitor, _) -> {
      process.demonitor_process(monitor)
      process.send(
        subject,
        RawResult(
          Error(
            requests.TransportFailed(case error {
              Unavailable(reason) | ResultMalformed(reason) -> reason
              CallTimedOut(_) -> "mcp request timed out"
              ServerError(_, message) -> message
              TooManyPages(_) -> "mcp pagination exceeded its bound"
            }),
          ),
        ),
      )
    }
  }
}

fn cancel_modern_wire(state: State, id: Int, reply: Reply) -> Nil {
  case reply {
    LegacyReply(_) -> Nil
    ModernReply(..) -> {
      let _ =
        state.connection.send(
          stdio.frame(jsonrpc.notification(
            "notifications/cancelled",
            Some(json.Object([#("requestId", json.Int(id))])),
          )),
        )
      Nil
    }
  }
}

fn cancel_matching(
  state: State,
  matches: fn(Reply) -> Bool,
) -> sm.Next(Phase, State, Msg) {
  let matching =
    dict.to_list(state.inflight)
    |> list.filter(fn(pair) { matches(pair.1.reply) })
  let inflight =
    list.fold(matching, state.inflight, fn(inflight, pair) {
      cancel_modern_wire(state, pair.0, pair.1.reply)
      settle_failure(pair.1.reply, Unavailable("mcp request was cancelled"))
      dict.delete(inflight, pair.0)
    })
  sm.keep(State(..state, inflight:))
}

fn route_notification(
  state: State,
  method: String,
  params: Option(JsonValue),
) -> Result(State, String) {
  let notification = jsonrpc.notification(method, params)
  let id = case params {
    Some(params) -> subscription.notification_id(params)
    None -> Error("notification params missing")
  }
  case id {
    Ok(jsonrpc.IdInt(id)) -> route_stream(state, id, notification)
    Ok(jsonrpc.IdString(_)) | Error(_) -> Ok(state)
  }
}

fn route_stream(
  state: State,
  id: Int,
  notification: JsonValue,
) -> Result(State, String) {
  case dict.get(state.inflight, id) {
    Ok(InFlight(ModernReply(original, reply, monitor, Some(stream)), deadline)) -> {
      case subscription.accept(stream, notification) {
        Ok(stream) -> {
          process.send(
            reply,
            RawNotification(replace_subscription_id(notification, original)),
          )
          let updated =
            InFlight(
              ModernReply(original, reply, monitor, Some(stream)),
              deadline,
            )
          Ok(State(..state, inflight: dict.insert(state.inflight, id, updated)))
        }
        Error(reason) -> {
          cancel_modern_wire(
            state,
            id,
            ModernReply(original, reply, monitor, Some(stream)),
          )
          process.demonitor_process(monitor)
          process.send(
            reply,
            RawResult(Error(requests.InvalidResponse(reason))),
          )
          Ok(State(..state, inflight: dict.delete(state.inflight, id)))
        }
      }
    }
    _ -> Ok(state)
  }
}

fn outbound_stream(
  outbound: requests.Outbound,
  id: Id,
) -> Option(subscription.Stream) {
  let decoded = {
    use envelope <- result.try(
      jsonrpc.decode_value(outbound.envelope) |> result.replace_error(Nil),
    )
    use fields <- result.try(case envelope {
      jsonrpc.Correlated(jsonrpc.ServerRequest(
        _,
        "subscriptions/listen",
        Some(json.Object(fields)),
      )) -> Ok(fields)
      _ -> Error(Nil)
    })
    use filter <- result.try(list.key_find(fields, "notifications"))
    subscription.decode(filter) |> result.replace_error(Nil)
  }
  decoded |> result.map(subscription.stream(id, _)) |> option.from_result
}

fn replace_subscription_id(notification: JsonValue, original: Id) -> JsonValue {
  map_object(notification, fn(pair) {
    case pair.0 {
      "params" -> #(pair.0, replace_result_subscription_id(pair.1, original))
      _ -> pair
    }
  })
}

fn replace_result_subscription_id(value: JsonValue, original: Id) -> JsonValue {
  map_object(value, fn(pair) {
    case pair.0 {
      "_meta" -> #(
        pair.0,
        map_object(pair.1, fn(pair) {
          case pair.0 {
            "io.modelcontextprotocol/subscriptionId" -> #(
              pair.0,
              encode_id(original),
            )
            _ -> pair
          }
        }),
      )
      _ -> pair
    }
  })
}

fn map_object(
  value: JsonValue,
  map: fn(#(String, JsonValue)) -> #(String, JsonValue),
) -> JsonValue {
  case value {
    json.Object(fields) -> json.Object(list.map(fields, map))
    _ -> value
  }
}

/// A validated modern tools catalog and conservative cache freshness.
pub type ToolListing {
  ToolListing(
    /// Tools accepted by both schema compilation and endpoint binding policy.
    tools: List(protocol.ToolDescriptor),
    /// Exact single-page hints; multi-page snapshots are conservatively stale.
    cache: discovery.CacheHint,
  )
}

/// Lists tools with per-request metadata, bounded pagination and schema admission.
///
/// Invalid transport bindings exclude only their tool; valid siblings remain
/// discoverable. The same monotonic request budget covers every page.
///
/// ## Examples
///
/// ```gleam
/// // client.list_tools_at(endpoint, options) returns descriptors and cache hints.
/// ```
pub fn list_tools_at(
  endpoint: requests.Endpoint,
  options: requests.Options,
) -> Result(ToolListing, requests.Error) {
  let clock = poll.monotonic()
  let deadline = clock.now() + requests.timeout_ms(options)
  modern_list_pages(
    endpoint,
    options,
    clock,
    deadline,
    None,
    [],
    [],
    None,
    max_tool_pages,
  )
}

fn modern_list_pages(
  endpoint: requests.Endpoint,
  options: requests.Options,
  clock: poll.Clock,
  deadline: Int,
  cursor: Option(String),
  seen: List(String),
  collected: List(protocol.ToolDescriptor),
  cache: Option(discovery.CacheHint),
  remaining: Int,
) -> Result(ToolListing, requests.Error) {
  use Nil <- result.try(case remaining > 0 && deadline > clock.now() {
    True -> Ok(Nil)
    False ->
      Error(requests.InvalidResponse(
        "tool listing exhausted its page or time budget",
      ))
  })
  let params = case cursor {
    None -> []
    Some(value) -> [#("cursor", json.String(value))]
  }
  let options = requests.with_timeout(options, deadline - clock.now())
  use value <- result.try(send_request(
    endpoint,
    "tools/list",
    params,
    None,
    options,
  ))
  use result_type <- result.try(decode_result_type(
    value,
    metadata.revision(requests.metadata(options)),
  ))
  use Nil <- result.try(case result_type {
    "complete" -> Ok(Nil)
    _ ->
      Error(requests.InvalidResponse("tools/list resultType must be complete"))
  })
  use hint <- result.try(
    discovery.decode_cache(value) |> result.map_error(requests.InvalidResponse),
  )
  use page <- result.try(
    protocol.decode_tools_page(value)
    |> result.map_error(fn(error) {
      requests.InvalidResponse(protocol_fault(error))
    }),
  )
  let admitted =
    list.filter(page.tools, fn(tool) {
      case schema.new(tool.input_schema) {
        Error(_) -> False
        Ok(compiled) ->
          requests.admit_schema(endpoint, compiled) |> result.is_ok
      }
    })
  let collected = list.append(collected, admitted)
  let cache = case cache {
    None -> hint
    Some(_) -> discovery.stale()
  }
  case page.next_cursor {
    None -> Ok(ToolListing(collected, cache))
    Some(next) ->
      case list.contains(seen, next) {
        True ->
          Error(requests.InvalidResponse(
            "tools/list repeated a continuation cursor",
          ))
        False ->
          modern_list_pages(
            endpoint,
            options,
            clock,
            deadline,
            Some(next),
            [next, ..seen],
            collected,
            Some(cache),
            remaining - 1,
          )
      }
  }
}

fn validate_stream_result(
  reply: Reply,
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Result(JsonValue, jsonrpc.RpcError) {
  case reply, outcome {
    ModernReply(_, _, _, Some(stream)), Ok(value) ->
      subscription.complete(stream, value)
      |> result.map(fn(_) { value })
      |> result.map_error(fn(reason) { jsonrpc.RpcError(-32_600, reason, None) })
    _, _ -> outcome
  }
}

fn admit_profile(
  output: schema.Schema,
  options: requests.Options,
) -> Result(Nil, requests.Error) {
  case version.is_modern(metadata.revision(requests.metadata(options))) {
    True -> Ok(Nil)
    False ->
      case schema.value(output) {
        json.Object(fields) ->
          case list.key_find(fields, "type") {
            Ok(json.String("object")) -> Ok(Nil)
            _ ->
              Error(requests.InvalidArguments(
                "legacy typed output requires an object schema",
              ))
          }
        _ ->
          Error(requests.InvalidArguments(
            "legacy typed output requires an object schema",
          ))
      }
  }
}

/// A retained subscription worker borrowing a caller-owned native client.
pub opaque type Listening {
  Listening(run: weft.Detached(JsonValue, requests.Error), id: Id)
}

/// The observed lifetime of one retained native subscription.
pub type ListenStatus {
  /// The admitted subscription is still open.
  ListeningPending

  /// The peer gracefully completed the subscription.
  ListeningCompleted(response: JsonValue)

  /// The subscription failed and its worker has been retired.
  ListeningFailed(error: requests.Error)

  /// Every outcome and worker retirement has already been consumed.
  ListeningDrained
}

/// Starts one modern subscription without blocking other native requests.
///
/// The calling process owns this handle and must poll or cancel it. Its
/// notification observer runs inside the retained request worker. Canceling that
/// worker causes the native actor to cancel the exact allocated wire request.
///
/// ## Examples
///
/// ```gleam
/// // client.listen(native, subscription.tools(), request.options("agent", "1"))
/// ```
pub fn listen(
  native: Client,
  filter: subscription.Filter,
  options: requests.Options,
) -> Result(Listening, requests.Error) {
  use Nil <- result.try(
    case version.is_modern(metadata.revision(requests.metadata(options))) {
      True -> Ok(Nil)
      False ->
        Error(requests.InvalidArguments("subscriptions require modern metadata"))
    },
  )
  let id = jsonrpc.IdInt(ffi_request.next_id())
  let outbound = listen_with_id(options, filter, id)
  let run =
    weft.new([
      fn() {
        use envelope <- result.try(raw_exchange(native, outbound))
        validate_listen_envelope(envelope)
      },
    ])
    |> weft.deadline(outbound.timeout_ms + reply_margin_ms)
    |> weft.start_detached
  Ok(Listening(run, id))
}

/// Observes the same retained worker without issuing another request.
///
/// ## Examples
///
/// ```gleam
/// // client.poll_listening(handle, 0) performs a nonblocking observation.
/// ```
pub fn poll_listening(listening: Listening, within: Int) -> ListenStatus {
  case weft.pull(listening.run, within: int.clamp(within, 0, 4_294_966_295)) {
    weft.NotYet -> ListeningPending
    weft.AllDelivered -> ListeningDrained
    weft.RunLost(_) ->
      ListeningFailed(requests.TransportFailed("subscription scope was lost"))
    weft.PulledOutcome(weft.Completed(_, value)) -> ListeningCompleted(value)
    weft.PulledOutcome(weft.Failed(_, error)) -> ListeningFailed(error)
    weft.PulledOutcome(_) ->
      ListeningFailed(requests.TransportFailed("subscription interrupted"))
  }
}

/// Cancels the retained worker and joins it before reporting completion.
///
/// The borrowed native client remains available to other callers. Joining this
/// worker does not roll back remote effects or automatically replay a request.
///
/// ## Examples
///
/// ```gleam
/// // client.cancel_listening(handle) retires one stream.
/// ```
pub fn cancel_listening(listening: Listening) -> Result(Nil, requests.Error) {
  weft.cancel_detached(listening.run)
  drain_listening(listening.run)
}

fn drain_listening(
  run: weft.Detached(JsonValue, requests.Error),
) -> Result(Nil, requests.Error) {
  case weft.pull(run, within: 1000) {
    weft.AllDelivered -> Ok(Nil)
    weft.RunLost(_) ->
      Error(requests.TransportFailed("subscription drain could not be proven"))
    weft.NotYet | weft.PulledOutcome(_) -> drain_listening(run)
  }
}

/// Returns the caller-visible identifier used by notification observers.
///
/// ## Examples
///
/// ```gleam
/// // client.listening_id(handle) matches acknowledgement subscriptionId.
/// ```
pub fn listening_id(listening: Listening) -> Id {
  listening.id
}

fn validate_listen_envelope(
  envelope: JsonValue,
) -> Result(JsonValue, requests.Error) {
  use decoded <- result.try(
    jsonrpc.decode_value(envelope)
    |> result.replace_error(requests.InvalidResponse(
      "invalid subscription response",
    )),
  )
  case decoded {
    jsonrpc.Correlated(jsonrpc.Response(_, Ok(_))) -> Ok(envelope)
    jsonrpc.Correlated(jsonrpc.Response(_, Error(error)))
    | jsonrpc.UncorrelatedError(error) -> Error(requests.RpcFailed(error))
    _ ->
      Error(requests.InvalidResponse("subscription did not receive a response"))
  }
}
