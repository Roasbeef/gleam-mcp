import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam_mcp/client
import gleam_mcp/codec
import gleam_mcp/discovery
import gleam_mcp/http_headers as gleam_mcp_http_headers
import gleam_mcp/json
import gleam_mcp/jsonrpc
import gleam_mcp/metadata
import gleam_mcp/mrtr
import gleam_mcp/protocol
import gleam_mcp/request
import gleam_mcp/schema
import gleam_mcp/server
import gleam_mcp/subscription as gleam_mcp_subscription
import gleam_mcp/tool
import gleam_mcp/version

fn arguments() -> codec.Codec(Int) {
  let assert Ok(schema) =
    schema.new(
      server.object_schema(
        [
          #("n", json.Object([#("type", json.String("integer"))])),
        ],
        ["n"],
      ),
    )
    as "argument schema compiles"
  codec.new(schema, fn(n) { json.Object([#("n", json.Int(n))]) }, fn(raw) {
    case raw {
      json.Object(fields) ->
        case list.key_find(fields, "n") {
          Ok(json.Int(n)) -> Ok(n)
          _ -> Error("n must be integer")
        }
      _ -> Error("object required")
    }
  })
}

fn definition() -> tool.Tool(Int, Int) {
  let assert Ok(output) = codec.int() as "output codec compiles"
  let assert Ok(definition) =
    tool.new("number", "Returns n.", arguments(), output)
    as "definition is valid"
  definition
}

fn registry(
  handler: fn(Int) -> Result(Int, server.ToolError),
) -> server.Server {
  let assert Ok(binding) = server.bind(definition(), handler)
    as "typed binding is valid"
  let assert Ok(registry) = server.new("typed", "1", [binding])
    as "unique registry is valid"
  registry |> server.modern
}

fn endpoint(registry: server.Server) -> request.Endpoint {
  request.endpoint("pure", fn(outbound) {
    let #(_, response) = server.handle_message(registry, outbound.envelope)
    case response {
      Some(response) -> Ok(response)
      None -> Error(request.InvalidResponse("response required"))
    }
  })
}

fn options() -> request.Options {
  request.options("typed-test", "1")
}

fn modern(
  id: Int,
  method: String,
  fields: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  jsonrpc.request(
    jsonrpc.IdInt(id),
    method,
    Some(
      json.Object([
        #("_meta", metadata.value(metadata.new(version.V20260728))),
        ..fields
      ]),
    ),
  )
}

fn response(
  registry: server.Server,
  envelope: json.JsonValue,
) -> jsonrpc.Inbound {
  let assert #(_, Some(answer)) = server.handle_message(registry, envelope)
    as "response exists"
  let assert Ok(jsonrpc.Correlated(answer)) = jsonrpc.decode_value(answer)
    as "server response is valid"
  answer
}

pub fn typed_modern_round_trip_decodes_primitive_output_test() {
  assert client.call(
      endpoint(registry(fn(n) { Ok(n) })),
      definition(),
      7,
      options(),
    )
    == Ok(client.Complete(7))
}

pub fn custom_encoder_cannot_bypass_schema_before_transport_effect_test() {
  let touched = process.new_subject()
  let bad =
    codec.new(codec.schema(arguments()), fn(_) { json.Object([]) }, fn(_) {
      Ok(1)
    })
  let assert Ok(output) = codec.int() as "output codec compiles"
  let assert Ok(definition) = tool.new("number", "", bad, output)
    as "definition is valid"
  let endpoint =
    request.endpoint("effects", fn(_) {
      process.send(touched, Nil)
      Error(request.TransportFailed("should not execute"))
    })
  assert client.call(endpoint, definition, 3, options()) |> result.is_error
  assert process.receive(touched, 0) == Error(Nil)
}

pub fn custom_decoder_cannot_accept_schema_invalid_output_test() {
  let touched = process.new_subject()
  let assert Ok(compiled) =
    schema.new(json.Object([#("type", json.String("integer"))]))
    as "schema compiles"
  let custom =
    codec.new(compiled, json.Int, fn(_) {
      process.send(touched, Nil)
      Ok(3)
    })
  assert codec.decode(custom, json.String("wrong")) |> result.is_error
  assert process.receive(touched, 0) == Error(Nil)
}

pub fn request_bound_result_decoder_survives_explicit_continuation_test() {
  let observed = process.new_subject()
  let definition =
    definition()
    |> tool.with_result_decoder(fn(original, raw) {
      case raw {
        json.Int(value) if value == original -> Ok(value)
        _ -> Error("value differs from original arguments")
      }
    })
  let endpoint =
    request.endpoint("mrtr", fn(outbound) {
      process.send(observed, outbound.envelope)
      let assert Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(
        id,
        _,
        Some(json.Object(fields)),
      ))) = jsonrpc.decode_value(outbound.envelope)
        as "caller sends a request"
      let result = case list.key_find(fields, "requestState") {
        Error(Nil) -> mrtr.value(mrtr.load_shed("exact-state"))
        Ok(json.String("exact-state")) ->
          json.Object([
            #("resultType", json.String("complete")),
            #("content", json.Array([])),
            #("structuredContent", json.Int(9)),
          ])
        _ -> panic as "state changed"
      }
      Ok(jsonrpc.response(id, result))
    })
  let assert Ok(client.InputRequired(continuation)) =
    client.call(endpoint, definition, 7, options())
    as "first explicit request suspends"
  let assert Ok(responses) =
    mrtr.responses(client.continuation_required(continuation), [])
    as "state-only suspension has no response keys"
  assert client.resume(continuation, responses, options()) |> result.is_error
  let assert Ok(first) = process.receive(observed, 1000)
    as "first request is observed"
  let assert Ok(second) = process.receive(observed, 1000)
    as "one explicit resume is observed"
  let assert Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(
    _,
    _,
    Some(json.Object(first)),
  ))) = jsonrpc.decode_value(first)
    as "first envelope decodes"
  let assert Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(
    _,
    _,
    Some(json.Object(second)),
  ))) = jsonrpc.decode_value(second)
    as "second envelope decodes"
  assert list.key_find(first, "arguments") == list.key_find(second, "arguments")
  assert list.key_find(second, "requestState") == Ok(json.String("exact-state"))
  assert process.receive(observed, 0) == Error(Nil)
}

