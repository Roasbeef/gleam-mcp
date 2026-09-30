//// Native HTTP peers use this fixture to prove socket-to-worker cancellation.

import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/client_http
import gleam_mcp/json
import gleam_mcp/jsonrpc
import gleam_mcp/metadata
import gleam_mcp/request
import gleam_mcp/schema
import gleam_mcp/server as mcp_server
import gleam_mcp/server_http

/// Boots a real listener and reports the death of each admitted callback.
pub fn server(port: Int) {
  let admitted = process.new_subject()
  let assert Ok(input) =
    schema.new(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #(
              "tenant",
              json.Object([
                #("type", json.String("string")),
                #("x-mcp-header", json.String("Tenant")),
              ]),
            ),
          ]),
        ),
      ]),
    )
  let assert Ok(config) =
    server_http.new(
      port,
      "/mcp",
      ["http://allowed.example"],
      server_http.LocalUnauthenticated,
    )
  let assert Ok(_) =
    server_http.start(
      config,
      fn(envelope, emit) {
        process.send(admitted, process.self())
        let assert Ok(jsonrpc.ServerRequest(id, method, params)) =
          jsonrpc.decode(json.to_string(envelope))
        let mode = case params {
          Some(json.Object(fields)) -> list.key_find(fields, "mode")
          _ -> Error(Nil)
        }
        case method, mode {
          "subscriptions/listen", _ -> {
            emit(jsonrpc.notification(
              "notifications/subscriptions/acknowledged",
              Some(
                json.Object([
                  #("notifications", json.Object([])),
                  #(
                    "_meta",
                    json.Object([
                      #("io.modelcontextprotocol/subscriptionId", json.Int(7)),
                    ]),
                  ),
                ]),
              ),
            ))
            let parked = process.new_subject()
            process.receive_forever(parked)
          }
          _, Ok(json.String("mrtr")) -> {
            let resumed = case params {
              Some(json.Object(fields)) -> list.key_find(fields, "requestState")
              _ -> Error(Nil)
            }
            case resumed {
              Ok(json.String("opaque-state")) ->
                Some(jsonrpc.response(
                  id,
                  json.Object([
                    #("resultType", json.String("complete")),
                    #("ok", json.Bool(True)),
                  ]),
                ))
              _ ->
                Some(jsonrpc.response(
                  id,
                  json.Object([
                    #("resultType", json.String("input_required")),
                    #("requestState", json.String("opaque-state")),
                  ]),
                ))
            }
          }
          _, Ok(json.String("block")) -> {
            emit(jsonrpc.notification(
              "notifications/progress",
              Some(json.Object([#("progress", json.Int(1))])),
            ))
            let parked = process.new_subject()
            process.receive_forever(parked)
          }
          _, _ ->
            Some(jsonrpc.response(id, json.Object([#("ok", json.Bool(True))])))
        }
      },
      fn(name) {
        case name {
          "echo" -> Some(input)
          _ -> None
        }
      },
    )
  io.println("READY")
  observe(admitted)
}

fn observe(admitted) {
  let worker = process.receive_forever(admitted)
  let watch = process.monitor(worker)
  io.println("WORKER_STARTED")
  process.new_selector()
  |> process.select_specific_monitor(watch, fn(_) { Nil })
  |> process.selector_receive_forever
  io.println("WORKER_DOWN")
  observe(admitted)
}

/// Performs one native client request against an independent Python server.
pub fn client(url: String, timeout: Int) {
  let assert Ok(config) = client_http.new(url, [])
  let options = request.options("native", "1") |> request.with_timeout(timeout)
  let envelope =
    jsonrpc.request(
      jsonrpc.IdInt(7),
      "tools/list",
      Some(json.Object([#("_meta", metadata.value(request.metadata(options)))])),
    )
  let outbound = request.outbound(options, envelope, None)
  case client_http.exchange(config, outbound) {
    Ok(value) -> io.println(json.to_string(value))
    Error(_) -> io.println("FAILED")
  }
}

/// Sends mirrored primitive arguments against an independent native HTTP peer.
pub fn client_tool(url: String, timeout: Int) {
  let assert Ok(config) = client_http.new(url, [])
  let assert Ok(input) =
    schema.new(
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #(
              "tenant",
              json.Object([
                #("type", json.String("string")),
                #("x-mcp-header", json.String("Tenant")),
              ]),
            ),
          ]),
        ),
      ]),
    )
  let options = request.options("native", "1") |> request.with_timeout(timeout)
  let envelope =
    jsonrpc.request(
      jsonrpc.IdInt(7),
      "tools/call",
      Some(
        json.Object([
          #("_meta", metadata.value(request.metadata(options))),
          #("name", json.String("漢😀")),
          #("arguments", json.Object([#("tenant", json.String(" padded "))])),
        ]),
      ),
    )
  let outbound = request.outbound(options, envelope, Some(input))
  case client_http.exchange(config, outbound) {
    Ok(value) -> io.println(json.to_string(value))
    Error(_) -> io.println("FAILED")
  }
}

/// Retains and explicitly drains a native subscription after observing its ack.
pub fn client_listen(url: String, timeout: Int) {
  let assert Ok(config) = client_http.new(url, [])
  let notifications = process.new_subject()
  let options =
    request.options("native", "1")
    |> request.with_timeout(timeout)
    |> request.with_notifications(fn(value) {
      process.send(notifications, value)
    })
  let envelope =
    jsonrpc.request(
      jsonrpc.IdInt(7),
      "subscriptions/listen",
      Some(
        json.Object([
          #("_meta", metadata.value(request.metadata(options))),
          #(
            "notifications",
            json.Object([#("toolsListChanged", json.Bool(True))]),
          ),
        ]),
      ),
    )
  let outbound = request.outbound(options, envelope, None)
  let assert Ok(listening) = client_http.listen(config, outbound)
  case process.receive(notifications, timeout) {
    Ok(_) -> {
      case client_http.poll(listening, 200) {
        client_http.Pending -> io.println("ACKNOWLEDGED")
        _ -> io.println("FAILED")
      }
    }
    Error(_) -> io.println("FAILED")
  }
  let assert Ok(Nil) = client_http.cancel(listening)
  io.println("DRAINED")
}

/// Distinguishes a validated graceful subscription result from rejection.
///
/// ## Examples
///
/// `client_listen_final(url, 2000)` observes a peer acknowledgement and final.
pub fn client_listen_final(url: String, timeout: Int) {
  let assert Ok(config) = client_http.new(url, [])
  let notifications = process.new_subject()
  let options =
    request.options("native", "1")
    |> request.with_timeout(timeout)
    |> request.with_notifications(fn(value) {
      process.send(notifications, value)
    })
  let envelope =
    jsonrpc.request(
      jsonrpc.IdInt(7),
      "subscriptions/listen",
      Some(
        json.Object([
          #("_meta", metadata.value(request.metadata(options))),
          #(
            "notifications",
            json.Object([#("toolsListChanged", json.Bool(True))]),
          ),
        ]),
      ),
    )
  let outbound = request.outbound(options, envelope, None)
  let assert Ok(listening) = client_http.listen(config, outbound)
  case process.receive(notifications, timeout) {
    Ok(_) -> {
      case client_http.poll(listening, 200) {
        client_http.Pending -> io.println("PENDING")
        client_http.Completed(_) -> io.println("COMPLETED")
        _ -> io.println("FAILED")
      }
    }
    Error(_) -> {
      case client_http.poll(listening, 200) {
        client_http.Completed(_) -> io.println("COMPLETED")
        client_http.Pending -> io.println("PENDING")
        _ -> io.println("FAILED")
      }
    }
  }
  let assert Ok(Nil) = client_http.cancel(listening)
  io.println("DRAINED")
}

/// Boots the public immutable server adapter without a protocol initialize step.
pub fn registry(port: Int) {
  let assert Ok(config) =
    server_http.new(port, "/mcp", [], server_http.LocalUnauthenticated)
  let assert Ok(registry) = mcp_server.new("native", "1", [])
  let assert Ok(_) = server_http.start_server(config, registry)
  io.println("READY")
  let parked = process.new_subject()
  process.receive_forever(parked)
}
