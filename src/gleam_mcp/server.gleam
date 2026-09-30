//// A tools-only MCP server with caller-owned handlers and an explicit lifecycle.
////
//// Registration makes duplicate tool names unreachable. The server owns envelope
//// decoding and initialize ordering; each handler owns its argument decoder and
//// effects. `handle_line` is the deterministic seam when handlers are pure, while
//// `server_stdio.run` connects the same transitions to bounded native input.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc
import gleam_mcp/protocol

/// A handler's refusal, kept distinct from a tool that ran and failed.
pub type ToolError {
  /// Arguments failed the tool's total decoder before execution.
  InvalidArguments(reason: String)

  /// Execution failed and the client should receive a tool-level verdict.
  ExecutionFailed(reason: String)
}

/// Why a server or tool definition could not be registered.
pub type ConfigurationError {
  /// An identity or tool name was empty.
  EmptyName

  /// Two registered tools had the same wire name.
  DuplicateTool(name: String)

  /// A schema did not declare an object at its top level.
  InvalidSchema
}

/// A validated tool descriptor and its caller-owned handler.
pub opaque type Tool {
  Tool(
    /// The descriptor admitted before the server starts.
    descriptor: protocol.ToolDescriptor,
    /// The caller-owned argument decoder and effect boundary.
    handler: fn(JsonValue) -> Result(protocol.CallToolResult, ToolError),
  )
}

type Phase {
  AwaitingInitialize
  AwaitingInitialized
  Ready
}

/// A server whose registered tool names are unique.
pub opaque type Server {
  Server(
    /// The identity advertised by initialize.
    name: String,
    /// The caller-owned server version.
    version: String,
    /// Registered tools whose names are unique.
    tools: List(Tool),
    /// The only lifecycle transition that admits tools/call.
    phase: Phase,
  )
}

/// Registers one tool with an object input schema.
///
/// Schema conformance beyond the top-level object is the handler's job. A
/// handler should decode every argument before starting its effects.
///
/// ## Examples
///
/// ```gleam
/// // server.tool("echo", "Echoes arguments.", server.object_schema([], []),
/// //   fn(arguments) { Ok(server.structured(arguments)) })
/// ```
pub fn tool(
  name: String,
  description: String,
  input_schema: JsonValue,
  handler: fn(JsonValue) -> Result(protocol.CallToolResult, ToolError),
) -> Result(Tool, ConfigurationError) {
  use Nil <- result.try(nonempty(name))
  use Nil <- result.try(object_schema_valid(input_schema))
  Ok(Tool(
    descriptor: protocol.ToolDescriptor(
      name:,
      title: None,
      description: Some(description),
      input_schema:,
      output_schema: None,
    ),
    handler:,
  ))
}

/// Adds an object output schema to a registered tool.
///
/// ## Examples
///
/// ```gleam
/// // server.with_output_schema(tool, server.object_schema([], []))
/// ```
pub fn with_output_schema(
  tool: Tool,
  schema: JsonValue,
) -> Result(Tool, ConfigurationError) {
  use Nil <- result.try(object_schema_valid(schema))
  Ok(
    Tool(
      ..tool,
      descriptor: protocol.ToolDescriptor(
        ..tool.descriptor,
        output_schema: Some(schema),
      ),
    ),
  )
}

/// Constructs a server before any input or handler can run.
///
/// ## Examples
///
/// ```gleam
/// // server.new("jev", "0.1.0", tools)
/// ```
pub fn new(
  name: String,
  version: String,
  tools: List(Tool),
) -> Result(Server, ConfigurationError) {
  use Nil <- result.try(nonempty(name))
  use Nil <- result.try(nonempty(version))
  use Nil <- result.try(unique_tools(tools, []))
  Ok(Server(name:, version:, tools:, phase: AwaitingInitialize))
}

fn nonempty(value: String) -> Result(Nil, ConfigurationError) {
  case value {
    "" -> Error(EmptyName)
    _ -> Ok(Nil)
  }
}