pub fn continuation_refuses_changed_revision_without_effect_test() {
  let registry = registry(fn(n) { Ok(n) })
  let calls = process.new_subject()
  let endpoint =
    request.endpoint("mrtr", fn(outbound) {
      process.send(calls, Nil)
      let assert Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(id, _, _))) =
        jsonrpc.decode_value(outbound.envelope)
        as "request decodes"
      Ok(jsonrpc.response(id, mrtr.value(mrtr.load_shed("token"))))
    })
  let assert Ok(client.InputRequired(continuation)) =
    client.call(endpoint, definition(), 7, options())
    as "call suspends"
  let assert Ok(responses) =
    mrtr.responses(client.continuation_required(continuation), [])
    as "responses bind exact empty keys"
  assert client.resume(
      continuation,
      responses,
      options() |> request.with_version(version.V20250618),
    )
    |> result.is_error
  let assert Ok(Nil) = process.receive(calls, 1000) as "first call executes"
  assert process.receive(calls, 0) == Error(Nil)
  assert server.is_modern(registry)
}

pub fn modern_invalid_arguments_are_tool_failure_before_handler_test() {
  let touched = process.new_subject()
  let registry =
    registry(fn(n) {
      process.send(touched, Nil)
      Ok(n)
    })
  let envelope =
    modern(1, "tools/call", [
      #("name", json.String("number")),
      #("arguments", json.Object([])),
    ])
  let assert jsonrpc.Response(_, Ok(value)) = response(registry, envelope)
    as "invalid arguments remain tool-level failures"
  let assert Ok(answer) = protocol.decode_call_tool_result(value)
    as "tool failure decodes"
  assert answer.is_error
  assert process.receive(touched, 0) == Error(Nil)
}

