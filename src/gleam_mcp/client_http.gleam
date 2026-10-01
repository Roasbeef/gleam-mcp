//// Each stateless POST owns a native HTTP connection adopted before sending.
//// Gun retries are disabled. A missing final correlated response means unknown
//// execution outcome; neither disconnect nor a header error replays effects.
//// Deadlines cancel and join the connection and worker through weft.
////
//// ## Flow
////
//// endpoint installs schema admission on request.Endpoint. exchange -> prepare
//// validates timers, standard mirrors and custom header plans before native.open.
//// The managed task adopts the Gun pid before send -> receive_headers chooses JSON
//// or SSE. receive_json -> final_json and receive_sse -> messages accept only the
//// correlated response; SSE notifications first pass their notification policy.
////
//// listen retains the same prepared task in a detached scope. poll observes that
//// scope and cancel -> join drains it. The handle owns its connection, so a caller
//// must keep it until completion or cancellation. Body credit is renewed only after
//// consumption; this bounds queued native messages, not total stream lifetime.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleam_mcp/http
import gleam_mcp/http_headers
import gleam_mcp/internal/ffi_http as native
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc
import gleam_mcp/request
import gleam_mcp/schema
import gleam_mcp/sse
import gleam_mcp/subscription
import weft

/// A validated HTTP endpoint and caller-owned authentication headers.
pub opaque type Config {
  /// The settings admitted together before any transport effect.
  Config(
    /// The original absolute URL used as endpoint identity.
    url: String,
    /// The parsed host used for connection and TLS hostname verification.
    host: String,
    /// The admitted TCP port, including the scheme default when omitted.
    port: Int,
    /// The admitted http or https transport choice.
    scheme: String,
    /// The request path with its optional query string.
    path: String,
    /// The caller's authentication headers, checked against reserved transport names.
    headers: List(#(String, String)),
    /// The byte cap for one JSON response or SSE event.
    limit: Int,
  )
}

/// Validates an absolute endpoint without userinfo or a URI fragment.
///
/// ## Examples
///
/// `new("http://127.0.0.1:8000/mcp", [])` uses an eight MiB event limit.
pub fn new(
  url: String,
  auth_headers: List(#(String, String)),
) -> Result(Config, String) {
  use parsed <- result.try(
    uri.parse(url) |> result.map_error(fn(_) { "invalid endpoint URI" }),
  )
  use #(scheme, host) <- result.try(
    case parsed.scheme, parsed.host, parsed.userinfo, parsed.fragment {
      Some("https"), Some(host), None, None
      | Some("http"), Some(host), None, None
        if host != ""
      ->
        Ok(#(
          case parsed.scheme {
            Some(scheme) -> scheme
            None -> ""
          },
          host,
        ))
      _, _, _, _ ->
        Error(
          "endpoint must be absolute HTTP or HTTPS without userinfo or fragment",
        )
    },
  )
  let port = case parsed.port {
    Some(port) -> port
    None ->
      case scheme {
        "https" -> 443
        _ -> 80
      }
  }
  use Nil <- result.try(case port > 0 && port <= 65_535 {
    True -> Ok(Nil)
    False -> Error("invalid endpoint port")
  })
  use Nil <- result.try(
    list.try_fold(auth_headers, Nil, fn(_, header) {
      let name = string.lowercase(header.0)
      case
        http_headers.valid_token(name)
        && !string.starts_with(name, "mcp-")
        && !list.contains(
          [
            "accept",
            "content-type",
            "content-length",
            "transfer-encoding",
            "host",
            "connection",
          ],
          name,
        )
      {
        False ->
          Error("authentication header conflicts with transport metadata")
        True -> http_headers.decode_value(header.1) |> result.map(fn(_) { Nil })
      }
    }),
  )
  let path = case parsed.path {
    "" -> "/"
    path -> path
  }
  let path = case parsed.query {
    None -> path
    Some(query) -> path <> "?" <> query
  }
  Ok(Config(url, host, port, scheme, path, auth_headers, 8_388_608))
}

/// Constructs the typed client's endpoint with HTTP schema admission installed.
///
/// ## Examples
///
/// `endpoint(config)` is passed to `client.call` with its opaque typed tool.
pub fn endpoint(config: Config) -> request.Endpoint {
  request.endpoint_with_admission(
    config.url,
    fn(outbound) { exchange(config, outbound) },
    fn(input) {
      http_headers.compile(schema.value(input))
      |> result.map(fn(_) { Nil })
      |> result.map_error(request.InvalidArguments)
    },
  )
}

