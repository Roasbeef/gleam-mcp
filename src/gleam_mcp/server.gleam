//// A tools-only MCP server with caller-owned handlers and an explicit lifecycle.
////
//// Registration makes duplicate tool names unreachable. The server owns envelope
//// decoding and initialize ordering; each handler owns its argument decoder and
//// effects. `handle_line` is the deterministic seam when handlers are pure, while
//// `server_stdio.run` connects the same transitions to bounded native input.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/codec
import gleam_mcp/discovery
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc
import gleam_mcp/metadata
import gleam_mcp/mrtr
import gleam_mcp/protocol
import gleam_mcp/schema
import gleam_mcp/subscription
import gleam_mcp/tool as definition
import gleam_mcp/version as revision

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
    /// The compiled input contract, present on typed definitions.
    compiled_input: Option(schema.Schema),
    /// The handler for explicit multi round-trip requests.
    round_trip: fn(JsonValue, mrtr.Context) -> Result(RawStep, ToolError),
  )
}

/// A typed handler either completes or explicitly asks the caller for input.
pub type ToolStep(output) {
  /// Validated output completes this request.
  Complete(output: output)

  /// Opaque request state and input requests suspend this request.
  InputRequired(required: mrtr.Required)
}

type RawStep {
  Finished(protocol.CallToolResult)
  Suspended(mrtr.Required)
}

type Phase {
  AwaitingInitialize
  AwaitingInitialized
  Ready
  RequestsOnly
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
    /// Subscriptions acknowledged on this stdio channel.
    subscriptions: List(jsonrpc.Id),
    /// Cache hints scoped to this registry's authorization context.
    cache: discovery.CacheHint,
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
  Ok(
    Tool(
      descriptor: protocol.ToolDescriptor(
        name:,
        title: None,
        description: Some(description),
        input_schema:,
        output_schema: None,
      ),
      handler:,
      compiled_input: None,
      round_trip: fn(arguments, _) {
        handler(arguments) |> result.map(Finished)
      },
    ),
  )
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
  Ok(Server(
    name:,
    version:,
    tools:,
    phase: AwaitingInitialize,
    subscriptions: [],
    cache: discovery.stale(),
  ))
}

/// Identifies a registry serving request-scoped metadata without initialization.
///
/// ## Examples
///
/// ```gleam
/// // server.is_modern(server.modern(registry)) returns True.
/// ```
pub fn is_modern(server: Server) -> Bool {
  server.phase == RequestsOnly
}

/// Returns active subscription identifiers for graceful transport retirement.
///
/// ## Examples
///
/// ```gleam
/// // server.subscriptions(registry) is empty before any listen request.
/// ```
pub fn subscriptions(server: Server) -> List(jsonrpc.Id) {
  server.subscriptions
}

/// Binds a typed definition to its argument and output handler.
///
/// Both directions remain schema-checked, including custom callbacks and the
/// output decoder bound to the exact original arguments.
///
/// ## Examples
///
/// ```gleam
/// // server.bind(definition, fn(args) { Ok(args.text) })
/// ```
pub fn bind(
  definition: definition.Tool(args, output),
  handler: fn(args) -> Result(output, ToolError),
) -> Result(Tool, ConfigurationError) {
  bind_round_trip(definition, fn(args, _) {
    handler(args) |> result.map(Complete)
  })
}

/// Binds a typed handler that supports explicit MRTR continuation.
///
/// ## Examples
///
/// ```gleam
/// // server.bind_round_trip(definition, fn(args, context) { continue(args, context) })
/// ```
pub fn bind_round_trip(
  definition: definition.Tool(args, output),
  handler: fn(args, mrtr.Context) -> Result(ToolStep(output), ToolError),
) -> Result(Tool, ConfigurationError) {
  let round_trip = fn(raw, context) {
    use args <- result.try(
      definition.decode_arguments(definition, raw)
      |> result.map_error(InvalidArguments),
    )
    use step <- result.try(handler(args, context))
    case step {
      InputRequired(required) -> Ok(Suspended(required))
      Complete(output) -> {
        use value <- result.try(
          definition.encode_output(definition, output)
          |> result.map_error(ExecutionFailed),
        )
        use _ <- result.try(
          codec.decode(definition.result_codec(definition, args), value)
          |> result.map_error(ExecutionFailed),
        )
        Ok(Finished(structured(value)))
      }
    }
  }
  Ok(Tool(
    descriptor: protocol.ToolDescriptor(
      name: definition.name(definition),
      title: None,
      description: Some(definition.description(definition)),
      input_schema: schema.value(definition.input_schema(definition)),
      output_schema: Some(schema.value(definition.output_schema(definition))),
    ),
    handler: fn(raw) {
      use step <- result.try(round_trip(raw, mrtr.Context(None, None)))
      case step {
        Finished(value) -> Ok(value)
        Suspended(_) ->
          Error(ExecutionFailed("this request requires modern MRTR support"))
      }
    },
    compiled_input: Some(definition.input_schema(definition)),
    round_trip:,
  ))
}

