import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam_mcp/client
import gleam_mcp/json
import gleam_mcp/oauth.{type HttpRequest}
import gleam_mcp/protocol
import gleam_mcp/sse
import gleam_mcp/streamable_http.{
  type HttpEvent, type HttpTransport, Config, HttpTransport, MalformedFault,
  NoAuth, OAuth, PreparedHttp, ResponseChunk, ResponseEnd, ResponseStatus,
  RunningHttp,
}

fn scripted_transport(
  handler: fn(HttpRequest, Subject(HttpEvent)) -> Nil,
) -> HttpTransport {
  HttpTransport(prepare_streaming: fn(req, events) {
    let ready = process.new_subject()
    let pid =
      process.spawn_unlinked(fn() {
        let control = process.new_subject()
        process.send(ready, control)
        case process.receive(control, 5000) {
          Ok(True) -> handler(req, events)
          Ok(False) | Error(Nil) -> Nil
        }
      })
    let assert Ok(control) = process.receive(ready, 1000)
      as "worker must report subject"
    Ok(
      PreparedHttp(
        running: RunningHttp(owner: pid, cancel: fn() {
          process.send(control, False)
        }),
        begin: fn() { process.send(control, True) },
      ),
    )
  })
}

pub fn initialized_session_retains_session_id_handles_sse_and_deletes_on_shutdown_test() {
  let seen = process.new_subject()
  let http_transport =
    scripted_transport(fn(req, events) {
      process.send(seen, #(req.method, req.headers, req.body))
      case req.method, string.contains(req.body, "\"initialize\"") {
        "POST", True -> {
          process.send(
            events,
            ResponseStatus(200, [
              #("content-type", "application/json"),
              #("mcp-session-id", "sess-42"),
            ]),
          )
          let reply =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}}}"
          process.send(events, ResponseChunk(bit_array.from_string(reply)))
          process.send(events, ResponseEnd)
        }
        "POST", False ->
          case
            string.contains(req.body, "notifications/initialized"),
            string.contains(req.body, "tools/list")
          {
            True, _ -> {
              process.send(events, ResponseStatus(202, []))
              process.send(events, ResponseEnd)
            }
            False, True -> {
              process.send(
                events,
                ResponseStatus(200, [
                  #("content-type", "text/event-stream"),
                  #("mcp-session-id", "sess-42"),
                ]),
              )
              let page =
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"ping\",\"inputSchema\":{\"type\":\"object\"}}]}}"
              process.send(
                events,
                ResponseChunk(bit_array.from_string(sse.encode(page))),
              )
              process.send(events, ResponseEnd)
            }
            False, False -> {
              process.send(
                events,
                ResponseStatus(200, [#("content-type", "application/json")]),
              )
              let call_res =
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"pong\"}]}}"
              process.send(
                events,
                ResponseChunk(bit_array.from_string(call_res)),
              )
              process.send(events, ResponseEnd)
            }
          }
        "DELETE", _ -> {
          process.send(events, ResponseStatus(204, []))
          process.send(events, ResponseEnd)
        }
        _, _ -> Nil
      }
    })
  let config =
    Config(
      server: "remote",
      url: "https://mcp.example.com/mcp",
      auth: NoAuth,
      http_transport:,
      client_name: "loom",
      client_version: "0.3.2",
      login_command: "loomd mcp login",
      request_timeout_ms: 5000,
    )
  let assert Ok(started) =
    client.start(
      streamable_http.seam(config),
      client.options("0.3.2") |> client.with_client_name("loom"),
    )
    as "start initialized streamable HTTP client"
  let assert Ok(tools) = client.list_tools(started, 5000)
    as "list tools over SSE"
  assert list.map(tools, fn(t) { t.name }) == ["ping"]

  let assert Ok(result) =
    client.call_tool(started, "ping", json.Object([]), 5000)
    as "call tool over streamable HTTP"
  assert result.content == [protocol.Text("pong")]

  let assert Ok(Nil) = client.shutdown(started, 5000)
    as "shutdown sends DELETE and confirms retirement"

  let recorded = drain(seen, [])
  assert list.any(recorded, fn(entry) {
    entry.0 == "DELETE"
    && list.contains(entry.1, #("mcp-session-id", "sess-42"))
  })
}

pub fn stateless_modern_2026_07_28_fallback_probes_discovery_and_mirrors_headers_test() {
  let seen = process.new_subject()
  let http_transport =
    scripted_transport(fn(req, events) {
      process.send(seen, #(req.method, req.headers, req.body))
      case
        string.contains(req.body, "\"initialize\""),
        string.contains(req.body, "\"discovery/discover\""),
        string.contains(req.body, "\"tools/list\"")
      {
        True, _, _ -> {
          process.send(
            events,
            ResponseStatus(200, [#("content-type", "application/json")]),
          )
          let err =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"initialize not supported on 2026-07-28\"}}"
          process.send(events, ResponseChunk(bit_array.from_string(err)))
          process.send(events, ResponseEnd)
        }
        False, True, _ -> {
          process.send(
            events,
            ResponseStatus(200, [#("content-type", "application/json")]),
          )
          let disc =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"tools\":{}},\"ttlMs\":0,\"cacheScope\":\"private\"}}"
          process.send(events, ResponseChunk(bit_array.from_string(disc)))
          process.send(events, ResponseEnd)
        }
        False, False, True -> {
          process.send(
            events,
            ResponseStatus(200, [#("content-type", "application/json")]),
          )
          let page =
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"lookup\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"tenant\":{\"type\":\"string\",\"x-mcp-header\":\"X-Tenant\"}}}}]}}"
          process.send(events, ResponseChunk(bit_array.from_string(page)))
          process.send(events, ResponseEnd)
        }
        False, False, False -> {
          process.send(
            events,
            ResponseStatus(200, [#("content-type", "application/json")]),
          )
          let call_res =
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}"
          process.send(events, ResponseChunk(bit_array.from_string(call_res)))
          process.send(events, ResponseEnd)
        }
      }
    })
  let config =
    Config(
      server: "modern",
      url: "https://mcp.example.com/mcp",
      auth: NoAuth,
      http_transport:,
      client_name: "loom",
      client_version: "0.3.2",
      login_command: "loomd mcp login",
      request_timeout_ms: 5000,
    )
  let assert Ok(started) =
    client.start(
      streamable_http.seam(config),
      client.options("0.3.2") |> client.with_client_name("loom"),
    )
    as "start against 2026-07-28 server"
  let assert Ok(tools) = client.list_tools(started, 5000)
    as "list 2026-07-28 tools"
  assert list.map(tools, fn(t) { t.name }) == ["lookup"]

  let assert Ok(_) =
    client.call_tool(
      started,
      "lookup",
      json.Object([#("tenant", json.String("acme"))]),
      5000,
    )
    as "call 2026-07-28 tool with x-mcp-header"
  let assert Ok(Nil) = client.shutdown(started, 5000)
    as "shutdown modern client"

  let recorded = drain(seen, [])
  assert list.any(recorded, fn(entry) {
    list.contains(entry.1, #("mcp-protocol-version", "2026-07-28"))
    && list.contains(entry.1, #("mcp-method", "tools/call"))
    && list.contains(entry.1, #("mcp-name", "lookup"))
    && list.contains(entry.1, #("mcp-param-X-Tenant", "acme"))
  })
}

pub fn oauth_unauthorized_retries_once_and_oversized_body_tags_malformed_fault_test() {
  let attempts = process.new_subject()
  let http_transport =
    scripted_transport(fn(req, events) {
      process.send(attempts, req.headers)
      case
        list.contains(req.headers, #("authorization", "Bearer fresh-token"))
      {
        False -> {
          process.send(events, ResponseStatus(401, []))
          process.send(events, ResponseEnd)
        }
        True ->
          case string.contains(req.body, "\"initialize\"") {
            True -> {
              process.send(
                events,
                ResponseStatus(200, [#("content-type", "application/json")]),
              )
              let reply =
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}}}"
              process.send(events, ResponseChunk(bit_array.from_string(reply)))
              process.send(events, ResponseEnd)
            }
            False -> {
              process.send(
                events,
                ResponseStatus(200, [#("content-type", "application/json")]),
              )
              let huge = <<
                0:size(streamable_http.max_response_bytes)-unit(8),
                65,
              >>
              process.send(events, ResponseChunk(huge))
              process.send(events, ResponseEnd)
            }
          }
      }
    })
  let config =
    Config(
      server: "oauth_srv",
      url: "https://mcp.example.com/mcp",
      auth: OAuth(
        authorize: fn(_) { Ok("stale-token") },
        refresh_unauthorized: fn(rejected, _) {
          assert rejected == "stale-token"
          Ok("fresh-token")
        },
      ),
      http_transport:,
      client_name: "loom",
      client_version: "0.3.2",
      login_command: "loomd mcp login",
      request_timeout_ms: 5000,
    )
  let assert Ok(started) =
    client.start(
      streamable_http.seam(config),
      client.options("0.3.2") |> client.with_client_name("loom"),
    )
    as "401 on initialize refreshes and succeeds"
  let assert Error(client.ServerError(message:, ..)) =
    client.list_tools(started, 5000)
    as "oversized response returns tagged fault"
  let assert Some(MalformedFault(reason:)) =
    streamable_http.classify_fault(message)
    as "tagged fault classifies as MalformedFault"
  assert string.contains(reason, "-byte limit")
  let assert Ok(Nil) = client.shutdown(started, 5000) as "shutdown after fault"
}

pub fn initialized_notification_gates_subsequent_requests_and_recovers_expired_session_on_404_test() {
  let order = process.new_subject()
  let http_transport =
    scripted_transport(fn(req, events) {
      case
        string.contains(req.body, "\"initialize\""),
        string.contains(req.body, "notifications/initialized"),
        list.contains(req.headers, #("mcp-session-id", "sess-expired"))
      {
        True, _, _ -> {
          let sid = case string.contains(req.body, "\"reinit\"") {
            True -> "sess-recovered"
            False -> "sess-expired"
          }
          process.send(order, "initialize:" <> sid)
          process.send(
            events,
            ResponseStatus(200, [
              #("content-type", "application/json"),
              #("mcp-session-id", sid),
            ]),
          )
          let reply =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}}}"
          let body = case string.contains(req.body, "\"reinit\"") {
            True ->
              "{\"jsonrpc\":\"2.0\",\"id\":\"reinit\",\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}}}"
            False -> reply
          }
          process.send(events, ResponseChunk(bit_array.from_string(body)))
          process.send(events, ResponseEnd)
        }
        False, True, True -> {
          process.sleep(60)
          process.send(order, "notifications/initialized")
          process.send(events, ResponseStatus(202, []))
          process.send(events, ResponseEnd)
        }
        False, True, False -> {
          process.send(order, "notifications/initialized:recovered")
          process.send(events, ResponseStatus(202, []))
          process.send(events, ResponseEnd)
        }
        False, False, True -> {
          process.send(order, "tools/list:expired-404")
          process.send(events, ResponseStatus(404, []))
          process.send(events, ResponseEnd)
        }
        False, False, False ->
          case string.contains(req.body, "\"id\":88") {
            True -> {
              assert list.contains(req.headers, #(
                "mcp-session-id",
                "sess-recovered",
              ))
              process.send(order, "response:88:sess-recovered")
              process.send(events, ResponseStatus(202, []))
              process.send(events, ResponseEnd)
            }
            False -> {
              process.send(order, "tools/list:recovered")
              process.send(
                events,
                ResponseStatus(200, [#("content-type", "text/event-stream")]),
              )
              let srv_req =
                "{\"jsonrpc\":\"2.0\",\"id\":88,\"method\":\"roots/list\"}"
              let page =
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[{\"name\":\"ok\",\"inputSchema\":{\"type\":\"object\"}}]}}"
              process.send(
                events,
                ResponseChunk(bit_array.from_string(sse.encode(srv_req))),
              )
              process.sleep(40)
              process.send(
                events,
                ResponseChunk(bit_array.from_string(sse.encode(page))),
              )
              process.send(events, ResponseEnd)
            }
          }
      }
    })
  let config =
    Config(
      server: "gated",
      url: "https://mcp.example.com/mcp",
      auth: NoAuth,
      http_transport:,
      client_name: "loom",
      client_version: "0.3.2",
      login_command: "loomd mcp login",
      request_timeout_ms: 5000,
    )
  let assert Ok(started) =
    client.start(
      streamable_http.seam(config),
      client.options("0.3.2") |> client.with_client_name("loom"),
    )
    as "start client while notifications/initialized is gated"
  let first_list = client.list_tools(started, 5000)
  assert case first_list {
    Error(_) -> True
    Ok(_) -> False
  }
  let assert Ok(tools) = client.list_tools(started, 5000)
    as "second list_tools transparently reinitializes after session 404"
  assert list.map(tools, fn(t) { t.name }) == ["ok"]
  let events_order = drain(order, [])
  assert events_order
    == [
      "initialize:sess-expired",
      "notifications/initialized",
      "tools/list:expired-404",
      "initialize:sess-recovered",
      "notifications/initialized:recovered",
      "tools/list:recovered",
      "response:88:sess-recovered",
    ]
  let assert Ok(Nil) = client.shutdown(started, 5000) as "shutdown gated client"
}

pub fn sse_server_request_and_stalled_request_timeout_cleanup_test() {
  let seen_bodies = process.new_subject()
  let http_transport =
    scripted_transport(fn(req, events) {
      process.send(seen_bodies, req.body)
      case
        string.contains(req.body, "\"initialize\""),
        string.contains(req.body, "notifications/initialized"),
        string.contains(req.body, "\"tools/list\""),
        string.contains(req.body, "\"tools/call\"")
      {
        True, _, _, _ -> {
          process.send(
            events,
            ResponseStatus(200, [#("content-type", "application/json")]),
          )
          let reply =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}}}"
          process.send(events, ResponseChunk(bit_array.from_string(reply)))
          process.send(events, ResponseEnd)
        }
        False, True, _, _ -> {
          process.send(events, ResponseStatus(202, []))
          process.send(events, ResponseEnd)
        }
        False, False, True, _ -> {
          process.send(
            events,
            ResponseStatus(200, [#("content-type", "text/event-stream")]),
          )
          let srv_req =
            "{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"roots/list\"}"
          let progress =
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":50}}"
          let page =
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"stall\",\"inputSchema\":{\"type\":\"object\"}}]}}"
          let stream =
            sse.encode(srv_req) <> sse.encode(progress) <> sse.encode(page)
          process.send(events, ResponseChunk(bit_array.from_string(stream)))
          process.send(events, ResponseEnd)
        }
        False, False, False, True -> {
          process.sleep(500)
        }
        False, False, False, False -> {
          process.send(events, ResponseStatus(202, []))
          process.send(events, ResponseEnd)
        }
      }
    })
  let config =
    Config(
      server: "sse_and_timeout",
      url: "https://mcp.example.com/mcp",
      auth: NoAuth,
      http_transport:,
      client_name: "loom",
      client_version: "0.3.2",
      login_command: "loomd mcp login",
      request_timeout_ms: 80,
    )
  let assert Ok(started) =
    client.start(
      streamable_http.seam(config),
      client.options("0.3.2") |> client.with_client_name("loom"),
    )
    as "start client"
  let assert Ok(tools) = client.list_tools(started, 5000)
    as "list_tools succeeds when SSE stream interleaves server request and progress notification"
  assert list.map(tools, fn(t) { t.name }) == ["stall"]
  let _ = client.call_tool(started, "stall", json.Object([]), 5000)
  let assert Ok(Nil) = client.shutdown(started, 5000)
    as "shutdown succeeds cleanly after timed-out request"
  let bodies = drain(seen_bodies, [])
  assert list.any(bodies, fn(b) { string.contains(b, "\"id\":77") })
}

fn drain(subject: Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}