/// Runs one request without retrying, returning its final JSON-RPC envelope.
///
/// ## Examples
///
/// `exchange(config, outbound)` also supports request-scoped notifications.
pub fn exchange(
  config: Config,
  outbound: request.Outbound,
) -> Result(JsonValue, request.Error) {
  use task <- result.try(prepare(config, outbound))
  case
    weft.new_prepared([task])
    |> weft.deadline(outbound.timeout_ms)
    |> weft.start
  {
    [weft.Completed(_, answer)] -> Ok(answer)
    [weft.Failed(_, error)] -> Error(error)
    _ ->
      Error(request.TransportFailed(
        "HTTP exchange interrupted; execution outcome is unknown",
      ))
  }
}

// All envelope and mirror checks finish before this prepared task exists.
// The callback then owns exactly one Gun connection under the scope's ledger.
fn prepare(
  config: Config,
  outbound: request.Outbound,
) -> Result(weft.PreparedTask(JsonValue, request.Error), request.Error) {
  use Nil <- result.try(
    case outbound.timeout_ms >= 1 && outbound.timeout_ms <= 4_294_966_295 {
      True -> Ok(Nil)
      False ->
        Error(request.InvalidArguments(
          "timeout is outside the supported timer range",
        ))
    },
  )
  use headers <- result.try(
    http.headers(outbound.envelope)
    |> result.map_error(request.InvalidArguments),
  )
  use extra <- result.try(
    case outbound.input_schema {
      None -> Ok([])
      Some(input) -> {
        use plan <- result.try(http_headers.compile(schema.value(input)))
        use args <- result.try(http.arguments(outbound.envelope))
        http_headers.headers(plan, args)
      }
    }
    |> result.map_error(request.InvalidArguments),
  )
  use id <- result.try(case jsonrpc.decode(json.to_string(outbound.envelope)) {
    Ok(jsonrpc.ServerRequest(id, _, _)) -> Ok(id)
    _ ->
      Error(request.InvalidArguments(
        "HTTP exchange requires one JSON-RPC request",
      ))
  })
  use policy <- result.try(notification_policy(outbound.envelope, id))
  let headers = list.append(headers, list.append(extra, config.headers))
  let task =
    weft.managed(fn(ledger) {
      use connection <- result.try(
        native.open(
          config.host,
          config.port,
          config.scheme,
          outbound.timeout_ms,
        )
        |> result.map_error(request.TransportFailed),
      )

      // Custody precedes the first POST; cancellation cannot miss the socket.
      case
        weft.adopt_leaf(ledger, connection, fn() { native.close(connection) })
      {
        weft.Refused -> {
          native.close(connection)
          Error(request.TransportFailed("request cancelled before sending"))
        }
        weft.Adopted -> {
          let deadline = native.now() + outbound.timeout_ms
          let answer =
            send(config, outbound, connection, headers, deadline, id, policy)
          native.close(connection)
          answer
        }
      }
    })
  Ok(task)
}

/// The retained scope of one HTTP subscription, owning its worker and socket.
pub opaque type Listening {
  /// The retained scope whose outcome and retirement must be consumed.
  Listening(
    /// The retained request scope that owns its worker and Gun connection.
    run: weft.Detached(JsonValue, request.Error),
  )
}

/// The observed lifetime of a retained subscription.
pub type ListenStatus {
  /// No final response or failure has arrived within the observation budget.
  Pending

  /// The server completed the subscription with a correlated response.
  Completed(
    /// The final correlated envelope remains available to the caller's decoder.
    envelope: JsonValue,
  )

  /// The transport failed or the configured lifetime elapsed.
  Failed(
    /// The refusal remains distinct from a graceful correlated completion.
    error: request.Error,
  )

  /// The scope has joined every worker and native connection it owned.
  Drained
}

/// Starts one retained subscriptions/listen request with caller-owned callbacks.
///
/// Its finite lifetime comes from Outbound.timeout_ms. Notifications, including
/// the first acknowledgement, flow through Outbound.on_notification. Cancellation
/// closes and joins the native socket rather than sending a protocol notification.
///
/// ## Examples
///
/// `listen(config, client.listen_outbound(...))` returns a scope handle.
pub fn listen(
  config: Config,
  outbound: request.Outbound,
) -> Result(Listening, request.Error) {
  use meta <- result.try(
    http.metadata(outbound.envelope)
    |> result.map_error(request.InvalidArguments),
  )
  use Nil <- result.try(case meta.method {
    "subscriptions/listen" -> Ok(Nil)
    _ -> Error(request.InvalidArguments("listen requires subscriptions/listen"))
  })
  use task <- result.try(prepare(config, outbound))
  Ok(Listening(
    weft.new_prepared([task])
    |> weft.deadline(outbound.timeout_ms)
    |> weft.start_detached,
  ))
}

