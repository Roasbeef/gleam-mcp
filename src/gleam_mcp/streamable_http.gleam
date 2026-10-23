//// Streamable HTTP adapter for the `gleam_mcp/transport.Transport` seam,
//// supporting both the modern `2026-07-28` stateless HTTP contract and the
//// `2025-06-18` / `2025-03-26` / `2024-11-05` initialized-session contracts.
////
//// `gleam_mcp/client` speaks newline-delimited JSON-RPC over a `Transport`.
//// This module implements a `ChannelTransport` coordinator that translates
//// each outbound JSON-RPC message into an HTTP `POST` over a caller-supplied
//// `HttpTransport`, bounded at `max_response_bytes` (eight MiB per JSON body
//// or SSE event), and feeds the correlated response back to the client actor
//// as `TransportData`.
////
//// Both streamable-HTTP protocol families in the specification are supported:
////
//// - **Initialized sessions (`2025-06-18`, `2025-03-26`, `2024-11-05`)**:
////   `initialize` is sent as a `POST`, any `Mcp-Session-Id` response header
////   and negotiated `protocolVersion` are retained for subsequent requests,
////   `notifications/initialized` is sent as a `POST` accepting `202 Accepted`,
////   and `Close` sends a bounded `DELETE` when a session ID is held.
//// - **Stateless modern HTTP (`2026-07-28`, `gleam_mcp/server_http`)**: when
////   the server rejects `initialize` with `-32020`, `-32022`, `-32600` or
////   `-32601`, the coordinator probes `discovery/discover` and `tools/list`
////   with `2026-07-28` request-scoped `_meta` and `Mcp-*` headers, answers
////   `gleam_mcp/client`'s `initialize` locally, and attaches `2026-07-28`
////   metadata and custom `x-mcp-header` mirrors to every subsequent
////   `tools/list` and `tools/call`.
////
//// Local HTTP framing and oversized-response faults are authenticated with a
//// VM-local HMAC (`tag_fault` / `classify_fault`) so callers can distinguish
//// an 8 MiB response overrun or malformed body from a transport or OAuth
//// failure without latching the client dead across independent HTTP requests.
////
//// ## Flow
////
//// `seam` → `open_connection` → `handle` → `handle_send` → `post_exchange` →
//// `execute_http`
////
//// 1. `seam` builds a `ChannelTransport` that calls `open_connection` in the
////    client actor's process.
//// 2. `handle` and `handle_send` dispatch initialization (`run_initialize`,
////    `probe_stateless_modern`), `notifications/initialized`
////    (`run_initialized_notification`), and requests (`run_request`).
//// 3. `post_exchange` resolves headers (`resolve_auth_headers`,
////    `build_request_headers`), runs `execute_http` (`await_status`,
////    `collect_sse`, `collect_body`, `finish_body`, `decode_json_body`), and
////    retries once on HTTP 401/403 with `retry_after_unauthorized`.
//// 4. `tag_fault` and `classify_fault` authenticate local HTTP faults across
////    the `gleam_mcp/client` boundary.
////
//// ## Coordinator transitions
////
//// | `Phase` | `Msg` | Action and next state |
//// | --- | --- | --- |
//// | `Running` | `Send` | Spawn detached `weft` exchange; record key in `inflight`. |
//// | `Running` | `InitializeDone` | Retire key; update `WireMode` and `tool_schemas`; forward reply frame. |
//// | `Running` | `RequestDone` | Retire key; merge discovered `tool_schemas`; forward reply frame. |
//// | `Running` | `NotificationDone` | Retire key. |
//// | `Running` | `Close` | Cancel and drain `inflight`; send session `DELETE` if held; emit `TransportClosed` and stop. |
//// | `Running` | `ClientGone` | Cancel `inflight` and stop. |

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/discovery
import gleam_mcp/http as mcp_http_meta
import gleam_mcp/http_headers
import gleam_mcp/internal/ffi_crypto
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc.{type Id}
import gleam_mcp/metadata
import gleam_mcp/oauth.{type HttpRequest, HttpRequest}
import gleam_mcp/protocol
import gleam_mcp/sse
import gleam_mcp/stdio
import gleam_mcp/transport
import gleam_mcp/version
import weft
import weft/state_machine as sm

/// The byte ceiling for retained accumulation of one HTTP JSON response body or
/// one SSE event (8 MiB), matching `gleam_mcp/client_http`. Checked before
/// appending each delivered response fragment.
pub const max_response_bytes = 8_388_608