/// Selects request-oriented dispatch with no initialize or ping methods.
///
/// ## Examples
///
/// ```gleam
/// // server.modern(server) is the default HTTP server boundary.
/// ```
pub fn modern(server: Server) -> Server {
  Server(..server, phase: RequestsOnly)
}

/// Sets explicit cache freshness and authorization scope for metadata results.
///
/// ## Examples
///
/// ```gleam
/// // server.with_cache_hint(server, hint)
/// ```
pub fn with_cache_hint(server: Server, hint: discovery.CacheHint) -> Server {
  Server(..server, cache: hint)
}

/// Returns the registered compiled input schema for transport admission.
///
/// ## Examples
///
/// ```gleam
/// // server.tool_input_schema(server, "echo") precedes HTTP header validation.
/// ```
pub fn tool_input_schema(
  server: Server,
  name: String,
) -> Option(schema.Schema) {
  let selected =
    list.find(server.tools, fn(tool) { tool.descriptor.name == name })
  case selected {
    Error(Nil) -> None
    Ok(tool) ->
      case tool.compiled_input {
        Some(value) -> Some(value)
        None -> schema.new(tool.descriptor.input_schema) |> option.from_result
      }
  }
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
  case json.parse(line) {
    Ok(value) -> handle_message(server, value)
    Error(_) -> #(
      server,
      Some(case server.phase {
        RequestsOnly -> rpc_error(None, -32_700, "parse error", None)
        AwaitingInitialize | AwaitingInitialized | Ready ->
          error_response(None, -32_700, "parse error")
      }),
    )
  }
}

/// Dispatches a parsed message using its own metadata or the legacy lifecycle.
///
/// ## Examples
///
/// ```gleam
/// // server.handle_message(server, envelope) requires no initialize for modern requests.
/// ```
pub fn handle_message(
  server: Server,
  value: JsonValue,
) -> #(Server, Option(JsonValue)) {
  case jsonrpc.decode_value(value) {
    Error(_) -> #(
      server,
      Some(case server.phase {
        RequestsOnly -> rpc_error(None, -32_600, "invalid request", None)
        AwaitingInitialize | AwaitingInitialized | Ready ->
          error_response(None, -32_600, "invalid request")
      }),
    )
    Ok(jsonrpc.UncorrelatedError(_)) -> #(server, None)
    Ok(jsonrpc.Correlated(jsonrpc.ServerRequest(id, method, params))) -> {
      case
        server.phase == RequestsOnly
        || has_metadata(params)
        || method == "server/discover"
        || method == "subscriptions/listen"
      {
        True -> handle_modern(server, id, method, params)
        False -> handle_request(server, id, method, params)
      }
    }
    Ok(jsonrpc.Correlated(jsonrpc.Notification(
      "notifications/cancelled",
      Some(json.Object(fields)),
    ))) -> {
      let cancelled = case list.key_find(fields, "requestId") {
        Ok(json.Int(id)) -> Some(jsonrpc.IdInt(id))
        Ok(json.String(id)) -> Some(jsonrpc.IdString(id))
        _ -> None
      }
      #(
        Server(
          ..server,
          subscriptions: list.filter(server.subscriptions, fn(id) {
            Some(id) != cancelled
          }),
        ),
        None,
      )
    }
    Ok(jsonrpc.Correlated(jsonrpc.Notification(
      "notifications/initialized",
      params,
    ))) -> {
      let phase = case params, server.phase {
        None, AwaitingInitialized | Some(json.Object(_)), AwaitingInitialized ->
          Ready
        _, phase -> phase
      }
      #(Server(..server, phase:), None)
    }
    Ok(jsonrpc.Correlated(jsonrpc.Notification(_, _)))
    | Ok(jsonrpc.Correlated(jsonrpc.Response(_, _))) -> #(server, None)
  }
}

fn has_metadata(params: Option(JsonValue)) -> Bool {
  case params {
    Some(json.Object(fields)) -> result.is_ok(list.key_find(fields, "_meta"))
    None | Some(_) -> False
  }
}

/// Closes acknowledged subscriptions gracefully at the transport's EOF boundary.
///
/// ## Examples
///
/// ```gleam
/// // server.close_subscriptions(server) returns final correlated complete results.
/// ```
pub fn close_subscriptions(server: Server) -> List(JsonValue) {
  list.map(server.subscriptions, subscription.closed)
}

