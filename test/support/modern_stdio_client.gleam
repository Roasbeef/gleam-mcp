//// The production native client against an independent Python wire peer.

import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam_mcp/client
import gleam_mcp/codec
import gleam_mcp/json
import gleam_mcp/jsonrpc
import gleam_mcp/mrtr
import gleam_mcp/request
import gleam_mcp/schema
import gleam_mcp/server
import gleam_mcp/subscription
import gleam_mcp/tool
import gleam_mcp/transport

fn definition() {
  let assert Ok(input) =
    schema.new(
      server.object_schema(
        [
          #("n", json.Object([#("type", json.String("integer"))])),
        ],
        ["n"],
      ),
    )
    as "input schema compiles"
  let args =
    codec.new(input, fn(n) { json.Object([#("n", json.Int(n))]) }, fn(raw) {
      case raw {
        json.Object(fields) ->
          case list.key_find(fields, "n") {
            Ok(json.Int(n)) -> Ok(n)
            _ -> Error("n missing")
          }
        _ -> Error("object missing")
      }
    })
  let assert Ok(output) = codec.int() as "output schema compiles"
  let assert Ok(definition) =
    tool.new("number", "Returns the original n.", args, output)
    as "definition compiles"
  definition
  |> tool.with_result_decoder(fn(original, raw) {
    case raw {
      json.Int(value) if value == original -> Ok(value)
      _ -> Error("original criteria were not preserved")
    }
  })
}

/// Exercises native framing, original stream ids, interleaving and MRTR.
///
/// ## Examples
///
/// ```gleam
/// // modern_stdio_client.run(python, peer_script)
/// ```
pub fn run(python: String, peer_script: String) -> Nil {
  let assert Ok(native) =
    client.start_modern(
      transport.PortTransport(transport.spawn(python, ["-u", peer_script])),
    )
    as "modern native client starts without initialize"
  let observed = process.new_subject()
  let options =
    request.options("native-witness", "1") |> request.with_timeout(5000)
  let listen_options =
    options
    |> request.with_notifications(fn(message) {
      process.send(observed, message)
    })
  let assert Ok(listening) =
    client.listen(native, subscription.tools(), listen_options)
    as "owned native subscription starts"
  let original_id = client.listening_id(listening)
  let assert Ok(ack) = process.receive(observed, 2000)
    as "ack arrives while stream is live"
  let assert Ok(jsonrpc.Correlated(jsonrpc.Notification(
    "notifications/subscriptions/acknowledged",
    Some(params),
  ))) = jsonrpc.decode_value(ack)
    as "first observer message is acknowledgement"
  assert subscription.notification_id(params) == Ok(original_id)

  let definition = definition()
  let assert Ok(client.InputRequired(continuation)) =
    client.call(client.endpoint(native), definition, 17, options)
    as "first explicit effect suspends"
  let assert Ok(changed) = process.receive(observed, 2000)
    as "interleaved list change arrives"
  let assert Ok(jsonrpc.Correlated(jsonrpc.Notification(
    "notifications/tools/list_changed",
    Some(params),
  ))) = jsonrpc.decode_value(changed)
    as "second observer message is list change"
  assert subscription.notification_id(params) == Ok(original_id)
  let assert Ok(responses) =
    mrtr.responses(client.continuation_required(continuation), [])
    as "state-only continuation requires no provider"
  assert client.resume(continuation, responses, options)
    == Ok(client.Complete(17))
  assert client.cancel_listening(listening) == Ok(Nil)
  assert client.call(client.endpoint(native), definition, 23, options)
    == Ok(client.Complete(23))
  assert client.shutdown(native, 2000) == Ok(Nil)
  io.println("NATIVE_MODERN_OK")
}