/// One streaming HTTP event delivered by `HttpTransport`.
pub type HttpEvent {
  /// The response status line and headers arrived before body chunks.
  ResponseStatus(
    /// HTTP status code.
    status: Int,
    /// Response header pairs.
    headers: List(#(String, String)),
  )

  /// One body fragment arrived.
  ResponseChunk(
    /// Raw response body bytes.
    chunk: BitArray,
  )

  /// The response body completed normally.
  ResponseEnd

  /// The server rejected the request before streaming with a status and body.
  RequestRefused(
    /// HTTP status code.
    status: Int,
    /// Response header pairs.
    headers: List(#(String, String)),
    /// Refusal body text.
    body: String,
  )

  /// The transport failed before or during the exchange.
  RequestFailed(
    /// Diagnostic transport error reason.
    reason: String,
  )
}

/// Custody handle for an in-flight streaming HTTP request.
pub type RunningHttp {
  /// The worker pid and cancellation callback adopted by the enclosing `weft.Ledger`.
  RunningHttp(
    /// Worker process that owns the HTTP request.
    owner: process.Pid,
    /// Cancels the in-flight HTTP request.
    cancel: fn() -> Nil,
  )
}

/// A parked streaming HTTP request whose worker is adopted before `begin` runs.
pub type PreparedHttp {
  /// The custody handle and start trigger for one streaming HTTP request.
  PreparedHttp(
    /// The worker custody handle to adopt into a `weft.Ledger`.
    running: RunningHttp,
    /// Starts the HTTP request once custody is adopted.
    begin: fn() -> Nil,
  )
}

/// Caller-supplied streaming HTTP transport seam.
pub type HttpTransport {
  /// Prepares a streaming HTTP request that delivers `HttpEvent`s to a subject.
  HttpTransport(
    /// Parks a streaming HTTP request for ledger adoption before execution.
    prepare_streaming: fn(HttpRequest, Subject(HttpEvent)) ->
      Result(PreparedHttp, String),
  )
}

/// How outbound HTTP requests authenticate to the remote MCP endpoint.
pub type Auth {
  /// No `Authorization` header is sent.
  NoAuth

  /// Static `Authorization: Bearer <token>`.
  Bearer(
    /// Bearer credential value.
    token: String,
  )

  /// Static `Authorization: Macaroon <token>`.
  Macaroon(
    /// Macaroon credential value.
    token: String,
  )

  /// OAuth 2.1 bearer token resolved per request, with one refresh attempt on
  /// HTTP 401/403.
  OAuth(
    /// Resolves a valid access token before sending a request.
    authorize: fn(weft.Ledger) -> Result(String, String),
    /// Rotates a rejected access token after HTTP 401/403.
    refresh_unauthorized: fn(String, weft.Ledger) -> Result(String, String),
  )
}

/// Configuration for one remote Streamable HTTP MCP server.
pub type Config {
  /// All settings required to run one remote Streamable HTTP MCP peer.
  Config(
    /// The configured server key.
    server: String,
    /// Validated absolute `http://` or `https://` endpoint URL.
    url: String,
    /// Authentication source for outbound requests.
    auth: Auth,
    /// Streaming HTTP transport implementation.
    http_transport: HttpTransport,
    /// Client name advertised in `clientInfo` and `2026-07-28` `_meta`.
    client_name: String,
    /// Client version advertised in `clientInfo` and `2026-07-28` `_meta`.
    client_version: String,
    /// Operator CLI prefix named in OAuth re-authentication errors.
    login_command: String,
    /// Per-request exchange deadline in milliseconds.
    request_timeout_ms: Int,
  )
}

/// Classification of a local HTTP fault carried through `gleam_mcp/client`.
pub type FaultKind {
  /// The HTTP response violated framing, content-type, UTF-8, JSON, or the
  /// 8 MiB byte ceiling.
  MalformedFault(
    /// Diagnostic description of the framing or byte-limit violation.
    reason: String,
  )

  /// The HTTP connection, TLS handshake, status, or OAuth token failed.
  UnavailableFault(
    /// Diagnostic description of the transport or authentication failure.
    reason: String,
  )
}

type WireMode {
  Negotiating
  AwaitingInitialized(
    session_id: Option(String),
    protocol_version: Option(String),
    queued_lines: List(String),
  )
  RecoveringSession(queued_lines: List(String))
  InitializedSession(
    session_id: Option(String),
    protocol_version: Option(String),
  )
  StatelessModern
}

type SessionHealth {
  SessionIntact
  SessionExpiredOnServer
}

type Phase {
  Running
}

type State {
  State(
    config: Config,
    inbound: Subject(transport.TransportEvent),
    commands: Subject(Msg),
    mode: WireMode,
    last_init_params: Option(JsonValue),
    tool_schemas: Dict(String, JsonValue),
    next_key: Int,
    inflight: Dict(Int, weft.Detached(Nil, Nil)),
  )
}

type Msg {
  Send(line: String)
  InitializeDone(
    key: Int,
    outcome: Result(
      #(WireMode, JsonValue, Dict(String, JsonValue)),
      #(Id, FaultKind),
    ),
  )
  InitializedDone(
    key: Int,
    outcome: Result(Nil, FaultKind),
    health: SessionHealth,
  )
  RecoveryDone(key: Int, outcome: Result(WireMode, FaultKind))
  RequestDone(
    key: Int,
    reply: JsonValue,
    schemas: Dict(String, JsonValue),
    health: SessionHealth,
  )
  NotificationDone(key: Int, health: SessionHealth)
  Close
  ClientGone
}

type ParsedResponse {
  ParsedResponse(
    session_id: Option(String),
    value: JsonValue,
    outcome: Result(JsonValue, jsonrpc.RpcError),
  )
}

type RawHttpOutcome {
  RawParsed(ParsedResponse)
  RawEmptyAccepted(session_id: Option(String))
  RawUnauthorized(status: Int)
  RawFault(FaultKind)
}

type PostAttempt {
  PostAttempt(
    session_id: Option(String),
    protocol_version: Option(String),
    extra_headers: List(#(String, String)),
    expected_id: Option(Id),
    body: String,
  )
}

const fault_prefix = "gleam-mcp-http-fault:"

/// Builds a `transport.Transport` (`ChannelTransport`) for a remote HTTP MCP
/// server.
///
/// ## Examples
///
/// ```gleam
/// // streamable_http.seam(config)
/// ```
pub fn seam(config: Config) -> transport.Transport {
  transport.ChannelTransport(connect: fn(inbound) {
    open_connection(config, inbound, process.self())
  })
}

/// Authenticates a local HTTP fault message so callers can distinguish it
/// from an untrusted remote JSON-RPC server error.
///
/// ## Examples
///
/// ```gleam
/// let tagged = streamable_http.tag_fault(streamable_http.MalformedFault("too large"))
/// assert streamable_http.classify_fault(tagged)
///   == Some(streamable_http.MalformedFault("too large"))
/// ```
pub fn tag_fault(fault: FaultKind) -> String {
  let payload = case fault {
    MalformedFault(reason:) -> "malformed:" <> reason
    UnavailableFault(reason:) -> "unavailable:" <> reason
  }
  let mac =
    ffi_crypto.hmac_sha256(
      bit_array.from_string(payload),
      ffi_crypto.fault_key(),
    )
    |> bit_array.base16_encode
  fault_prefix <> mac <> ":" <> payload
}

/// Verifies and decodes a tagged local HTTP fault message. Untrusted server
/// error messages without a valid HMAC return `None`.
///
/// ## Examples
///
/// ```gleam
/// assert streamable_http.classify_fault("untrusted server error") == None
/// ```
pub fn classify_fault(message: String) -> Option(FaultKind) {
  case string.starts_with(message, fault_prefix) {
    False -> None
    True -> {
      let rest = string.drop_start(message, string.length(fault_prefix))
      case string.split_once(rest, ":") {
        Error(Nil) -> None
        Ok(#(mac, payload)) -> verify_fault_mac(mac, payload)
      }
    }
  }
}

fn verify_fault_mac(mac: String, payload: String) -> Option(FaultKind) {
  let expected =
    ffi_crypto.hmac_sha256(
      bit_array.from_string(payload),
      ffi_crypto.fault_key(),
    )
    |> bit_array.base16_encode
  case
    ffi_crypto.secure_compare(
      bit_array.from_string(mac),
      bit_array.from_string(expected),
    )
  {
    False -> None
    True -> decode_fault_payload(payload)
  }
}

fn decode_fault_payload(payload: String) -> Option(FaultKind) {
  case
    string.starts_with(payload, "malformed:"),
    string.starts_with(payload, "unavailable:")
  {
    True, _ ->
      Some(
        MalformedFault(reason: string.drop_start(
          payload,
          string.length("malformed:"),
        )),
      )
    False, True ->
      Some(
        UnavailableFault(reason: string.drop_start(
          payload,
          string.length("unavailable:"),
        )),
      )
    False, False -> None
  }
}

fn open_connection(
  config: Config,
  inbound: Subject(transport.TransportEvent),
  client_pid: process.Pid,
) -> transport.Connection {
  let started =
    sm.new_with_initialiser(1000, fn(commands) {
      let selector =
        process.new_selector()
        |> process.select(commands)
        |> process.select_specific_monitor(process.monitor(client_pid), fn(_) {
          ClientGone
        })
      let state =
        State(
          config:,
          inbound:,
          commands:,
          mode: Negotiating,
          last_init_params: None,
          tool_schemas: dict.new(),
          next_key: 1,
          inflight: dict.new(),
        )
      sm.initialised(Running, state)
      |> sm.selecting(selector)
      |> sm.returning(commands)
      |> Ok
    })
    |> sm.on_event(handle)
    |> sm.unlinked
    |> sm.start
  case started {
    Ok(actor) -> {
      let commands = actor.data
      transport.Connection(
        send: fn(line) {
          process.send(commands, Send(line))
          Ok(Nil)
        },
        close: fn() { process.send(commands, Close) },
      )
    }
    Error(_) ->
      transport.Connection(send: fn(_) { Error(Nil) }, close: fn() {
        process.send(
          inbound,
          transport.TransportClosed("mcp http coordinator failed to start"),
        )
      })
  }
}

fn handle(phase: Phase, state: State, msg: Msg) -> sm.Next(Phase, State, Msg) {
  case phase, msg {
    Running, Send(line) -> handle_send(state, line)
    Running, InitializeDone(key, outcome) ->
      case dict.has_key(state.inflight, key) {
        False -> sm.keep(state)
        True -> {
          let state = retire_key(state, key)
          case outcome {
            Ok(#(mode, reply, schemas)) -> {
              send_frame(state.inbound, reply)
              sm.keep(
                State(
                  ..state,
                  mode:,
                  tool_schemas: dict.merge(state.tool_schemas, schemas),
                ),
              )
            }
            Error(#(id, fault)) -> {
              send_frame(state.inbound, tagged_error_response(id, fault))
              sm.keep(state)
            }
          }
        }
      }
    Running, InitializedDone(key, outcome, health) ->
      case dict.has_key(state.inflight, key) {
        False -> sm.keep(state)
        True -> {
          let state = retire_key(state, key)
          handle_initialized_done(state, outcome, health)
        }
      }
    Running, RecoveryDone(key, outcome) ->
      case dict.has_key(state.inflight, key) {
        False -> sm.keep(state)
        True -> {
          let state = retire_key(state, key)
          handle_recovery_done(state, outcome)
        }
      }
    Running, RequestDone(key, reply, schemas, health) ->
      case dict.has_key(state.inflight, key) {
        False -> sm.keep(state)
        True -> {
          let state = retire_key(state, key)
          send_frame(state.inbound, reply)
          let mode = next_mode_after_request(state.mode, health)
          sm.keep(
            State(
              ..state,
              mode:,
              tool_schemas: dict.merge(state.tool_schemas, schemas),
            ),
          )
        }
      }
    Running, NotificationDone(key, health) ->
      case dict.has_key(state.inflight, key) {
        False -> sm.keep(state)
        True -> {
          let state = retire_key(state, key)
          sm.keep(apply_session_health(state, health))
        }
      }
    Running, Close -> {
      let drained = cancel_all(state.inflight)
      delete_session_if_needed(state.config, state.mode)
      case drained {
        Ok(Nil) -> {
          process.send(
            state.inbound,
            transport.TransportClosed("mcp http transport closed"),
          )
          sm.stop()
        }
        Error(Nil) -> sm.stop_abnormal("mcp http request drain unconfirmed")
      }
    }
    Running, ClientGone -> {
      let _ = cancel_all(state.inflight)
      sm.stop()
    }
  }
}

fn handle_initialized_done(
  state: State,
  outcome: Result(Nil, FaultKind),
  health: SessionHealth,
) -> sm.Next(Phase, State, Msg) {
  case outcome, state.mode {
    Ok(Nil), AwaitingInitialized(session_id:, protocol_version:, queued_lines:)
    -> {
      let ready =
        State(..state, mode: InitializedSession(session_id:, protocol_version:))
      sm.keep(list.fold(queued_lines, ready, dispatch_line))
    }
    Ok(Nil), _ -> sm.keep(apply_session_health(state, health))
    Error(fault), AwaitingInitialized(queued_lines:, ..) -> {
      fail_queued_requests(state.inbound, queued_lines, fault)
      process.send(state.inbound, transport.TransportClosed(tag_fault(fault)))
      sm.keep(State(..state, mode: Negotiating))
    }
    Error(fault), _ -> {
      process.send(state.inbound, transport.TransportClosed(tag_fault(fault)))
      sm.keep(apply_session_health(state, health))
    }
  }
}

fn fail_queued_requests(
  inbound: Subject(transport.TransportEvent),
  queued_lines: List(String),
  fault: FaultKind,
) -> Nil {
  list.each(queued_lines, fn(line) {
    case jsonrpc.decode(string.trim_end(line)) {
      Ok(jsonrpc.ServerRequest(id:, ..)) ->
        send_frame(inbound, tagged_error_response(id, fault))
      _ -> Nil
    }
  })
}

fn handle_recovery_done(
  state: State,
  outcome: Result(WireMode, FaultKind),
) -> sm.Next(Phase, State, Msg) {
  case outcome, state.mode {
    Ok(recovered), RecoveringSession(queued_lines:) -> {
      let ready = State(..state, mode: recovered)
      sm.keep(list.fold(queued_lines, ready, dispatch_line))
    }
    Ok(recovered), _ -> sm.keep(State(..state, mode: recovered))
    Error(fault), RecoveringSession(queued_lines:) -> {
      fail_queued_requests(state.inbound, queued_lines, fault)
      sm.keep(State(..state, mode: Negotiating))
    }
    Error(_), _ -> sm.keep(State(..state, mode: Negotiating))
  }
}

fn next_mode_after_request(
  current: WireMode,
  health: SessionHealth,
) -> WireMode {
  case health {
    SessionExpiredOnServer -> Negotiating
    SessionIntact -> current
  }
}

fn apply_session_health(state: State, health: SessionHealth) -> State {
  case health {
    SessionIntact -> state
    SessionExpiredOnServer -> State(..state, mode: Negotiating)
  }
}

fn handle_send(state: State, line: String) -> sm.Next(Phase, State, Msg) {
  let trimmed = string.trim_end(line)
  case state.mode, state.last_init_params, jsonrpc.decode(trimmed) {
    AwaitingInitialized(session_id:, protocol_version:, ..),
      _,
      Ok(jsonrpc.Notification(method: "notifications/initialized", ..))
    -> {
      let active_mode = InitializedSession(session_id:, protocol_version:)
      sm.keep(spawn_initialized_notification(state, active_mode))
    }
    AwaitingInitialized(session_id:, protocol_version:, queued_lines:), _, _ ->
      sm.keep(
        State(
          ..state,
          mode: AwaitingInitialized(
            session_id:,
            protocol_version:,
            queued_lines: list.append(queued_lines, [trimmed]),
          ),
        ),
      )
    RecoveringSession(..),
      _,
      Ok(jsonrpc.ServerRequest(method: "initialize", ..))
    -> sm.keep(dispatch_line(state, trimmed))
    RecoveringSession(queued_lines:), _, _ ->
      sm.keep(
        State(
          ..state,
          mode: RecoveringSession(
            queued_lines: list.append(queued_lines, [trimmed]),
          ),
        ),
      )
    Negotiating, Some(_), Ok(jsonrpc.ServerRequest(method: "initialize", ..)) ->
      sm.keep(dispatch_line(state, trimmed))
    Negotiating, Some(init_params), Ok(jsonrpc.ServerRequest(..)) -> {
      let recovering =
        State(..state, mode: RecoveringSession(queued_lines: [trimmed]))
      sm.keep(spawn_session_recovery(recovering, init_params))
    }
    _, _, _ -> sm.keep(dispatch_line(state, trimmed))
  }
}

fn spawn_session_recovery(state: State, init_params: JsonValue) -> State {
  let key = state.next_key
  let config = state.config
  let inbound = state.inbound
  let commands = state.commands
  let run =
    spawn_bounded(
      config.request_timeout_ms,
      fn(ledger) {
        recover_expired_session(ledger, config, inbound, init_params)
      },
      fn() { Error(UnavailableFault("timed out waiting for HTTP response")) },
      fn(outcome) { RecoveryDone(key, outcome) },
      commands,
    )
  State(
    ..state,
    next_key: key + 1,
    inflight: dict.insert(state.inflight, key, run),
  )
}

fn dispatch_line(state: State, trimmed: String) -> State {
  case jsonrpc.decode(trimmed) {
    Ok(jsonrpc.ServerRequest(id:, method: "initialize", params:)) -> {
      let key = state.next_key
      let config = state.config
      let inbound = state.inbound
      let commands = state.commands
      let run =
        spawn_bounded(
          config.request_timeout_ms,
          fn(ledger) { run_initialize(ledger, config, inbound, id, params) },
          fn() {
            Error(#(id, UnavailableFault("timed out waiting for HTTP response")))
          },
          fn(outcome) { InitializeDone(key, outcome) },
          commands,
        )
      State(
        ..state,
        last_init_params: Some(option.unwrap(params, json.Object([]))),
        next_key: key + 1,
        inflight: dict.insert(state.inflight, key, run),
      )
    }
    Ok(jsonrpc.Notification(method: "notifications/initialized", ..)) ->
      case state.mode {
        StatelessModern -> state
        Negotiating
        | AwaitingInitialized(..)
        | RecoveringSession(..)
        | InitializedSession(..) ->
          spawn_initialized_notification(state, state.mode)
      }
    Ok(jsonrpc.ServerRequest(id:, method:, params:)) -> {
      let key = state.next_key
      let config = state.config
      let inbound = state.inbound
      let mode = state.mode
      let schemas = state.tool_schemas
      let commands = state.commands
      let run =
        spawn_bounded(
          config.request_timeout_ms,
          fn(ledger) {
            run_request(
              ledger,
              config,
              inbound,
              mode,
              schemas,
              id,
              method,
              params,
            )
          },
          fn() {
            #(
              tagged_error_response(
                id,
                UnavailableFault("timed out waiting for HTTP response"),
              ),
              dict.new(),
              SessionIntact,
            )
          },
          fn(res) { RequestDone(key, res.0, res.1, res.2) },
          commands,
        )
      State(
        ..state,
        next_key: key + 1,
        inflight: dict.insert(state.inflight, key, run),
      )
    }
    Ok(jsonrpc.Notification(method:, params:)) -> {
      let envelope = jsonrpc.notification(method, params)
      spawn_outbound_frame(state, envelope)
    }
    Ok(jsonrpc.Response(id:, outcome:)) -> {
      let envelope = case outcome {
        Ok(result) -> jsonrpc.response(id, result)
        Error(err) -> jsonrpc.error_response(Some(id), err)
      }
      spawn_outbound_frame(state, envelope)
    }
    Error(_) -> state
  }
}

fn spawn_initialized_notification(state: State, mode: WireMode) -> State {
  let key = state.next_key
  let config = state.config
  let inbound = state.inbound
  let commands = state.commands
  let run =
    spawn_bounded(
      config.request_timeout_ms,
      fn(ledger) { run_initialized_notification(ledger, config, inbound, mode) },
      fn() {
        #(
          Error(UnavailableFault("timed out waiting for HTTP response")),
          SessionIntact,
        )
      },
      fn(res) { InitializedDone(key, res.0, res.1) },
      commands,
    )
  State(
    ..state,
    next_key: key + 1,
    inflight: dict.insert(state.inflight, key, run),
  )
}

fn spawn_outbound_frame(state: State, envelope: JsonValue) -> State {
  let key = state.next_key
  let config = state.config
  let inbound = state.inbound
  let mode = state.mode
  let commands = state.commands
  let run =
    spawn_bounded(
      config.request_timeout_ms,
      fn(ledger) { run_outbound_frame(ledger, config, inbound, mode, envelope) },
      fn() { SessionIntact },
      fn(health) { NotificationDone(key, health) },
      commands,
    )
  State(
    ..state,
    next_key: key + 1,
    inflight: dict.insert(state.inflight, key, run),
  )
}

fn spawn_bounded(
  timeout_ms: Int,
  work: fn(weft.Ledger) -> a,
  on_timeout: fn() -> a,
  to_msg: fn(a) -> Msg,
  commands: Subject(Msg),
) -> weft.Detached(Nil, Nil) {
  let bounded_ms = int.max(timeout_ms, 1)
  let timer =
    process.send_after(commands, bounded_ms + 300, to_msg(on_timeout()))
  weft.new_prepared([
    weft.managed(fn(ledger) {
      let outcome = work(ledger)
      let _ = process.cancel_timer(timer)
      process.send(commands, to_msg(outcome))
      Ok(Nil)
    }),
  ])
  |> weft.deadline(bounded_ms + 200)
  |> weft.start_detached
}

fn retire_key(state: State, key: Int) -> State {
  case dict.get(state.inflight, key) {
    Error(Nil) -> state
    Ok(run) -> {
      weft.cancel_detached(run)
      let _ = drain_detached(run, ffi_crypto.monotonic_time_ms() + 5000)
      State(..state, inflight: dict.delete(state.inflight, key))
    }
  }
}

fn cancel_all(
  inflight: Dict(Int, weft.Detached(Nil, Nil)),
) -> Result(Nil, Nil) {
  let runs = dict.values(inflight)
  let deadline = ffi_crypto.monotonic_time_ms() + 5000
  list.each(runs, weft.cancel_detached)
  list.try_each(runs, drain_detached(_, deadline))
}

fn drain_detached(
  run: weft.Detached(Nil, Nil),
  deadline: Int,
) -> Result(Nil, Nil) {
  let remaining = deadline - ffi_crypto.monotonic_time_ms()
  case remaining > 0 {
    False -> Error(Nil)
    True ->
      case weft.pull(run, int.min(remaining, 1000)) {
        weft.AllDelivered -> Ok(Nil)
        weft.RunLost(_) -> Error(Nil)
        weft.NotYet | weft.PulledOutcome(_) -> drain_detached(run, deadline)
      }
  }
}

fn send_frame(
  inbound: Subject(transport.TransportEvent),
  message: JsonValue,
) -> Nil {
  process.send(
    inbound,
    transport.TransportData(bytes: bit_array.from_string(stdio.frame(message))),
  )
}

fn tagged_error_response(id: Id, fault: FaultKind) -> JsonValue {
  jsonrpc.error_response(
    Some(id),
    jsonrpc.RpcError(code: -32_000, message: tag_fault(fault), data: None),
  )
}

fn run_initialize(
  ledger: weft.Ledger,
  config: Config,
  inbound: Subject(transport.TransportEvent),
  id: Id,
  params: Option(JsonValue),
) -> Result(#(WireMode, JsonValue, Dict(String, JsonValue)), #(Id, FaultKind)) {
  let envelope = jsonrpc.request(id, "initialize", params)
  case
    post_exchange(
      ledger,
      config,
      Some(inbound),
      None,
      None,
      [],
      Some(id),
      envelope,
    )
  {
    Error(fault) -> Error(#(id, fault))
    Ok(ParsedResponse(session_id:, value:, outcome: Ok(result_obj))) -> {
      let negotiated = extract_protocol_version(result_obj)
      Ok(#(
        AwaitingInitialized(
          session_id:,
          protocol_version: negotiated,
          queued_lines: [],
        ),
        value,
        dict.new(),
      ))
    }
    Ok(ParsedResponse(
      outcome: Error(jsonrpc.RpcError(code:, ..)),
      value: original_error,
      ..,
    ))
      if code == -32_020 || code == -32_022 || code == -32_600 || code == -32_601
    -> probe_stateless_modern(ledger, config, inbound, id, original_error)
    Ok(ParsedResponse(session_id:, value:, outcome: Error(_))) ->
      Ok(#(
        InitializedSession(session_id:, protocol_version: None),
        value,
        dict.new(),
      ))
  }
}

// When an HTTP endpoint rejects `initialize` because it implements only the
// stateless `2026-07-28` request profile, probe `discovery/discover` and fall
// back to `tools/list` with `2026-07-28` metadata and `Mcp-*` headers.
fn probe_stateless_modern(
  ledger: weft.Ledger,
  config: Config,
  inbound: Subject(transport.TransportEvent),
  init_id: Id,
  original_error: JsonValue,
) -> Result(#(WireMode, JsonValue, Dict(String, JsonValue)), #(Id, FaultKind)) {
  let discover_envelope =
    modern_envelope(
      config.client_name,
      config.client_version,
      init_id,
      "discovery/discover",
      None,
    )
  let discover_headers =
    mcp_http_meta.headers(discover_envelope) |> result.unwrap([])
  let discovered =
    post_exchange(
      ledger,
      config,
      Some(inbound),
      None,
      None,
      discover_headers,
      Some(init_id),
      discover_envelope,
    )
  case discovered {
    Ok(ParsedResponse(outcome: Ok(result_obj), ..)) ->
      case discovery.decode(result_obj) {
        Ok(info) ->
          Ok(synthesized_modern_init(init_id, info.instructions, dict.new()))
        Error(_) ->
          probe_modern_tools_list(
            ledger,
            config,
            inbound,
            init_id,
            original_error,
          )
      }
    Ok(_) | Error(_) ->
      probe_modern_tools_list(ledger, config, inbound, init_id, original_error)
  }
}

fn probe_modern_tools_list(
  ledger: weft.Ledger,
  config: Config,
  inbound: Subject(transport.TransportEvent),
  init_id: Id,
  original_error: JsonValue,
) -> Result(#(WireMode, JsonValue, Dict(String, JsonValue)), #(Id, FaultKind)) {
  let probe_envelope =
    modern_envelope(
      config.client_name,
      config.client_version,
      init_id,
      "tools/list",
      None,
    )
  let extra_headers = mcp_http_meta.headers(probe_envelope) |> result.unwrap([])
  case
    post_exchange(
      ledger,
      config,
      Some(inbound),
      None,
      None,
      extra_headers,
      Some(init_id),
      probe_envelope,
    )
  {
    Ok(ParsedResponse(outcome: Ok(result_obj), ..)) -> {
      let schemas = extract_tool_schemas(result_obj)
      Ok(synthesized_modern_init(init_id, None, schemas))
    }
    Ok(_) | Error(_) ->
      Ok(#(
        InitializedSession(session_id: None, protocol_version: None),
        original_error,
        dict.new(),
      ))
  }
}

fn synthesized_modern_init(
  init_id: Id,
  instructions: Option(String),
  schemas: Dict(String, JsonValue),
) -> #(WireMode, JsonValue, Dict(String, JsonValue)) {
  let base = [
    #("protocolVersion", json.String(protocol.requested_version)),
    #("capabilities", json.Object([#("tools", json.Object([]))])),
  ]
  let fields = case instructions {
    None -> base
    Some(text) -> list.append(base, [#("instructions", json.String(text))])
  }
  #(StatelessModern, jsonrpc.response(init_id, json.Object(fields)), schemas)
}

fn run_initialized_notification(
  ledger: weft.Ledger,
  config: Config,
  inbound: Subject(transport.TransportEvent),
  mode: WireMode,
) -> #(Result(Nil, FaultKind), SessionHealth) {
  let #(session_id, protocol_version) = case mode {
    InitializedSession(session_id:, protocol_version:) -> #(
      session_id,
      protocol_version,
    )
    AwaitingInitialized(session_id:, protocol_version:, ..) -> #(
      session_id,
      protocol_version,
    )
    Negotiating | RecoveringSession(..) | StatelessModern -> #(None, None)
  }
  case
    post_notification(
      ledger,
      config,
      Some(inbound),
      session_id,
      protocol_version,
      [],
      protocol.initialized(),
    )
  {
    Ok(Nil) -> #(Ok(Nil), SessionIntact)
    Error(fault) -> #(Error(fault), session_health_for_fault(session_id, fault))
  }
}