fn handle_modern(
  server: Server,
  id: jsonrpc.Id,
  method: String,
  params: Option(JsonValue),
) -> #(Server, Option(JsonValue)) {
  case modern_metadata(params) {
    Error(metadata.InvalidMetadata(reason)) -> #(
      server,
      Some(rpc_error(Some(id), -32_602, reason, None)),
    )
    Error(metadata.UnsupportedVersion(requested)) -> #(
      server,
      Some(rpc_error(
        Some(id),
        -32_022,
        "unsupported protocol version",
        Some(
          json.Object([
            #(
              "supported",
              json.Array(list.map(revision.supported(), json.String)),
            ),
            #("requested", json.String(requested)),
          ]),
        ),
      )),
    )
    Ok(meta) ->
      case revision.is_modern(metadata.revision(meta)) {
        False -> handle_request(server, id, method, params)
        True -> modern_method(server, id, method, params, meta)
      }
  }
}

fn modern_metadata(
  params: Option(JsonValue),
) -> Result(metadata.Metadata, metadata.Fault) {
  use fields <- result.try(
    params_fields(params) |> result.map_error(metadata.InvalidMetadata),
  )
  use raw <- result.try(
    list.key_find(fields, "_meta")
    |> result.replace_error(metadata.InvalidMetadata(
      "request metadata is required",
    )),
  )
  metadata.decode(raw)
}

fn modern_method(
  server: Server,
  id: jsonrpc.Id,
  method: String,
  params: Option(JsonValue),
  meta: metadata.Metadata,
) -> #(Server, Option(JsonValue)) {
  case method {
    "server/discover" -> #(
      server,
      Some(modern_success(
        server,
        id,
        json.Object(list.append(
          [
            #(
              "supportedVersions",
              json.Array(list.map(revision.supported(), json.String)),
            ),
            #("capabilities", capabilities(server)),
          ],
          discovery.cache_fields(server.cache),
        )),
      )),
    )
    "tools/list" -> #(
      server,
      Some(case list_params(params) {
        Error(reason) -> rpc_error(Some(id), -32_602, reason, None)
        Ok(Nil) ->
          modern_success(
            server,
            id,
            json.Object(list.append(
              [
                #("tools", json.Array(list.map(server.tools, descriptor_json))),
              ],
              discovery.cache_fields(server.cache),
            )),
          )
      }),
    )
    "tools/call" -> #(server, Some(modern_call_tool(server, id, params, meta)))
    "subscriptions/listen" -> listen(server, id, params)
    _ -> #(server, Some(rpc_error(Some(id), -32_601, "method not found", None)))
  }
}

fn capabilities(server: Server) -> JsonValue {
  case server.tools {
    [] -> json.Object([])
    [_, ..] -> json.Object([#("tools", json.Object([]))])
  }
}

fn listen(
  server: Server,
  id: jsonrpc.Id,
  params: Option(JsonValue),
) -> #(Server, Option(JsonValue)) {
  let accepted = {
    use fields <- result.try(params_fields(params))
    use notifications <- result.try(
      list.key_find(fields, "notifications")
      |> result.replace_error("notifications filter is required"),
    )
    use _ <- result.try(subscription.decode(notifications))
    case
      list.length(server.subscriptions) >= 32
      || list.contains(server.subscriptions, id)
    {
      True -> Error("subscription limit or duplicate request id")
      False -> Ok(Nil)
    }
  }
  case accepted {
    Error(reason) -> #(server, Some(rpc_error(Some(id), -32_602, reason, None)))
    Ok(Nil) -> #(
      Server(..server, subscriptions: [id, ..server.subscriptions]),
      Some(subscription.acknowledge(id, subscription.empty())),
    )
  }
}

fn modern_call_tool(
  server: Server,
  id: jsonrpc.Id,
  params: Option(JsonValue),
  meta: metadata.Metadata,
) -> JsonValue {
  use fields <- or_modern_error(params_fields(params), id)
  use #(name, arguments) <- or_modern_error(
    tool_arguments(Some(json.Object(fields))),
    id,
  )
  use tool <- or_modern_error(
    list.find(server.tools, fn(tool) { tool.descriptor.name == name })
      |> result.replace_error("unknown tool " <> name),
    id,
  )
  let context = mrtr.context(json.Object(fields))
  use context <- or_modern_error(context, id)
  let admitted = case tool_input_schema(server, name) {
    Some(compiled) ->
      schema.validate(compiled, arguments)
      |> result.map_error(schema.validation_error_message)
    None -> Error("tool input schema is unsupported")
  }
  case admitted {
    Error(reason) -> modern_success(server, id, result_json(failure(reason)))
    Ok(Nil) ->
      case tool.round_trip(arguments, context) {
        Error(InvalidArguments(reason)) | Error(ExecutionFailed(reason)) ->
          modern_success(server, id, result_json(failure(reason)))
        Ok(Finished(answer)) ->
          modern_success(server, id, checked_output(tool, answer))
        Ok(Suspended(required)) -> required_result(server, id, required, meta)
      }
  }
}