pub fn unknown_version_preserves_supported_version_error_data_test() {
  let envelope =
    jsonrpc.request(
      jsonrpc.IdInt(8),
      "server/discover",
      Some(
        json.Object([
          #(
            "_meta",
            json.Object([
              #(metadata.protocol_version_key, json.String("2099-01-01")),
              #(metadata.capabilities_key, json.Object([])),
            ]),
          ),
        ]),
      ),
    )
  let assert jsonrpc.Response(jsonrpc.IdInt(8), Error(error)) =
    response(registry(fn(n) { Ok(n) }), envelope)
    as "unsupported version is correlated"
  assert error.code == -32_022
  let assert Some(json.Object(data)) = error.data
    as "negotiation data remains intact"
  assert list.key_find(data, "requested") == Ok(json.String("2099-01-01"))
  assert list.key_find(data, "supported")
    == Ok(json.Array(list.map(version.supported(), json.String)))
}

pub fn uncorrelated_modern_error_omits_id_and_retains_data_test() {
  let error =
    jsonrpc.RpcError(
      -32_700,
      "parse",
      Some(json.Object([#("detail", json.Int(3))])),
    )
  let envelope = jsonrpc.error_response(None, error)
  let assert json.Object(fields) = envelope as "error is object"
  assert list.key_find(fields, "id") == Error(Nil)
  assert jsonrpc.decode_value(envelope) == Ok(jsonrpc.UncorrelatedError(error))
  let assert #(_, Some(parsed)) =
    server.handle_line(registry(fn(n) { Ok(n) }), "{")
    as "parse refusal exists"
  let assert json.Object(fields) = parsed as "parse refusal is object"
  assert list.key_find(fields, "id") == Error(Nil)
}

pub fn huge_cache_ttl_is_total_and_timer_options_are_bounded_test() {
  let assert Ok(json.Int(huge)) = json.parse("1" <> string_repeat(500))
    as "JSON preserves arbitrary precision integer"
  assert discovery.cache_hint(huge, discovery.Private) |> result.is_error
  assert discovery.decode_cache(
      json.Object([
        #("ttlMs", json.Int(huge)),
        #("cacheScope", json.String("private")),
      ]),
    )
    |> result.is_error
  assert request.timeout_ms(options() |> request.with_timeout(huge))
    == 4_294_966_295
  assert request.timeout_ms(options() |> request.with_timeout(-1)) == 1
}

fn string_repeat(count: Int) -> String {
  case count {
    0 -> ""
    _ -> "0" <> string_repeat(count - 1)
  }
}

pub fn legacy_primitive_outputs_project_to_text_and_typed_calls_refuse_test() {
  let assert Ok(binding) = server.bind(definition(), fn(n) { Ok(n) })
    as "binding is valid"
  let assert Ok(registry) = server.new("legacy", "1", [binding])
    as "registry is valid"
  let #(registry, _) =
    server.handle_message(
      registry,
      protocol.initialize_request(jsonrpc.IdInt(1), "1"),
    )
  let #(registry, _) = server.handle_message(registry, protocol.initialized())
  let assert jsonrpc.Response(_, Ok(json.Object(fields))) =
    response(registry, protocol.list_tools_request(jsonrpc.IdInt(2), None))
    as "legacy listing completes"
  let assert Ok(json.Array([json.Object(descriptor)])) =
    list.key_find(fields, "tools")
    as "one tool is listed"
  assert list.key_find(descriptor, "outputSchema") == Error(Nil)
  let assert jsonrpc.Response(_, Ok(answer)) =
    response(
      registry,
      protocol.call_tool_request(
        jsonrpc.IdInt(3),
        "number",
        json.Object([#("n", json.Int(7))]),
      ),
    )
    as "legacy call completes"
  let assert Ok(answer) = protocol.decode_call_tool_result(answer)
    as "legacy result decodes"
  assert answer.structured_content == None
  assert answer.content == [protocol.Text("7")]
  let touched = process.new_subject()
  let endpoint =
    request.endpoint("legacy", fn(_) {
      process.send(touched, Nil)
      Error(request.TransportFailed("unreachable"))
    })
  assert client.call(
      endpoint,
      definition(),
      7,
      options() |> request.with_version(version.V20250618),
    )
    |> result.is_error
  assert process.receive(touched, 0) == Error(Nil)
}

pub fn modern_catalog_excludes_only_invalid_http_binding_and_keeps_cache_test() {
  let assert json.Object(fields) = server.object_schema([], [])
    as "schema is object"
  let bad_schema =
    json.Object([#("x-mcp-header", json.String("Bad-Root")), ..fields])
  let assert Ok(good) =
    server.tool("good", "", server.object_schema([], []), fn(_) {
      Ok(server.text("ok"))
    })
    as "good tool registers"
  let assert Ok(bad) =
    server.tool("bad", "", bad_schema, fn(_) { Ok(server.text("ok")) })
    as "header annotation is transport-specific"
  let assert Ok(cache) = discovery.cache_hint(5000, discovery.Public)
    as "cache hint is valid"
  let assert Ok(registry) = server.new("catalog", "1", [good, bad])
    as "registry is unique"
  let registry = registry |> server.modern |> server.with_cache_hint(cache)
  let stdio = endpoint(registry)
  let http =
    request.endpoint_with_admission(
      "http",
      request.exchange(stdio, _),
      fn(compiled) {
        gleam_mcp_http_headers.compile(schema.value(compiled))
        |> result.map(fn(_) { Nil })
        |> result.map_error(request.InvalidArguments)
      },
    )
  let assert Ok(listed) = client.list_tools_at(http, options())
    as "HTTP catalog validates each descriptor"
  assert list.map(listed.tools, fn(descriptor) { descriptor.name }) == ["good"]
  assert listed.cache == cache
  let assert Ok(listed) = client.list_tools_at(stdio, options())
    as "stdio may ignore HTTP-only annotation"
  assert list.map(listed.tools, fn(descriptor) { descriptor.name })
    == ["good", "bad"]
}

pub fn missing_mrtr_capability_is_correlated_and_preserves_data_test() {
  let assert Ok(input) =
    mrtr.input_request("elicitation/create", json.Object([]))
    as "input method is recognized"
  let assert Ok(required) =
    mrtr.required(Some([#("confirm", input)]), Some("state"))
    as "required input binds unique key"
  let assert Ok(binding) =
    server.bind_round_trip(definition(), fn(_, _) {
      Ok(server.InputRequired(required))
    })
    as "typed handler binds"
  let assert Ok(registry) = server.new("mrtr", "1", [binding])
    as "registry compiles"
  let assert jsonrpc.Response(_, Error(error)) =
    response(
      server.modern(registry),
      modern(4, "tools/call", [
        #("name", json.String("number")),
        #("arguments", json.Object([#("n", json.Int(1))])),
      ]),
    )
    as "undeclared provider capability is refused"
  assert error.code == -32_021
  assert error.data
    == Some(
      json.Object([
        #("requiredCapabilities", json.Array([json.String("elicitation")])),
      ]),
    )
}

pub fn subscription_observers_require_ack_first_identity_and_subset_test() {
  let id = jsonrpc.IdInt(4)
  let stream = gleam_mcp_subscription.stream(id, gleam_mcp_subscription.tools())
  let change =
    jsonrpc.notification(
      "notifications/tools/list_changed",
      Some(
        json.Object([
          #(
            "_meta",
            json.Object([
              #("io.modelcontextprotocol/subscriptionId", json.Int(4)),
            ]),
          ),
        ]),
      ),
    )
  assert gleam_mcp_subscription.accept(stream, change) |> result.is_error
  let assert Ok(stream) =
    gleam_mcp_subscription.accept(
      stream,
      gleam_mcp_subscription.acknowledge(id, gleam_mcp_subscription.tools()),
    )
    as "requested acknowledgement admits stream"
  assert gleam_mcp_subscription.accept(stream, change) |> result.is_ok
  assert gleam_mcp_subscription.accept(
      stream,
      gleam_mcp_subscription.acknowledge(
        jsonrpc.IdInt(5),
        gleam_mcp_subscription.tools(),
      ),
    )
    |> result.is_error
  assert gleam_mcp_subscription.acknowledged(
      json.Object([#("resourcesListChanged", json.Bool(True))]),
    )
    |> result.is_error
  assert gleam_mcp_subscription.acknowledged(
      json.Object([
        #("resourceSubscriptions", json.Array([json.String("file:///x")])),
      ]),
    )
    |> result.is_error
  assert gleam_mcp_subscription.complete(
      stream,
      json.Object([
        #(
          "_meta",
          json.Object([#("io.modelcontextprotocol/subscriptionId", json.Int(5))]),
        ),
      ]),
    )
    |> result.is_error
}

pub fn subscription_graceful_completion_requires_complete_result_type_test() {
  let id = jsonrpc.IdString("stream")
  let stream = gleam_mcp_subscription.stream(id, gleam_mcp_subscription.empty())
  let assert Ok(stream) =
    gleam_mcp_subscription.accept(
      stream,
      gleam_mcp_subscription.acknowledge(id, gleam_mcp_subscription.empty()),
    )
    as "empty subset is acknowledged"
  let meta =
    json.Object([
      #("io.modelcontextprotocol/subscriptionId", json.String("stream")),
    ])
  assert gleam_mcp_subscription.complete(
      stream,
      json.Object([#("_meta", meta)]),
    )
    |> result.is_error
  assert gleam_mcp_subscription.complete(
      stream,
      json.Object([
        #("_meta", meta),
        #("resultType", json.String("input_required")),
      ]),
    )
    |> result.is_error
  assert gleam_mcp_subscription.complete(
      stream,
      json.Object([#("_meta", meta), #("resultType", json.String("future"))]),
    )
    |> result.is_error
  assert gleam_mcp_subscription.complete(
      stream,
      json.Object([#("_meta", meta), #("resultType", json.String("complete"))]),
    )
    == Ok(Nil)
}

pub fn modern_call_envelope_refuses_nonobject_arguments_before_effects_test() {
  let touched = process.new_subject()
  let assert Ok(binding) =
    server.tool("object", "", server.object_schema([], []), fn(arguments) {
      process.send(touched, arguments)
      Ok(server.structured(arguments))
    })
    as "object tool registers"
  let assert Ok(registry) = server.new("shape", "1", [binding])
    as "registry registers"
  let registry = server.modern(registry)
  list.each(
    [json.Null, json.Array([]), json.String("x"), json.Int(1), json.Bool(True)],
    fn(arguments) {
      let assert jsonrpc.Response(_, Error(error)) =
        response(
          registry,
          modern(1, "tools/call", [
            #("name", json.String("object")),
            #("arguments", arguments),
          ]),
        )
        as "malformed argument envelope is a protocol refusal"
      assert error.code == -32_602
    },
  )
  assert process.receive(touched, 0) == Error(Nil)
  let assert jsonrpc.Response(_, Ok(_)) =
    response(
      registry,
      modern(2, "tools/call", [#("name", json.String("object"))]),
    )
    as "absent arguments default to the valid empty object"
  assert process.receive(touched, 1000) == Ok(json.Object([]))
}