fn run_outbound_frame(
  ledger: weft.Ledger,
  config: Config,
  inbound: Subject(transport.TransportEvent),
  mode: WireMode,
  envelope: JsonValue,
) -> SessionHealth {
  let #(session_id, protocol_version, extra_headers) = case mode {
    InitializedSession(session_id:, protocol_version:) -> #(
      session_id,
      protocol_version,
      [],
    )
    AwaitingInitialized(session_id:, protocol_version:, ..) -> #(
      session_id,
      protocol_version,
      [],
    )
    StatelessModern -> #(None, Some("2026-07-28"), [])
    Negotiating | RecoveringSession(..) -> #(None, None, [])
  }
  case
    post_notification(
      ledger,
      config,
      Some(inbound),
      session_id,
      protocol_version,
      extra_headers,
      envelope,
    )
  {
    Ok(Nil) -> SessionIntact
    Error(fault) -> session_health_for_fault(session_id, fault)
  }
}

fn recover_expired_session(
  ledger: weft.Ledger,
  config: Config,
  inbound: Subject(transport.TransportEvent),
  init_params: JsonValue,
) -> Result(WireMode, FaultKind) {
  let init_id = jsonrpc.IdString("reinit")
  case run_initialize(ledger, config, inbound, init_id, Some(init_params)) {
    Error(#(_, fault)) -> Error(fault)
    Ok(#(AwaitingInitialized(session_id:, protocol_version:, ..), _, _)) -> {
      let recovered = InitializedSession(session_id:, protocol_version:)
      case run_initialized_notification(ledger, config, inbound, recovered) {
        #(Ok(Nil), _) -> Ok(recovered)
        #(Error(fault), _) -> Error(fault)
      }
    }
    Ok(#(other_mode, _, _)) -> Ok(other_mode)
  }
}

fn run_request(
  ledger: weft.Ledger,
  config: Config,
  inbound: Subject(transport.TransportEvent),
  mode: WireMode,
  schemas: Dict(String, JsonValue),
  id: Id,
  method: String,
  params: Option(JsonValue),
) -> #(JsonValue, Dict(String, JsonValue), SessionHealth) {
  let #(session_id, protocol_version, extra_headers, envelope) = case mode {
    StatelessModern -> {
      let env =
        modern_envelope(
          config.client_name,
          config.client_version,
          id,
          method,
          params,
        )
      let base_headers = mcp_http_meta.headers(env) |> result.unwrap([])
      let param_headers = modern_param_headers(schemas, method, env)
      #(None, None, list.append(base_headers, param_headers), env)
    }
    InitializedSession(session_id:, protocol_version:) -> #(
      session_id,
      protocol_version,
      [],
      jsonrpc.request(id, method, params),
    )
    AwaitingInitialized(session_id:, protocol_version:, ..) -> #(
      session_id,
      protocol_version,
      [],
      jsonrpc.request(id, method, params),
    )
    Negotiating | RecoveringSession(..) -> #(
      None,
      None,
      [],
      jsonrpc.request(id, method, params),
    )
  }
  case
    post_exchange(
      ledger,
      config,
      Some(inbound),
      session_id,
      protocol_version,
      extra_headers,
      Some(id),
      envelope,
    )
  {
    Error(fault) -> #(
      tagged_error_response(id, fault),
      dict.new(),
      session_health_for_fault(session_id, fault),
    )
    Ok(ParsedResponse(value:, outcome: Ok(result_obj), ..)) -> {
      let discovered = case method {
        "tools/list" -> extract_tool_schemas(result_obj)
        _ -> dict.new()
      }
      #(value, discovered, SessionIntact)
    }
    Ok(ParsedResponse(value:, outcome: Error(_), ..)) -> #(
      value,
      dict.new(),
      SessionIntact,
    )
  }
}