fn checked_output(tool: Tool, answer: protocol.CallToolResult) -> JsonValue {
  case tool.descriptor.output_schema, answer.is_error {
    None, _ | _, True -> result_json(answer)
    Some(raw_schema), False -> {
      let validated = {
        use compiled <- result.try(
          schema.new(raw_schema)
          |> result.map_error(schema.schema_error_message),
        )
        use value <- result.try(case answer.structured_content {
          Some(value) -> Ok(value)
          None -> Error("tool output is missing structuredContent")
        })
        schema.validate(compiled, value)
        |> result.map_error(schema.validation_error_message)
      }
      case validated {
        Ok(Nil) -> result_json(answer)
        Error(reason) -> result_json(failure(reason))
      }
    }
  }
}

fn or_modern_error(
  value: Result(a, String),
  id: jsonrpc.Id,
  next: fn(a) -> JsonValue,
) -> JsonValue {
  case value {
    Ok(value) -> next(value)
    Error(reason) -> rpc_error(Some(id), -32_602, reason, None)
  }
}

fn modern_success(
  server: Server,
  id: jsonrpc.Id,
  value: JsonValue,
) -> JsonValue {
  let fields = case value {
    json.Object(fields) -> fields
    _ -> []
  }
  let fields = case list.key_find(fields, "resultType") {
    Ok(_) -> fields
    Error(Nil) -> [#("resultType", json.String("complete")), ..fields]
  }
  jsonrpc.response(
    id,
    json.Object(
      list.append(fields, [
        #(
          "_meta",
          json.Object([
            #(
              "io.modelcontextprotocol/serverInfo",
              json.Object([
                #("name", json.String(server.name)),
                #("version", json.String(server.version)),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
}

fn rpc_error(
  id: Option(jsonrpc.Id),
  code: Int,
  message: String,
  data: Option(JsonValue),
) -> JsonValue {
  jsonrpc.error_response(id, jsonrpc.RpcError(code, message, data))
}

fn handle_request(
  server: Server,
  id: jsonrpc.Id,
  method: String,
  params: Option(JsonValue),
) -> #(Server, Option(JsonValue)) {
  case method, server.phase {
    _, RequestsOnly -> #(
      server,
      Some(rpc_error(Some(id), -32_602, "request metadata is required", None)),
    )
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
          #("tools", json.Array(list.map(server.tools, legacy_descriptor_json))),
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
    Ok(answer) -> success_response(id, result_json(legacy_answer(answer)))
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

fn required_result(
  registry: Server,
  id: jsonrpc.Id,
  required: mrtr.Required,
  meta: metadata.Metadata,
) -> JsonValue {
  let capabilities = case metadata.capabilities(meta) {
    json.Object(fields) -> fields
    _ -> []
  }
  let missing = case mrtr.input_requests(required) {
    None -> []
    Some(inputs) ->
      inputs
      |> list.map(fn(pair) {
        case mrtr.method(pair.1) {
          "sampling/createMessage" -> "sampling"
          "elicitation/create" -> "elicitation"
          "roots/list" -> "roots"
          _ -> "unsupported"
        }
      })
      |> list.unique
      |> list.filter(fn(name) {
        case list.key_find(capabilities, name) {
          Ok(json.Object(_)) -> False
          _ -> True
        }
      })
  }
  case missing {
    [] -> modern_success(registry, id, mrtr.value(required))
    _ ->
      jsonrpc.error_response(
        Some(id),
        jsonrpc.RpcError(
          -32_021,
          "required client capability is missing",
          Some(
            json.Object([
              #(
                "requiredCapabilities",
                json.Array(list.map(missing, json.String)),
              ),
            ]),
          ),
        ),
      )
  }
}

fn legacy_descriptor_json(tool: Tool) -> JsonValue {
  let descriptor = case tool.descriptor.output_schema {
    Some(json.Object(fields)) ->
      case list.key_find(fields, "type") {
        Ok(json.String("object")) -> tool.descriptor
        _ -> protocol.ToolDescriptor(..tool.descriptor, output_schema: None)
      }
    None | Some(_) ->
      protocol.ToolDescriptor(..tool.descriptor, output_schema: None)
  }
  descriptor_json(Tool(..tool, descriptor:))
}

fn legacy_answer(answer: protocol.CallToolResult) -> protocol.CallToolResult {
  case answer.structured_content {
    None | Some(json.Object(_)) -> answer
    Some(_) -> protocol.CallToolResult(..answer, structured_content: None)
  }
}