/// Observes a retained subscription without granting another effect request.
///
/// ## Examples
///
/// `poll(listening, 0)` reports Pending while its stream remains open.
pub fn poll(listening: Listening, timeout_ms: Int) -> ListenStatus {
  case weft.pull(listening.run, int.max(0, timeout_ms)) {
    weft.NotYet -> Pending
    weft.AllDelivered -> Drained
    weft.RunLost(_) ->
      Failed(request.TransportFailed("subscription scope was lost"))
    weft.PulledOutcome(weft.Completed(_, envelope)) -> Completed(envelope)
    weft.PulledOutcome(weft.Failed(_, error)) -> Failed(error)
    weft.PulledOutcome(_) ->
      Failed(request.TransportFailed("subscription interrupted"))
  }
}

/// Cancels and joins a subscription's socket and worker before returning.
///
/// ## Examples
///
/// `cancel(listening)` waits for the same scope's terminal drain verdict.
pub fn cancel(listening: Listening) -> Result(Nil, request.Error) {
  weft.cancel_detached(listening.run)
  join(listening.run)
}

// Drain consumes outcomes until the scope reports AllDelivered. A terminal
// value and worker retirement are separate observations.
fn join(
  run: weft.Detached(JsonValue, request.Error),
) -> Result(Nil, request.Error) {
  case weft.pull(run, 1000) {
    weft.AllDelivered -> Ok(Nil)
    weft.RunLost(_) ->
      Error(request.TransportFailed("subscription drain could not be proven"))
    weft.NotYet | weft.PulledOutcome(_) -> join(run)
  }
}

// This is the first network effect after adoption. All subsequent receives
// use the same absolute deadline; none restarts the caller's budget.
fn send(
  config: Config,
  outbound: request.Outbound,
  connection,
  headers,
  deadline,
  id,
  policy,
) {
  use stream <- result.try(
    native.post(
      connection,
      config.path,
      headers,
      json.to_string(outbound.envelope),
      remaining(deadline),
    )
    |> result.map_error(request.TransportFailed),
  )
  receive_headers(config, outbound, connection, stream, deadline, id, policy)
}

fn remaining(deadline: Int) -> Int {
  int.max(0, deadline - native.now())
}

// Informational responses leave the same request outstanding. Status and
// media type decide how body bytes are interpreted, while final correlation
// remains mandatory even for a JSON error body.
fn receive_headers(
  config: Config,
  outbound: request.Outbound,
  connection,
  stream,
  deadline,
  id,
  policy,
) {
  use event <- result.try(
    native.next(connection, stream, remaining(deadline))
    |> result.map_error(request.TransportFailed),
  )
  case event {
    native.Inform ->
      receive_headers(
        config,
        outbound,
        connection,
        stream,
        deadline,
        id,
        policy,
      )
    native.Headers(completion, status, headers) -> {
      use content_type <- result.try(
        http_headers.get(headers, "content-type")
        |> result.map_error(request.InvalidResponse),
      )
      let content_type =
        content_type
        |> string.split(";")
        |> list.first
        |> result.unwrap("")
        |> string.trim
        |> string.lowercase
      case status >= 200 && status < 300, content_type, completion {
        _, "application/json", native.More ->
          receive_json(config, connection, stream, deadline, id, <<>>, policy)
        True, "text/event-stream", native.More -> {
          use decoder <- result.try(
            sse.new(config.limit) |> result.map_error(request.InvalidResponse),
          )
          receive_sse(
            outbound,
            connection,
            stream,
            deadline,
            id,
            decoder,
            policy,
          )
        }
        _, _, _ ->
          Error(request.InvalidResponse(
            "unsupported HTTP status, content type, or empty response",
          ))
      }
    }
    _ -> Error(request.InvalidResponse("HTTP body preceded headers"))
  }
}

// Body credit is renewed after the byte cap has been checked and the fragment
// consumed. The pending bytes belong only to this one response.
fn receive_json(
  config: Config,
  connection,
  stream,
  deadline,
  id,
  bytes,
  policy,
) {
  use event <- result.try(
    native.next(connection, stream, remaining(deadline))
    |> result.map_error(request.TransportFailed),
  )
  case event {
    native.Data(completion, data) -> {
      use Nil <- result.try(
        case
          bit_array.byte_size(bytes) + bit_array.byte_size(data) <= config.limit
        {
          True -> Ok(Nil)
          False ->
            Error(request.InvalidResponse("JSON response exceeds byte limit"))
        },
      )
      let bytes = bit_array.append(bytes, data)
      case completion {
        native.More -> {
          native.credit(connection, stream)
          receive_json(config, connection, stream, deadline, id, bytes, policy)
        }
        native.Finished -> final_json(bytes, id, policy)
      }
    }
    native.Trailers -> final_json(bytes, id, policy)
    _ ->
      Error(request.InvalidResponse("unexpected HTTP event in JSON response"))
  }
}

