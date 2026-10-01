//// Mist owns HTTP parsing and listener supervision. Each admitted POST transfers
//// its socket to a parked SSE actor before that actor starts a weft worker.
//// Socket close cancels the scope, and the actor waits for its drained verdict
//// before stopping. Header and Origin refusals happen before worker admission.
//// Request bodies use unambiguous Content-Length framing up to eight MiB.
//// Transfer-Encoding is refused before Mist can buffer a declared HTTP chunk.
////
//// ## Flow
////
//// start_server -> start creates a loopback Mist listener. Each request follows
//// handle -> admit before routing. post -> read_body -> body_framing bounds body
//// collection, then validate_request -> http.validate -> route -> custom_headers
//// checks body/header agreement before stream can admit application work.
//// Refusals follow reject -> discard_body without JSON parsing or dispatch.
////
//// ## Stream transitions
////
//// | Phase | Event | Ownership change |
//// | --- | --- | --- |
//// | Parked | Start after socket transfer | Admit the weft scope, then Running. |
//// | Running | Notify | Write one event; failed write cancels the scope. |
//// | Running | Socket close or unexpected bytes | Cancel, then Draining. |
//// | Running | Completed response | Write the final event, then Draining. |
//// | Draining | AllDelivered | Close the socket and stop. |
//// | Any | RunLost | Close and stop after scope loss; no normal drain proof. |
////
//// stream -> stream_loop separates the socket owner from dispatch_request's worker.
//// A notification returned by the dispatcher starts a subscription; wait_for_close
//// keeps its scope owned until cancellation. Draining proves local termination on
//// the normal path. It doesn't prove a remote operation was rolled back.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http as http_types
import gleam/http/request as http_request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import gleam/string
import gleam/string_tree
import gleam_mcp/http
import gleam_mcp/http_headers
import gleam_mcp/internal/ffi_http_socket as socket_native
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc
import gleam_mcp/schema
import gleam_mcp/server
import glisten/socket/options
import glisten/transport
import mist
import weft
import weft/poll