fn session_health_for_fault(
  session_id: Option(String),
  fault: FaultKind,
) -> SessionHealth {
  case session_id, fault {
    Some(_), UnavailableFault("the server answered HTTP 404") ->
      SessionExpiredOnServer
    _, _ -> SessionIntact
  }
}

fn modern_envelope(
  client_name: String,
  client_version: String,
  id: Id,
  method: String,
  params: Option(JsonValue),
) -> JsonValue {
  let meta =
    metadata.new(version.V20260728)
    |> metadata.with_client(client_name, client_version)
    |> metadata.value
  let fields = case params {
    Some(json.Object(existing)) -> existing
    _ -> []
  }
  jsonrpc.request(id, method, Some(json.Object([#("_meta", meta), ..fields])))
}

fn modern_param_headers(
  schemas: Dict(String, JsonValue),
  method: String,
  envelope: JsonValue,
) -> List(#(String, String)) {
  case method {
    "tools/call" -> {
      let rendered = {
        use meta <- result.try(mcp_http_meta.metadata(envelope))
        use tool_name <- result.try(option.to_result(meta.name, "no name"))
        use schema_json <- result.try(
          dict.get(schemas, tool_name) |> result.replace_error("no schema"),
        )
        use plan <- result.try(http_headers.compile(schema_json))
        use args <- result.try(mcp_http_meta.arguments(envelope))
        http_headers.headers(plan, args)
      }
      result.unwrap(rendered, [])
    }
    _ -> []
  }
}

fn extract_protocol_version(value: JsonValue) -> Option(String) {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "protocolVersion") {
        Ok(json.String(ver)) if ver != "" -> Some(ver)
        _ -> None
      }
    _ -> None
  }
}

fn extract_tool_schemas(value: JsonValue) -> Dict(String, JsonValue) {
  case protocol.decode_tools_page(value) {
    Error(_) -> dict.new()
    Ok(page) ->
      list.fold(page.tools, dict.new(), fn(acc, tool) {
        dict.insert(acc, tool.name, tool.input_schema)
      })
  }
}

fn post_exchange(
  ledger: weft.Ledger,
  config: Config,
  inbound: Option(Subject(transport.TransportEvent)),
  session_id: Option(String),
  protocol_version: Option(String),
  extra_headers: List(#(String, String)),
  expected_id: Option(Id),
  envelope: JsonValue,
) -> Result(ParsedResponse, FaultKind) {
  use #(auth_headers, used_oauth_token) <- result.try(resolve_auth_headers(
    ledger,
    config.auth,
  ))
  let headers =
    build_request_headers(
      session_id,
      protocol_version,
      extra_headers,
      auth_headers,
    )
  let body = json.to_string(envelope)
  case
    execute_http(
      ledger,
      config.http_transport,
      inbound,
      "POST",
      config.url,
      headers,
      body,
      expected_id,
      config.request_timeout_ms,
    )
  {
    RawParsed(parsed) -> Ok(parsed)
    RawEmptyAccepted(session_id:) -> empty_accepted(expected_id, session_id)
    RawFault(fault) -> Error(fault)
    RawUnauthorized(status) ->
      retry_after_unauthorized(
        ledger,
        config,
        inbound,
        PostAttempt(
          session_id:,
          protocol_version:,
          extra_headers:,
          expected_id:,
          body:,
        ),
        used_oauth_token,
        status,
      )
  }
}

fn empty_accepted(
  expected_id: Option(Id),
  session_id: Option(String),
) -> Result(ParsedResponse, FaultKind) {
  case expected_id {
    None ->
      Ok(ParsedResponse(
        session_id:,
        value: json.Object([]),
        outcome: Ok(json.Object([])),
      ))
    Some(_) ->
      Error(MalformedFault(
        "the server answered an empty body to a JSON-RPC request",
      ))
  }
}

fn retry_after_unauthorized(
  ledger: weft.Ledger,
  config: Config,
  inbound: Option(Subject(transport.TransportEvent)),
  attempt: PostAttempt,
  used_oauth_token: Option(String),
  status: Int,
) -> Result(ParsedResponse, FaultKind) {
  case config.auth, used_oauth_token {
    OAuth(refresh_unauthorized:, ..), Some(rejected) -> {
      use refreshed_token <- result.try(
        refresh_unauthorized(rejected, ledger)
        |> result.map_error(UnavailableFault),
      )
      let headers =
        build_request_headers(
          attempt.session_id,
          attempt.protocol_version,
          attempt.extra_headers,
          [#("authorization", "Bearer " <> refreshed_token)],
        )
      let second =
        execute_http(
          ledger,
          config.http_transport,
          inbound,
          "POST",
          config.url,
          headers,
          attempt.body,
          attempt.expected_id,
          config.request_timeout_ms,
        )
      finish_retry_outcome(config, attempt.expected_id, second)
    }
    _, _ ->
      Error(UnavailableFault(
        "the server rejected authentication with HTTP " <> int.to_string(status),
      ))
  }
}

fn finish_retry_outcome(
  config: Config,
  expected_id: Option(Id),
  outcome: RawHttpOutcome,
) -> Result(ParsedResponse, FaultKind) {
  case outcome {
    RawParsed(parsed) -> Ok(parsed)
    RawEmptyAccepted(session_id:) -> empty_accepted(expected_id, session_id)
    RawUnauthorized(code) ->
      Error(UnavailableFault(
        "the OAuth token for mcp."
        <> config.server
        <> " was rejected (HTTP "
        <> int.to_string(code)
        <> "); run `"
        <> config.login_command
        <> " "
        <> config.server
        <> "`",
      ))
    RawFault(fault) -> Error(fault)
  }
}

fn post_notification(
  ledger: weft.Ledger,
  config: Config,
  inbound: Option(Subject(transport.TransportEvent)),
  session_id: Option(String),
  protocol_version: Option(String),
  extra_headers: List(#(String, String)),
  envelope: JsonValue,
) -> Result(Nil, FaultKind) {
  use _ <- result.try(post_exchange(
    ledger,
    config,
    inbound,
    session_id,
    protocol_version,
    extra_headers,
    None,
    envelope,
  ))
  Ok(Nil)
}

fn delete_session_if_needed(config: Config, mode: WireMode) -> Nil {
  case mode {
    InitializedSession(session_id: Some(sid), protocol_version:) -> {
      let auth = config.auth
      let transport = config.http_transport
      let url = config.url
      let _ =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            send_session_delete(
              ledger,
              auth,
              transport,
              url,
              sid,
              protocol_version,
            )
          }),
        ])
        |> weft.deadline(1000)
        |> weft.start
      Nil
    }
    AwaitingInitialized(session_id: Some(sid), protocol_version:, ..) -> {
      let auth = config.auth
      let transport = config.http_transport
      let url = config.url
      let _ =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            send_session_delete(
              ledger,
              auth,
              transport,
              url,
              sid,
              protocol_version,
            )
          }),
        ])
        |> weft.deadline(1000)
        |> weft.start
      Nil
    }
    InitializedSession(session_id: None, ..)
    | AwaitingInitialized(session_id: None, ..)
    | Negotiating
    | RecoveringSession(..)
    | StatelessModern -> Nil
  }
}