fn final_json(bytes, id, policy) {
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_) {
      request.InvalidResponse("invalid UTF-8 JSON response")
    }),
  )
  use value <- result.try(
    json.parse(text)
    |> result.map_error(fn(_) {
      request.InvalidResponse("malformed JSON response")
    }),
  )
  case jsonrpc.decode(text) {
    Ok(jsonrpc.Response(response_id, outcome)) if response_id == id -> {
      use Nil <- result.try(final_policy(policy, outcome))
      Ok(value)
    }
    _ -> Error(request.InvalidResponse("uncorrelated JSON-RPC response"))
  }
}

// Complete events are validated before observer delivery. A stream end without
// a correlated final result leaves the remote execution outcome unknown.
fn receive_sse(
  outbound: request.Outbound,
  connection,
  stream,
  deadline,
  id,
  decoder,
  policy,
) {
  use event <- result.try(
    native.next(connection, stream, remaining(deadline))
    |> result.map_error(request.TransportFailed),
  )
  case event {
    native.Data(completion, bytes) -> {
      use #(decoder, events) <- result.try(
        sse.feed(decoder, bytes) |> result.map_error(request.InvalidResponse),
      )
      use #(policy, final) <- result.try(messages(
        events,
        id,
        outbound.on_notification,
        policy,
        None,
      ))
      case final, completion {
        Some(value), _ -> Ok(value)
        None, native.Finished ->
          Error(request.TransportFailed(
            "SSE stream closed before a final response; execution outcome is unknown",
          ))
        None, native.More -> {
          native.credit(connection, stream)
          receive_sse(
            outbound,
            connection,
            stream,
            deadline,
            id,
            decoder,
            policy,
          )
        }
      }
    }
    native.Trailers ->
      Error(request.TransportFailed(
        "SSE stream ended without a final response; execution outcome is unknown",
      ))
    _ -> Error(request.InvalidResponse("unexpected HTTP event in SSE stream"))
  }
}

type NotificationPolicy {
  RequestNotifications
  SubscriptionNotifications(stream: subscription.Stream)
}

fn notification_policy(
  envelope: JsonValue,
  id: jsonrpc.Id,
) -> Result(NotificationPolicy, request.Error) {
  use meta <- result.try(
    http.metadata(envelope) |> result.map_error(request.InvalidArguments),
  )
  case meta.method {
    "subscriptions/listen" ->
      {
        use fields <- result.try(case envelope {
          json.Object(fields) -> Ok(fields)
          _ -> Error("invalid envelope")
        })
        use params <- result.try(case list.key_find(fields, "params") {
          Ok(json.Object(fields)) -> Ok(fields)
          _ -> Error("invalid subscription params")
        })
        use filter <- result.try(
          list.key_find(params, "notifications")
          |> result.map_error(fn(_) { "missing subscription notifications" }),
        )
        subscription.decode(filter)
        |> result.map(fn(requested) {
          SubscriptionNotifications(subscription.stream(id, requested))
        })
      }
      |> result.map_error(request.InvalidArguments)
    _ -> Ok(RequestNotifications)
  }
}

// Events from one fragment remain ordered. Once a final response is admitted,
// any following event in that fragment is a protocol refusal.
fn messages(
  events: List(String),
  id: jsonrpc.Id,
  notify: fn(JsonValue) -> Nil,
  policy: NotificationPolicy,
  final,
) {
  case events, final {
    [], final -> Ok(#(policy, final))
    [_, ..], Some(_) ->
      Error(request.InvalidResponse("message followed final SSE response"))
    [event, ..rest], None -> {
      use value <- result.try(
        json.parse(event)
        |> result.map_error(fn(_) {
          request.InvalidResponse("invalid SSE JSON")
        }),
      )
      case jsonrpc.decode(event) {
        Ok(jsonrpc.Response(response_id, outcome)) if response_id == id -> {
          use Nil <- result.try(final_policy(policy, outcome))
          messages(rest, id, notify, policy, Some(value))
        }
        Ok(jsonrpc.Notification(_, _)) -> {
          use policy <- result.try(
            notification(policy, value)
            |> result.map_error(request.InvalidResponse),
          )
          notify(value)
          messages(rest, id, notify, policy, None)
        }
        _ ->
          Error(request.InvalidResponse(
            "independent request or uncorrelated response on SSE stream",
          ))
      }
    }
  }
}

fn final_policy(
  policy: NotificationPolicy,
  outcome,
) -> Result(Nil, request.Error) {
  case policy, outcome {
    SubscriptionNotifications(stream), Ok(value) ->
      subscription.complete(stream, value)
      |> result.map_error(request.InvalidResponse)
    _, _ -> Ok(Nil)
  }
}

fn notification(
  policy: NotificationPolicy,
  value: JsonValue,
) -> Result(NotificationPolicy, String) {
  case policy {
    RequestNotifications -> Ok(policy)
    SubscriptionNotifications(stream) ->
      subscription.accept(stream, value)
      |> result.map(SubscriptionNotifications)
  }
}