/// Explicit operator admission, separate from descriptive MCP client identity.
pub type Admission {
  /// A local operator has deliberately chosen unauthenticated loopback access.
  LocalUnauthenticated

  /// The operator validates credentials before the body or handler is admitted.
  Authenticate(
    /// Ok admits transport credentials; Error produces an HTTP 401 response.
    check: fn(List(#(String, String))) -> Result(Nil, Nil),
  )
}

/// Validated listener settings; the default interface is always loopback.
pub opaque type Config {
  /// The settings admitted together before any transport effect.
  Config(
    /// The admitted listener port; zero delegates selection to the OS.
    port: Int,
    /// The POST endpoint path, without a query or fragment.
    path: String,
    /// The exact allowlist for every present browser Origin.
    origins: List(String),
    /// The operator's explicit credentials policy.
    admission: Admission,
    /// The byte cap used before body collection and during refusal drains.
    limit: Int,
  )
}

/// A caller-owned stream dispatcher, which may emit request-scoped notifications.
pub type Dispatcher =
  fn(JsonValue, fn(JsonValue) -> Nil) -> Option(JsonValue)

/// Constructs a loopback listener with an explicit Origin allowlist and policy.
///
/// ## Examples
///
/// `new(8000, "/mcp", [], LocalUnauthenticated)` rejects every browser Origin.
pub fn new(
  port: Int,
  path: String,
  allowed_origins: List(String),
  admission: Admission,
) -> Result(Config, String) {
  case
    port >= 0
    && port <= 65_535
    && string.starts_with(path, "/")
    && !string.contains(path, "?")
    && !string.contains(path, "#")
  {
    True -> Ok(Config(port, path, allowed_origins, admission, 8_388_608))
    False -> Error("invalid HTTP listener port or endpoint path")
  }
}

/// Starts an immutable tools server using request-scoped modern dispatch.
///
/// ## Examples
///
/// `start_server(config, tools_server)` does not initialize a protocol session.
pub fn start_server(
  config: Config,
  registry: server.Server,
) -> Result(actor.Started(Supervisor), actor.StartError) {
  let registry = server.modern(registry)
  start(
    config,
    fn(envelope, _) { server.handle_message(registry, envelope).1 },
    fn(name) { server.tool_input_schema(registry, name) },
  )
}

/// Starts a caller-owned dispatcher with schema lookup for mirrored arguments.
///
/// A returned notification opens a long-lived stream; a returned response closes
/// it after delivery. Returning None leaves the owned worker waiting for close.
///
/// ## Examples
///
/// `start(config, dispatch, input_schema)` uses Mist's supervised listener.
pub fn start(
  config: Config,
  dispatch: Dispatcher,
  input_schema: fn(String) -> Option(schema.Schema),
) -> Result(actor.Started(Supervisor), actor.StartError) {
  mist.new(fn(req) { handle(config, dispatch, input_schema, req) })
  |> mist.bind("127.0.0.1")
  |> mist.port(config.port)
  |> mist.start
}

fn handle(
  config: Config,
  dispatch: Dispatcher,
  input_schema,
  req: http_request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case admit(config, req) {
    Error(status) -> reject(config, req, status)
    Ok(Nil) ->
      case req.method, req.path {
        http_types.Post, path if path == config.path ->
          post(config, dispatch, input_schema, req)
        _, _ -> reject(config, req, 405) |> response.set_header("allow", "POST")
      }
  }
}

// A refusal must consume its framed body before Mist reuses the connection.
// Otherwise a later body packet becomes a second request and closes the socket,
// which can reset the first response on Linux. Discarding never parses JSON or
// admits a callback, and retains only Mist's current bounded chunk.
fn reject(config: Config, req: http_request.Request(mist.Connection), status) {
  case discard_body(req, config.limit) {
    Ok(Nil) -> plain(status, "")
    Error(Nil) ->
      plain(status, "") |> response.set_header("connection", "close")
  }
}

fn discard_body(req: http_request.Request(mist.Connection), limit: Int) {
  use Nil <- result.try(
    body_framing(req.headers, limit) |> result.replace_error(Nil),
  )
  use consume <- result.try(mist.stream(req) |> result.replace_error(Nil))

  // Mist bounds each blocking body read to fifteen seconds. The shared poll
  // deadline charges those reads to one fifteen-second budget, so a slow peer
  // can overrun it by at most the final read rather than restart it per chunk.
  case
    poll.fold_until(
      clock: poll.monotonic(),
      within: 15_000,
      every: poll.Fixed(1),
      from: #(consume, limit),
      attempt: discard_chunk,
    )
  {
    poll.Answer(Nil) -> Ok(Nil)
    poll.Failure(Nil) | poll.RanOut(_) -> Error(Nil)
  }
}

// Mist's chunked reader can collect a whole declared chunk before yielding.
// Both admitted reads and refusal drains require bounded Content-Length framing.
// Unsupported or ambiguous framing closes before trusting a chunk declaration.
fn body_framing(headers: List(#(String, String)), limit: Int) {
  use Nil <- result.try(
    case
      list.any(headers, fn(header) {
        string.lowercase(header.0) == "transfer-encoding"
      })
    {
      True -> Error("unsupported or ambiguous HTTP body framing")
      False -> Ok(Nil)
    },
  )
  let length = case http_headers.get(headers, "content-length") {
    Ok(value) -> {
      use Nil <- result.try(
        case
          value != ""
          && list.all(string.to_graphemes(value), fn(digit) {
            list.contains(
              ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
              digit,
            )
          })
        {
          True -> Ok(Nil)
          False -> Error("malformed HTTP content length")
        },
      )
      int.parse(value) |> result.replace_error("malformed HTTP content length")
    }
    Error(_) ->
      case
        list.any(headers, fn(header) {
          string.lowercase(header.0) == "content-length"
        })
      {
        True -> Error("unsupported or ambiguous HTTP body framing")
        False -> Ok(0)
      }
  }
  use length <- result.try(length)
  case length >= 0 && length <= limit {
    True -> Ok(Nil)
    False -> Error("HTTP request exceeds byte limit")
  }
}

fn discard_chunk(state) {
  let #(consume, remaining) = state
  case consume(65_536) {
    Error(_) -> poll.Broken(Nil)
    Ok(mist.Done) -> poll.Settled(Nil)
    Ok(mist.Chunk(data, next)) ->
      case bit_array.byte_size(data) <= remaining {
        True -> poll.Pending(#(next, remaining - bit_array.byte_size(data)))
        False -> poll.Broken(Nil)
      }
  }
}

// Browser Origin and operator authentication answer separate admission
// questions. Both finish before routing can read or dispatch a body.
fn admit(config: Config, req: http_request.Request(mist.Connection)) {
  use Nil <- result.try(case http_headers.get(req.headers, "origin") {
    Error(_) ->
      case
        list.any(req.headers, fn(header) {
          string.lowercase(header.0) == "origin"
        })
      {
        True -> Error(403)
        False -> Ok(Nil)
      }
    Ok(origin) ->
      case list.contains(config.origins, origin) {
        True -> Ok(Nil)
        False -> Error(403)
      }
  })
  case config.admission {
    LocalUnauthenticated -> Ok(Nil)
    Authenticate(check) -> check(req.headers) |> result.map_error(fn(_) { 401 })
  }
}

fn post(
  config: Config,
  dispatch: Dispatcher,
  input_schema,
  req: http_request.Request(mist.Connection),
) {
  case read_body(req, config.limit) {
    Error(reason) ->
      rpc_error(400, None, -32_700, reason, None)
      |> response.set_header("connection", "close")
    Ok(body) ->
      case json.parse(body) {
        Error(_) -> rpc_error(400, None, -32_700, "parse error", None)
        Ok(envelope) -> {
          let id = request_id(envelope)

          // Modern HTTP has no notification metadata contract. Notifications
          // acknowledge transport acceptance without starting request workers.
          case jsonrpc.decode(json.to_string(envelope)) {
            Ok(jsonrpc.Notification(_, _)) -> plain(202, "")
            _ ->
              validate_request(
                config,
                dispatch,
                input_schema,
                req,
                envelope,
                id,
              )
          }
        }
      }
  }
}

fn validate_request(
  config: Config,
  dispatch: Dispatcher,
  input_schema,
  req: http_request.Request(mist.Connection),
  envelope,
  id,
) {
  case http.validate(envelope, req.headers) {
    Error(reason) -> rpc_error(400, id, -32_020, reason, None)
    Ok(meta) ->
      case meta.revision {
        "2026-07-28" ->
          route(config, dispatch, input_schema, req, envelope, meta, id)
        _ ->
          rpc_error(
            400,
            id,
            -32_022,
            "unsupported protocol version",
            Some(
              json.Object([
                #("supported", json.Array([json.String("2026-07-28")])),
                #("requested", json.String(meta.revision)),
              ]),
            ),
          )
      }
  }
}

fn route(
  config: Config,
  dispatch: Dispatcher,
  input_schema,
  req: http_request.Request(mist.Connection),
  envelope,
  meta: http.Metadata,
  id,
) {
  case
    list.contains(
      [
        "server/discover",
        "tools/list",
        "tools/call",
        "subscriptions/listen",
      ],
      meta.method,
    )
  {
    False -> rpc_error(404, id, -32_601, "method not found", None)
    True ->
      case custom_headers(input_schema, envelope, meta, req.headers) {
        Error(reason) -> rpc_error(400, id, -32_020, reason, None)
        Ok(Nil) ->
          case jsonrpc.decode(json.to_string(envelope)) {
            Ok(jsonrpc.ServerRequest(_, _, _)) ->
              stream(config, dispatch, req, envelope)
            Ok(jsonrpc.Notification(_, _)) -> plain(202, "")
            _ -> rpc_error(400, id, -32_600, "invalid request", None)
          }
      }
  }
}

// Only a known tool input schema contributes custom mirrors. Unknown names
// remain the dispatcher's protocol refusal rather than inventing a schema here.
fn custom_headers(
  input_schema: fn(String) -> Option(schema.Schema),
  envelope,
  meta: http.Metadata,
  headers,
) {
  case meta.method, meta.name {
    "tools/call", Some(name) ->
      case input_schema(name) {
        None -> Ok(Nil)
        Some(input) -> {
          use plan <- result.try(http_headers.compile(schema.value(input)))
          use args <- result.try(http.arguments(envelope))
          http_headers.validate(plan, args, headers)
        }
      }
    _, _ -> Ok(Nil)
  }
}

fn read_body(req: http_request.Request(mist.Connection), limit: Int) {
  use Nil <- result.try(body_framing(req.headers, limit))
  use consume <- result.try(
    mist.stream(req) |> result.map_error(fn(_) { "malformed HTTP body" }),
  )
  chunks(consume(65_536), <<>>, limit)
}

// The framing check already bounded the declared body. This second count
// checks actual fragments before accumulation; it is a byte bound, not a total
// wall-clock deadline for admitted body collection.
fn chunks(chunk, bytes, limit) {
  use chunk <- result.try(
    chunk |> result.map_error(fn(_) { "malformed HTTP body" }),
  )
  case chunk {
    mist.Done ->
      bit_array.to_string(bytes)
      |> result.map_error(fn(_) { "invalid UTF-8 request" })
    mist.Chunk(data, consume) -> {
      case bit_array.byte_size(bytes) + bit_array.byte_size(data) > limit {
        True -> Error("HTTP request exceeds byte limit")
        False -> chunks(consume(65_536), bit_array.append(bytes, data), limit)
      }
    }
  }
}

// Stream messages belong to the socket owner below, after HTTP admission.
// Handler values and scope retirement arrive separately on the same selector.
type Message {
  Start
  Notify(JsonValue)
  Scope(weft.Pulled(Option(JsonValue), Nil))
  Socket(socket_native.Event)
}

// These are the socket actor's actual lifetime variants, not HTTP statuses.
// Draining retains the actor after cancellation or final-response delivery.
type Phase {
  Parked
  Running(cancel: weft.Cancel)
  Draining
}

// The inbox owns notifications; outcomes carry the weft scope's drain verdict.
// Keeping both channels in the socket actor makes disconnect cleanup local.
type State {
  State(
    inbox: Subject(Message),
    outcomes: Subject(weft.Pulled(Option(JsonValue), Nil)),
    phase: Phase,
  )
}

fn stream(
  config: Config,
  dispatch: Dispatcher,
  req: http_request.Request(mist.Connection),
  envelope,
) {
  let ready = process.new_subject()
  let resp =
    mist.server_sent_events(
      req,
      response.new(200) |> response.set_header("x-accel-buffering", "no"),
      fn(inbox) {
        let outcomes = process.new_subject()
        process.send(ready, inbox)
        State(inbox, outcomes, Parked)
      },
      fn(state, message, connection) {
        stream_loop(config, dispatch, req, envelope, state, message, connection)
      },
    )

  // Mist has transferred the socket only after its constructor returns. The
  // permit prevents a worker from executing under the previous socket owner.
  case process.receive(ready, 1000) {
    Ok(inbox) -> process.send(inbox, Start)
    Error(_) -> Nil
  }
  resp
}

// The socket actor keeps cancellation authority until a drained verdict.
// A completed handler value can precede AllDelivered, so publishing that value
// does not by itself authorize actor exit.
fn stream_loop(
  _config: Config,
  dispatch: Dispatcher,
  req: http_request.Request(mist.Connection),
  envelope,
  state: State,
  message: Message,
  connection: mist.SSEConnection,
) -> actor.Next(State, Message) {
  case message, state.phase {
    Start, Parked -> {
      let selector =
        process.new_selector()
        |> process.select(state.inbox)
        |> process.select_map(state.outcomes, Scope)
        |> process.select_other(fn(message) {
          Socket(socket_native.classify(req.body.socket, message))
        })
      case
        transport.set_opts(req.body.transport, req.body.socket, [
          options.ActiveMode(options.Once),
        ])
      {
        Error(_) -> actor.stop()
        Ok(Nil) -> {
          let cancel = weft.cancel_signal()
          let owner = process.self()
          let task =
            weft.task(fn() { dispatch_request(dispatch, envelope, state.inbox) })
          let _ =
            weft.new_prepared([task])
            |> weft.cancel_with(cancel)
            |> weft.cancel_when_exits(owner)
            |> weft.start_relayed(state.outcomes)
          actor.continue(State(..state, phase: Running(cancel)))
          |> actor.with_selector(selector)
        }
      }
    }
    Notify(value), Running(cancel) ->
      case
        mist.send_event(
          connection,
          mist.event(string_tree.from_string(json.to_string(value))),
        )
      {
        Ok(Nil) -> actor.continue(state)
        Error(_) -> {
          weft.cancel(cancel)
          actor.continue(State(..state, phase: Draining))
        }
      }
    Socket(socket_native.Closed), Running(cancel)
    | Socket(socket_native.UnexpectedData), Running(cancel)
    -> {
      weft.cancel(cancel)
      actor.continue(State(..state, phase: Draining))
    }
    Scope(weft.PulledOutcome(weft.Completed(_, Some(value)))), Running(_) -> {
      let _ =
        mist.send_event(
          connection,
          mist.event(string_tree.from_string(json.to_string(value))),
        )
      actor.continue(State(..state, phase: Draining))
    }
    Scope(weft.AllDelivered), _ | Scope(weft.RunLost(_)), _ -> {
      let _ = transport.close(req.body.transport, req.body.socket)
      actor.stop()
    }
    _, _ -> actor.continue(state)
  }
}

// A returned notification is the start of a subscription, not its completion.
// The scope keeps custody while the worker waits for transport cancellation.
fn dispatch_request(
  dispatch: Dispatcher,
  envelope: JsonValue,
  inbox: Subject(Message),
) -> Result(Option(JsonValue), Nil) {
  let answer =
    dispatch(envelope, fn(value) { process.send(inbox, Notify(value)) })
  case answer {
    Some(value) ->
      case jsonrpc.decode(json.to_string(value)) {
        Ok(jsonrpc.Notification(_, _)) -> {
          process.send(inbox, Notify(value))
          wait_for_close()
        }
        _ -> Ok(answer)
      }
    None -> wait_for_close()
  }
}

fn wait_for_close() -> Result(Option(JsonValue), Nil) {
  let parked = process.new_subject()
  process.receive_forever(parked)
}

fn request_id(envelope) {
  case envelope {
    json.Object(fields) ->
      case list.key_find(fields, "id") {
        Ok(json.Int(id)) -> Some(json.Int(id))
        Ok(json.String(id)) -> Some(json.String(id))
        _ -> None
      }
    _ -> None
  }
}

fn plain(status, body) {
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn rpc_error(status, id, code, message, data) {
  let error = [#("code", json.Int(code)), #("message", json.String(message))]
  let error = case data {
    None -> error
    Some(data) -> list.append(error, [#("data", data)])
  }
  let id = case id {
    None -> []
    Some(id) -> [#("id", id)]
  }
  plain(
    status,
    json.to_string(
      json.Object(list.append(
        [
          #("jsonrpc", json.String("2.0")),
          #("error", json.Object(error)),
        ],
        id,
      )),
    ),
  )
  |> response.set_header("content-type", "application/json")
}