fn object_schema_valid(schema: JsonValue) -> Result(Nil, ConfigurationError) {
  case schema {
    json.Object(fields) ->
      case list.key_find(fields, "type") {
        Ok(json.String("object")) -> Ok(Nil)
        _ -> Error(InvalidSchema)
      }
    _ -> Error(InvalidSchema)
  }
}

fn unique_tools(
  tools: List(Tool),
  seen: List(String),
) -> Result(Nil, ConfigurationError) {
  case tools {
    [] -> Ok(Nil)
    [tool, ..rest] ->
      case list.contains(seen, tool.descriptor.name) {
        True -> Error(DuplicateTool(tool.descriptor.name))
        False -> unique_tools(rest, [tool.descriptor.name, ..seen])
      }
  }
}

/// Builds the common JSON Schema object envelope without interpreting fields.
///
/// ## Examples
///
/// ```gleam
/// // server.object_schema([#("query", json.Object([#("type", json.String("string"))]))], ["query"])
/// ```
pub fn object_schema(
  properties: List(#(String, JsonValue)),
  required: List(String),
) -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #("properties", json.Object(properties)),
    #("required", json.Array(list.map(required, json.String))),
  ])
}

/// Reads one required string argument without coercion or side effects.
///
/// ## Examples
///
/// ```gleam
/// assert server.string_argument(json.Object([#("name", json.String("Ada"))]), "name") == Ok("Ada")
/// ```
pub fn string_argument(
  arguments: JsonValue,
  name: String,
) -> Result(String, ToolError) {
  use value <- result.try(argument(arguments, name))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error(InvalidArguments(name <> " must be a string"))
  }
}

/// Reads one required argument from the object admitted by tools/call.
///
/// ## Examples
///
/// ```gleam
/// assert server.argument(json.Object([#("n", json.Int(1))]), "n") == Ok(json.Int(1))
/// ```
pub fn argument(
  arguments: JsonValue,
  name: String,
) -> Result(JsonValue, ToolError) {
  case arguments {
    json.Object(fields) ->
      list.key_find(fields, name)
      |> result.map_error(fn(_) {
        InvalidArguments("missing argument " <> name)
      })
    _ -> Error(InvalidArguments("arguments must be an object"))
  }
}

/// Returns structured content and the same JSON as a text block.
///
/// ## Examples
///
/// ```gleam
/// // server.structured(json.Object([#("answer", json.Bool(True))]))
/// ```
pub fn structured(value: JsonValue) -> protocol.CallToolResult {
  protocol.CallToolResult(
    content: [protocol.Text(json.to_string(value))],
    is_error: False,
    structured_content: Some(value),
  )
}

/// Returns a successful text result.
///
/// ## Examples
///
/// ```gleam
/// // server.text("Done.")
/// ```
pub fn text(message: String) -> protocol.CallToolResult {
  protocol.CallToolResult(
    content: [protocol.Text(message)],
    is_error: False,
    structured_content: None,
  )
}

/// Returns a tool-level failure without changing the JSON-RPC correlation.
///
/// ## Examples
///
/// ```gleam
/// // server.failure("The upstream service is unavailable.")
/// ```
pub fn failure(message: String) -> protocol.CallToolResult {
  protocol.CallToolResult(..text(message), is_error: True)
}