fn send_session_delete(
  ledger: weft.Ledger,
  auth: Auth,
  transport: HttpTransport,
  url: String,
  sid: String,
  protocol_version: Option(String),
) -> Result(Nil, Nil) {
  case resolve_auth_headers(ledger, auth) {
    Error(_) -> Ok(Nil)
    Ok(#(auth_headers, _)) -> {
      let headers =
        build_request_headers(Some(sid), protocol_version, [], auth_headers)
      let _ =
        execute_http(
          ledger,
          transport,
          None,
          "DELETE",
          url,
          headers,
          "",
          None,
          1000,
        )
      Ok(Nil)
    }
  }
}

fn resolve_auth_headers(
  ledger: weft.Ledger,
  auth: Auth,
) -> Result(#(List(#(String, String)), Option(String)), FaultKind) {
  case auth {
    NoAuth -> Ok(#([], None))
    Bearer(token:) -> Ok(#([#("authorization", "Bearer " <> token)], None))
    Macaroon(token:) -> Ok(#([#("authorization", "Macaroon " <> token)], None))
    OAuth(authorize:, ..) ->
      case authorize(ledger) {
        Ok(token) ->
          Ok(#([#("authorization", "Bearer " <> token)], Some(token)))
        Error(reason) -> Error(UnavailableFault(reason))
      }
  }
}

fn build_request_headers(
  session_id: Option(String),
  protocol_version: Option(String),
  extra_headers: List(#(String, String)),
  auth_headers: List(#(String, String)),
) -> List(#(String, String)) {
  let base = case extra_headers {
    [] -> [
      #("accept", "application/json, text/event-stream"),
      #("content-type", "application/json"),
    ]
    _ -> extra_headers
  }
  let with_session = case session_id {
    None -> base
    Some(sid) -> list.append(base, [#("mcp-session-id", sid)])
  }
  let with_version = case
    protocol_version,
    list.any(with_session, fn(h) {
      string.lowercase(h.0) == "mcp-protocol-version"
    })
  {
    Some(ver), False ->
      list.append(with_session, [#("mcp-protocol-version", ver)])
    _, _ -> with_session
  }
  list.append(with_version, auth_headers)
}

fn execute_http(
  ledger: weft.Ledger,
  http_transport: HttpTransport,
  inbound: Option(Subject(transport.TransportEvent)),
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  expected_id: Option(Id),
  timeout_ms: Int,
) -> RawHttpOutcome {
  let events = process.new_subject()
  let req = HttpRequest(method:, url:, headers:, body:)
  case http_transport.prepare_streaming(req, events) {
    Error(reason) -> RawFault(UnavailableFault(reason))
    Ok(prepared) ->
      case
        weft.adopt(
          ledger,
          owner: prepared.running.owner,
          cancel: prepared.running.cancel,
        )
      {
        weft.Refused ->
          RawFault(UnavailableFault("mcp http request was cancelled"))
        weft.Adopted -> {
          prepared.begin()
          let deadline = ffi_crypto.monotonic_time_ms() + int.max(timeout_ms, 1)
          let outcome = await_status(events, inbound, expected_id, deadline)
          prepared.running.cancel()
          outcome
        }
      }
  }
}

fn await_status(
  events: Subject(HttpEvent),
  inbound: Option(Subject(transport.TransportEvent)),
  expected_id: Option(Id),
  deadline: Int,
) -> RawHttpOutcome {
  let remaining = int.max(deadline - ffi_crypto.monotonic_time_ms(), 0)
  case process.receive(events, remaining) {
    Error(Nil) ->
      RawFault(UnavailableFault("timed out waiting for HTTP response headers"))
    Ok(RequestFailed(reason:)) -> RawFault(UnavailableFault(reason))
    Ok(RequestRefused(status:, ..)) ->
      RawFault(UnavailableFault(
        "HTTP request refused with status " <> int.to_string(status),
      ))
    Ok(ResponseChunk(_)) | Ok(ResponseEnd) ->
      RawFault(MalformedFault("HTTP response body preceded headers"))
    Ok(ResponseStatus(status:, headers:)) ->
      dispatch_response_status(
        events,
        inbound,
        status,
        headers,
        expected_id,
        deadline,
      )
  }
}

fn dispatch_response_status(
  events: Subject(HttpEvent),
  inbound: Option(Subject(transport.TransportEvent)),
  status: Int,
  headers: List(#(String, String)),
  expected_id: Option(Id),
  deadline: Int,
) -> RawHttpOutcome {
  let session_id =
    option.from_result(http_headers.get(headers, "mcp-session-id"))
  let content_type = media_type(headers)
  case status, content_type, expected_id {
    401, _, _ | 403, _, _ -> RawUnauthorized(status)
    404, _, _ -> RawFault(UnavailableFault("the server answered HTTP 404"))
    s, "text/event-stream", Some(id) if s >= 200 && s < 300 ->
      case sse.new(max_response_bytes) {
        Ok(decoder) ->
          collect_sse(events, inbound, session_id, id, decoder, deadline)
        Error(reason) -> RawFault(MalformedFault(reason))
      }
    _, _, _ ->
      collect_body(
        events,
        status,
        session_id,
        content_type,
        expected_id,
        <<>>,
        deadline,
      )
  }
}

fn collect_sse(
  events: Subject(HttpEvent),
  inbound: Option(Subject(transport.TransportEvent)),
  session_id: Option(String),
  expected_id: Id,
  decoder: sse.Decoder,
  deadline: Int,
) -> RawHttpOutcome {
  let remaining = int.max(deadline - ffi_crypto.monotonic_time_ms(), 0)
  case process.receive(events, remaining) {
    Error(Nil) ->
      RawFault(UnavailableFault("timed out waiting for SSE response event"))
    Ok(RequestFailed(reason:)) -> RawFault(UnavailableFault(reason))
    Ok(RequestRefused(status:, ..)) ->
      RawFault(UnavailableFault(
        "SSE stream refused with status " <> int.to_string(status),
      ))
    Ok(ResponseStatus(..)) ->
      RawFault(MalformedFault("duplicate HTTP status in SSE stream"))
    Ok(ResponseEnd) -> finish_sse_stream(decoder)
    Ok(ResponseChunk(chunk:)) ->
      feed_sse_chunk(
        events,
        inbound,
        session_id,
        expected_id,
        decoder,
        chunk,
        deadline,
      )
  }
}

fn finish_sse_stream(decoder: sse.Decoder) -> RawHttpOutcome {
  case sse.finish(decoder) {
    Error(reason) ->
      RawFault(MalformedFault(
        "the server's SSE stream ended mid-event: " <> reason,
      ))
    Ok(Nil) ->
      RawFault(UnavailableFault(
        "SSE stream closed before a correlated JSON-RPC response arrived",
      ))
  }
}

fn feed_sse_chunk(
  events: Subject(HttpEvent),
  inbound: Option(Subject(transport.TransportEvent)),
  session_id: Option(String),
  expected_id: Id,
  decoder: sse.Decoder,
  chunk: BitArray,
  deadline: Int,
) -> RawHttpOutcome {
  case sse.feed(decoder, chunk) {
    Error(reason) ->
      RawFault(MalformedFault(
        "the server's SSE response exceeded the "
        <> int.to_string(max_response_bytes)
        <> "-byte limit or was malformed: "
        <> reason,
      ))
    Ok(#(next_decoder, sse_events)) ->
      case inspect_sse_events(sse_events, inbound, session_id, expected_id) {
        Ok(Some(parsed)) -> RawParsed(parsed)
        Ok(None) ->
          collect_sse(
            events,
            inbound,
            session_id,
            expected_id,
            next_decoder,
            deadline,
          )
        Error(fault) -> RawFault(fault)
      }
  }
}

fn inspect_sse_events(
  sse_events: List(String),
  inbound: Option(Subject(transport.TransportEvent)),
  session_id: Option(String),
  expected_id: Id,
) -> Result(Option(ParsedResponse), FaultKind) {
  case sse_events {
    [] -> Ok(None)
    [event, ..rest] -> {
      use value <- result.try(
        json.parse(event)
        |> result.replace_error(MalformedFault(
          "the server sent malformed JSON in an SSE event",
        )),
      )
      case jsonrpc.decode_modern(event) {
        Ok(jsonrpc.Correlated(jsonrpc.Response(response_id, outcome)))
          if response_id == expected_id
        -> Ok(Some(ParsedResponse(session_id:, value:, outcome:)))
        Ok(jsonrpc.Correlated(jsonrpc.Notification(..)))
        | Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(..))) -> {
          case inbound {
            Some(sub) -> send_frame(sub, value)
            None -> Nil
          }
          inspect_sse_events(rest, inbound, session_id, expected_id)
        }
        Ok(jsonrpc.UncorrelatedError(error)) ->
          Ok(
            Some(ParsedResponse(
              session_id:,
              value: jsonrpc.error_response(Some(expected_id), error),
              outcome: Error(error),
            )),
          )
        _ ->
          Error(MalformedFault(
            "the server sent an uncorrelated or invalid JSON-RPC event on the SSE stream",
          ))
      }
    }
  }
}

fn collect_body(
  events: Subject(HttpEvent),
  status: Int,
  session_id: Option(String),
  content_type: String,
  expected_id: Option(Id),
  bytes: BitArray,
  deadline: Int,
) -> RawHttpOutcome {
  let remaining = int.max(deadline - ffi_crypto.monotonic_time_ms(), 0)
  case process.receive(events, remaining) {
    Error(Nil) ->
      RawFault(UnavailableFault("timed out reading HTTP response body"))
    Ok(RequestFailed(reason:)) -> RawFault(UnavailableFault(reason))
    Ok(RequestRefused(status: code, ..)) ->
      RawFault(UnavailableFault(
        "HTTP request refused with status " <> int.to_string(code),
      ))
    Ok(ResponseStatus(..)) ->
      RawFault(MalformedFault("duplicate HTTP status before response end"))
    Ok(ResponseChunk(chunk:)) -> {
      let next_size = bit_array.byte_size(bytes) + bit_array.byte_size(chunk)
      case next_size <= max_response_bytes {
        False ->
          RawFault(MalformedFault(
            "the server's HTTP response exceeded the "
            <> int.to_string(max_response_bytes)
            <> "-byte limit",
          ))
        True ->
          collect_body(
            events,
            status,
            session_id,
            content_type,
            expected_id,
            <<bytes:bits, chunk:bits>>,
            deadline,
          )
      }
    }
    Ok(ResponseEnd) ->
      finish_body(status, session_id, content_type, expected_id, bytes)
  }
}

fn finish_body(
  status: Int,
  session_id: Option(String),
  content_type: String,
  expected_id: Option(Id),
  bytes: BitArray,
) -> RawHttpOutcome {
  case expected_id, status == 202 || status == 204 || status == 200, bytes {
    None, True, _ -> RawEmptyAccepted(session_id:)
    _, _, _ ->
      case content_type == "application/json" {
        True -> decode_json_body(status, session_id, expected_id, bytes)
        False -> non_json_status_fault(status, content_type)
      }
  }
}

fn non_json_status_fault(status: Int, content_type: String) -> RawHttpOutcome {
  case status >= 200 && status < 300 {
    True ->
      RawFault(MalformedFault(
        "unsupported HTTP content-type `" <> content_type <> "`",
      ))
    False ->
      RawFault(UnavailableFault(
        "the server answered HTTP " <> int.to_string(status),
      ))
  }
}

fn decode_json_body(
  status: Int,
  session_id: Option(String),
  expected_id: Option(Id),
  bytes: BitArray,
) -> RawHttpOutcome {
  use <- bool.guard(
    when: bytes == <<>> && status >= 200 && status < 300,
    return: RawFault(MalformedFault("the server returned an empty JSON body")),
  )
  case bit_array.to_string(bytes) {
    Error(Nil) ->
      RawFault(MalformedFault("the server's JSON response is not valid UTF-8"))
    Ok(text) -> decode_utf8_json_body(status, session_id, expected_id, text)
  }
}

fn decode_utf8_json_body(
  status: Int,
  session_id: Option(String),
  expected_id: Option(Id),
  text: String,
) -> RawHttpOutcome {
  case json.parse(text), jsonrpc.decode_modern(text), expected_id {
    Ok(value),
      Ok(jsonrpc.Correlated(jsonrpc.Response(response_id, outcome))),
      Some(id)
      if response_id == id
    -> RawParsed(ParsedResponse(session_id:, value:, outcome:))
    Ok(_), Ok(jsonrpc.UncorrelatedError(error)), Some(id) ->
      RawParsed(ParsedResponse(
        session_id:,
        value: jsonrpc.error_response(Some(id), error),
        outcome: Error(error),
      ))
    _, _, _ ->
      case status >= 200 && status < 300 {
        True ->
          RawFault(MalformedFault(
            "the server's JSON response is not a correlated JSON-RPC response",
          ))
        False ->
          RawFault(UnavailableFault(
            "the server answered HTTP " <> int.to_string(status),
          ))
      }
  }
}

fn media_type(headers: List(#(String, String))) -> String {
  case http_headers.get(headers, "content-type") {
    Error(_) -> ""
    Ok(raw) ->
      raw
      |> string.split(";")
      |> list.first
      |> result.unwrap("")
      |> string.trim
      |> string.lowercase
  }
}
