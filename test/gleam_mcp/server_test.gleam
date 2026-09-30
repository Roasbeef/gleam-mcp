import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam_mcp/json
import gleam_mcp/jsonrpc
import gleam_mcp/protocol
import gleam_mcp/server

fn fixture() -> server.Server {
  let assert Ok(echo_tool) =
    server.tool(
      "echo",
      "Echoes a decoded argument.",
      server.object_schema(
        [#("message", json.Object([#("type", json.String("string"))]))],
        ["message"],
      ),
      fn(arguments) {
        use message <- result.try(server.string_argument(arguments, "message"))
        Ok(server.structured(json.Object([#("message", json.String(message))])))
      },
    )
    as "echo tool definition is valid"
  let assert Ok(failed) =
    server.tool(
      "failed",
      "Fails after execution.",
      server.object_schema([], []),
      fn(_) { Error(server.ExecutionFailed("upstream failed")) },
    )
    as "failure tool definition is valid"
  let assert Ok(server) = server.new("fixture", "1.0.0", [echo_tool, failed])
    as "server definition is valid"
  server
}

fn ready() -> server.Server {
  let assert #(server, Some(_)) =
    server.handle_line(
      fixture(),
      json.to_string(protocol.initialize_request(jsonrpc.IdInt(1), "1.0.0")),
    )
    as "lifecycle exchange has the expected response"
  let assert #(server, None) =
    server.handle_line(server, json.to_string(protocol.initialized()))
    as "lifecycle exchange has the expected response"
  server
}

fn response(server: server.Server, request: json.JsonValue) -> json.JsonValue {
  let #(_, answer) = server.handle_line(server, json.to_string(request))
  let assert Some(answer) = answer as "request receives a response"
  answer
}

fn field(value: json.JsonValue, key: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "response is an object"
  let assert Ok(found) = list.key_find(fields, key)
    as "expected response field exists"
  found
}

fn error_code(value: json.JsonValue) -> json.JsonValue {
  field(field(value, "error"), "code")
}

pub fn tool_registration_rejects_duplicates_and_non_object_schemas_test() {
  let handler = fn(_) { Ok(server.text("ok")) }
  assert server.tool("", "", server.object_schema([], []), handler)
    == Error(server.EmptyName)
  assert server.tool("bad", "", json.Object([]), handler)
    == Error(server.InvalidSchema)
  let assert Ok(tool) =
    server.tool("same", "", server.object_schema([], []), handler)
    as "definition is valid"
  assert server.new("fixture", "1", [tool, tool])
    == Error(server.DuplicateTool("same"))
  assert server.with_output_schema(tool, json.String("object"))
    == Error(server.InvalidSchema)
}

pub fn initialize_roundtrip_and_empty_client_capabilities_test() {
  let #(server, answer) =
    server.handle_line(
      fixture(),
      json.to_string(protocol.initialize_request_with_name(
        jsonrpc.IdString("init"),
        "caller",
        "2",
      )),
    )
  let assert Some(answer) = answer as "initialize responds"
  assert field(answer, "id") == json.String("init")
  let assert Ok(initialized) =
    protocol.decode_initialize_result(field(answer, "result"))
    as "server result decodes in production client"
  assert initialized.protocol_version == protocol.requested_version
  assert initialized.server_name == Some("fixture")
  assert initialized.tools == Some(protocol.ToolsCapability(False))

  let before =
    response(server, protocol.list_tools_request(jsonrpc.IdInt(2), None))
  assert error_code(before) == json.Int(-32_002)
  let #(server, notification) =
    server.handle_line(server, json.to_string(protocol.initialized()))
  assert notification == None
  let listing =
    response(server, protocol.list_tools_request(jsonrpc.IdInt(3), None))
  let assert Ok(page) = protocol.decode_tools_page(field(listing, "result"))
    as "listing decodes"
  assert list.map(page.tools, fn(tool) { tool.name }) == ["echo", "failed"]
  assert page.next_cursor == None
}

pub fn tool_call_preserves_structured_content_and_text_test() {
  let answer =
    response(
      ready(),
      protocol.call_tool_request(
        jsonrpc.IdString("call"),
        "echo",
        json.Object([#("message", json.String("hi"))]),
      ),
    )
  assert field(answer, "id") == json.String("call")
  let assert Ok(result) =
    protocol.decode_call_tool_result(field(answer, "result"))
    as "result decodes"
  assert result
    == server.structured(json.Object([#("message", json.String("hi"))]))
}

pub fn argument_fault_is_rpc_error_and_execution_fault_is_tool_verdict_test() {
  let missing =
    response(
      ready(),
      protocol.call_tool_request(jsonrpc.IdInt(9), "echo", json.Object([])),
    )
  assert field(missing, "id") == json.Int(9)
  assert error_code(missing) == json.Int(-32_602)

  let failed =
    response(
      ready(),
      protocol.call_tool_request(jsonrpc.IdInt(10), "failed", json.Object([])),
    )
  let assert Ok(verdict) =
    protocol.decode_call_tool_result(field(failed, "result"))
    as "tool failure is a valid result"
  assert verdict.is_error
  assert verdict.content == [protocol.Text("upstream failed")]
}

pub fn malformed_input_and_invalid_envelopes_use_null_ids_test() {
  let assert #(_, Some(parse_error)) = server.handle_line(fixture(), "{")
    as "lifecycle exchange has the expected response"
  assert field(parse_error, "id") == json.Null
  assert error_code(parse_error) == json.Int(-32_700)
  let assert #(_, Some(invalid_request)) =
    server.handle_line(fixture(), "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":4}")
    as "lifecycle exchange has the expected response"
  assert field(invalid_request, "id") == json.Null
  assert error_code(invalid_request) == json.Int(-32_600)
}

pub fn unsupported_method_unknown_tool_bad_arguments_and_cursor_are_correlated_test() {
  let server = ready()
  let unknown_method =
    response(server, jsonrpc.request(jsonrpc.IdInt(2), "other", None))
  assert error_code(unknown_method) == json.Int(-32_601)
  let unknown_tool =
    response(
      server,
      protocol.call_tool_request(jsonrpc.IdInt(3), "absent", json.Object([])),
    )
  assert error_code(unknown_tool) == json.Int(-32_602)
  let malformed_arguments =
    response(
      server,
      protocol.call_tool_request(jsonrpc.IdInt(4), "echo", json.Array([])),
    )
  assert error_code(malformed_arguments) == json.Int(-32_602)
  let cursor =
    response(
      server,
      protocol.list_tools_request(jsonrpc.IdInt(5), Some("missing")),
    )
  assert error_code(cursor) == json.Int(-32_602)
  assert field(cursor, "id") == json.Int(5)
}

pub fn invalid_initialize_does_not_advance_lifecycle_test() {
  let #(server, answer) =
    server.handle_line(
      fixture(),
      json.to_string(jsonrpc.request(
        jsonrpc.IdInt(1),
        "initialize",
        Some(json.Object([])),
      )),
    )

  let assert Some(answer) = answer as "invalid initialize responds"
  assert error_code(answer) == json.Int(-32_602)
  let #(_, answer) =
    server.handle_line(
      server,
      json.to_string(protocol.initialize_request(jsonrpc.IdInt(2), "1")),
    )
  let assert Some(answer) = answer as "subsequent valid initialize responds"
  let assert Ok(_) = protocol.decode_initialize_result(field(answer, "result"))
    as "failed initialization left the server uninitialized"
}

pub fn repeated_initialize_and_early_notification_cannot_bypass_lifecycle_test() {
  let assert #(server, None) =
    server.handle_line(fixture(), json.to_string(protocol.initialized()))
    as "lifecycle exchange has the expected response"
  assert error_code(response(
      server,
      protocol.list_tools_request(jsonrpc.IdInt(1), None),
    ))
    == json.Int(-32_002)
  assert error_code(response(
      ready(),
      protocol.initialize_request(jsonrpc.IdInt(2), "1"),
    ))
    == json.Int(-32_600)
}

pub fn all_supported_versions_negotiate_and_unknown_version_proposes_default_test() {
  list.each(protocol.supported_versions(), fn(version) {
    let request = initialize_with_version(version)
    let answer = response(fixture(), request)
    assert field(field(answer, "result"), "protocolVersion")
      == json.String(version)
  })
  let answer = response(fixture(), initialize_with_version("9999-01-01"))
  assert field(field(answer, "result"), "protocolVersion")
    == json.String(protocol.requested_version)
}

fn initialize_with_version(version: String) -> json.JsonValue {
  jsonrpc.request(
    jsonrpc.IdInt(1),
    "initialize",
    Some(
      json.Object([
        #("protocolVersion", json.String(version)),
        #("capabilities", json.Object([])),
        #(
          "clientInfo",
          json.Object([
            #("name", json.String("caller")),
            #("version", json.String("1")),
          ]),
        ),
      ]),
    ),
  )
}

pub fn raw_non_text_result_payload_survives_client_server_roundtrip_test() {
  let raw =
    json.Object([
      #("type", json.String("image")),
      #("data", json.String("...")),
      #("mimeType", json.String("image/png")),
      #("future", json.Int(2)),
    ])
  let value =
    protocol.CallToolResult(
      content: [protocol.Other("image", raw)],
      is_error: False,
      structured_content: None,
    )
  let assert Ok(tool) =
    server.tool("image", "", server.object_schema([], []), fn(_) { Ok(value) })
    as "definition is valid"
  let assert Ok(server) = server.new("fixture", "1", [tool])
    as "server is valid"
  let #(server, _) =
    server.handle_line(
      server,
      json.to_string(protocol.initialize_request(jsonrpc.IdInt(1), "1")),
    )
  let #(server, _) =
    server.handle_line(server, json.to_string(protocol.initialized()))
  let answer =
    response(
      server,
      protocol.call_tool_request(jsonrpc.IdInt(2), "image", json.Object([])),
    )
  assert protocol.decode_call_tool_result(field(answer, "result")) == Ok(value)
}

pub fn malformed_initialized_notification_does_not_advance_lifecycle_test() {
  let #(server, _) =
    server.handle_line(
      fixture(),
      json.to_string(protocol.initialize_request(jsonrpc.IdInt(1), "1")),
    )
  let #(server, answer) =
    server.handle_line(
      server,
      json.to_string(jsonrpc.notification(
        "notifications/initialized",
        Some(json.String("invalid")),
      )),
    )
  assert answer == None
  assert error_code(response(
      server,
      protocol.list_tools_request(jsonrpc.IdInt(2), None),
    ))
    == json.Int(-32_002)
  let #(server, _) =
    server.handle_line(server, json.to_string(protocol.initialized()))
  let answer =
    response(server, protocol.list_tools_request(jsonrpc.IdInt(3), None))
  let assert Ok(_) = protocol.decode_tools_page(field(answer, "result"))
    as "valid notification unlocks tool admission"
}