/// Processes one complete JSON-RPC line and returns the next lifecycle state.
///
/// Notifications and client responses produce no response. Parse errors and
/// invalid envelopes use a null id; valid requests retain their exact id type.
///
/// ## Examples
///
/// ```gleam
/// // let #(server, response) = server.handle_line(server, request_line)
/// ```
pub fn handle_line(
  server: Server,
  line: String,
) -> #(Server, Option(JsonValue)) {
  case jsonrpc.decode(line) {
    Error(jsonrpc.MalformedMessage(_)) -> #(
      server,
      Some(error_response(None, -32_700, "parse error")),
    )
    Error(jsonrpc.BadMessage(_)) -> #(
      server,
      Some(error_response(None, -32_600, "invalid request")),
    )
    Ok(jsonrpc.Notification("notifications/initialized", params)) -> {
      // Invalid notification parameters cannot advance the lifecycle, and a
      // notification never receives an error response.
      let phase = case params, server.phase {
        None, AwaitingInitialized | Some(json.Object(_)), AwaitingInitialized ->
          Ready
        _, phase -> phase
      }
      #(Server(..server, phase:), None)
    }
    Ok(jsonrpc.Notification(_, _)) | Ok(jsonrpc.Response(_, _)) -> #(
      server,
      None,
    )
    Ok(jsonrpc.ServerRequest(id, method, params)) ->
      handle_request(server, id, method, params)
  }
}

fn handle_request(
  server: Server,
  id: jsonrpc.Id,
  method: String,
  params: Option(JsonValue),
) -> #(Server, Option(JsonValue)) {
  case method, server.phase {
    "ping", _ -> #(server, Some(success_response(id, json.Object([]))))
    "initialize", AwaitingInitialize -> initialize(server, id, params)
    "initialize", AwaitingInitialized | "initialize", Ready -> #(
      server,
      Some(error_response(Some(id), -32_600, "already initialized")),
    )
    _, AwaitingInitialize | _, AwaitingInitialized -> #(
      server,
      Some(error_response(Some(id), -32_002, "server is not initialized")),
    )
    "tools/list", Ready -> #(server, Some(list_tools(server, id, params)))
    "tools/call", Ready -> #(server, Some(call_tool(server, id, params)))
    _, Ready -> #(
      server,
      Some(error_response(Some(id), -32_601, "method not found")),
    )
  }
}

fn initialize(
  server: Server,
  id: jsonrpc.Id,
  params: Option(JsonValue),
) -> #(Server, Option(JsonValue)) {
  case initialize_version(params) {
    Error(reason) -> #(server, Some(error_response(Some(id), -32_602, reason)))
    Ok(version) -> {
      let value =
        json.Object([
          #("protocolVersion", json.String(version)),
          #("capabilities", json.Object([#("tools", json.Object([]))])),
          #(
            "serverInfo",
            json.Object([
              #("name", json.String(server.name)),
              #("version", json.String(server.version)),
            ]),
          ),
        ])
      #(
        Server(..server, phase: AwaitingInitialized),
        Some(success_response(id, value)),
      )
    }
  }
}

fn initialize_version(params: Option(JsonValue)) -> Result(String, String) {
  use fields <- result.try(params_fields(params))
  use version <- result.try(string_field(fields, "protocolVersion"))
  use _ <- result.try(object_field(fields, "capabilities"))
  use client <- result.try(object_field(fields, "clientInfo"))
  use _ <- result.try(string_field(client, "name"))
  use _ <- result.try(string_field(client, "version"))
  case list.contains(protocol.supported_versions(), version) {
    True -> Ok(version)
    False -> Ok(protocol.requested_version)
  }
}

fn list_tools(
  server: Server,
  id: jsonrpc.Id,
  params: Option(JsonValue),
) -> JsonValue {
  case list_params(params) {
    Error(reason) -> error_response(Some(id), -32_602, reason)
    Ok(Nil) ->
      success_response(
        id,
        json.Object([
          #("tools", json.Array(list.map(server.tools, descriptor_json))),
        ]),
      )
  }
}

fn list_params(params: Option(JsonValue)) -> Result(Nil, String) {
  case params {
    None -> Ok(Nil)
    Some(json.Object(fields)) ->
      case list.key_find(fields, "cursor") {
        Error(Nil) -> Ok(Nil)
        Ok(_) -> Error("this server has no continuation cursor")
      }
    Some(_) -> Error("params must be an object")
  }
}

fn descriptor_json(tool: Tool) -> JsonValue {
  let descriptor = tool.descriptor
  let fields = [
    #("name", json.String(descriptor.name)),
    #("inputSchema", descriptor.input_schema),
  ]
  let fields = case descriptor.description {
    None -> fields
    Some(description) ->
      list.append(fields, [#("description", json.String(description))])
  }
  let fields = case descriptor.output_schema {
    None -> fields
    Some(schema) -> list.append(fields, [#("outputSchema", schema)])
  }
  json.Object(fields)
}

fn call_tool(
  server: Server,
  id: jsonrpc.Id,
  params: Option(JsonValue),
) -> JsonValue {
  use #(name, arguments) <- or_rpc_error(tool_arguments(params), id)
  use tool <- or_rpc_error(
    list.find(server.tools, fn(tool) { tool.descriptor.name == name })
      |> result.map_error(fn(_) { "unknown tool " <> name }),
    id,
  )

  // A decoder refusal is a protocol error; an admitted tool's failure remains
  // an ordinary tools/call result that preserves request correlation.
  case tool.handler(arguments) {
    Error(InvalidArguments(reason)) -> error_response(Some(id), -32_602, reason)
    Error(ExecutionFailed(reason)) ->
      success_response(id, result_json(failure(reason)))
    Ok(answer) -> success_response(id, result_json(answer))
  }
}

fn or_rpc_error(
  value: Result(a, String),
  id: jsonrpc.Id,
  next: fn(a) -> JsonValue,
) -> JsonValue {
  case value {
    Ok(value) -> next(value)
    Error(reason) -> error_response(Some(id), -32_602, reason)
  }
}

fn tool_arguments(
  params: Option(JsonValue),
) -> Result(#(String, JsonValue), String) {
  use fields <- result.try(params_fields(params))
  use name <- result.try(string_field(fields, "name"))
  let arguments = case list.key_find(fields, "arguments") {
    Error(Nil) -> Ok(json.Object([]))
    Ok(json.Object(_) as value) -> Ok(value)
    Ok(_) -> Error("arguments must be an object")
  }
  use arguments <- result.try(arguments)
  Ok(#(name, arguments))
}

fn params_fields(
  params: Option(JsonValue),
) -> Result(List(#(String, JsonValue)), String) {
  case params {
    Some(json.Object(fields)) -> Ok(fields)
    None | Some(_) -> Error("params must be an object")
  }
}

fn string_field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error(name <> " must be a string")
  }
}

fn object_field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(List(#(String, JsonValue)), String) {
  case list.key_find(fields, name) {
    Ok(json.Object(fields)) -> Ok(fields)
    _ -> Error(name <> " must be an object")
  }
}

fn result_json(answer: protocol.CallToolResult) -> JsonValue {
  let fields = [
    #(
      "content",
      json.Array(
        list.map(answer.content, fn(block) {
          case block {
            protocol.Text(text) ->
              json.Object([
                #("type", json.String("text")),
                #("text", json.String(text)),
              ])
            protocol.Other(_, raw) -> raw
          }
        }),
      ),
    ),
    #("isError", json.Bool(answer.is_error)),
  ]
  case answer.structured_content {
    None -> json.Object(fields)
    Some(value) ->
      json.Object(list.append(fields, [#("structuredContent", value)]))
  }
}

fn id_json(id: jsonrpc.Id) -> JsonValue {
  case id {
    jsonrpc.IdInt(value) -> json.Int(value)
    jsonrpc.IdString(value) -> json.String(value)
  }
}

fn success_response(id: jsonrpc.Id, value: JsonValue) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String(jsonrpc.version)),
    #("id", id_json(id)),
    #("result", value),
  ])
}

fn error_response(
  id: Option(jsonrpc.Id),
  code: Int,
  message: String,
) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String(jsonrpc.version)),
    #("id", option.map(id, id_json) |> option.unwrap(json.Null)),
    #(
      "error",
      json.Object([
        #("code", json.Int(code)),
        #("message", json.String(message)),
      ]),
    ),
  ])
}
