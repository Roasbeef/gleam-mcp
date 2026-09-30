# Gleam MCP

A typed Gleam MCP client and tools server, extracted from
[Loom](https://github.com/Roasbeef/loom). The modern profile implements
MCP `2026-07-28` over stdio and HTTP. The existing `2025-06-18` and
`2024-11-05` initialization profiles remain available over stdio.

The package couples tool schemas, argument codecs, and result codecs in one
opaque definition shared by client and server. It implements the three base
request patterns: request/response, explicit multi-round-trip continuation,
and owned subscriptions. Resources, prompts, and client providers are separate
optional features; see [the feature scope](docs/extensions.md) and
[resources/prompts issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1).

Use Gleam >= 1.18 and Erlang/OTP >= 29. Consume the package through an exact
Git commit dependency, as [Jevelin MCP](https://github.com/Roasbeef/jevelin-mcp)
does. The runtime targets Erlang; its copied development linter isn't a
runtime dependency. Loom keeps its capability generator, schema planner, and
MessagePack adapter.

## Define a typed tool

A codec checks both emitted and received JSON against its compiled schema.
Custom encoders and decoders stay inside that boundary. A tool then binds the
codecs to one name and description:

```gleam
import gleam/result
import gleam_mcp/codec
import gleam_mcp/json
import gleam_mcp/schema
import gleam_mcp/server
import gleam_mcp/tool

pub fn echo_tool() -> Result(tool.Tool(String, String), String) {
  use shape <- result.try(
    schema.new(server.object_schema([
      #("message", json.Object([#("type", json.String("string"))])),
    ], ["message"])) |> result.map_error(schema.schema_error_message),
  )
  let message = codec.new(shape,
    fn(text) { json.Object([#("message", json.String(text))]) },
    fn(value) {
      server.string_argument(value, "message")
      |> result.map_error(fn(_) { "Expected a message string." })
    },
  )
  tool.new("echo", "Returns the supplied message.", message, message)
  |> result.map_error(fn(_) { "Invalid tool definition." })
}
```

Bind the definition with `server.bind(definition, fn(message) { Ok(message) })`,
then register it with `server.new`. Duplicate names fail construction.
`tool.with_result_decoder` can additionally close over the original typed
arguments, preserving invariants such as a Choice's permitted labels or a
Score's rubric bounds. Jevelin's shared definitions demonstrate this contract
with real request-bound answer decoding.

## Call through the same definition

Construct a modern HTTP endpoint with `client_http.new(url, auth_headers)`;
its `client_http.endpoint` is the caller-owned exchange used by typed calls:

```gleam
client.call(
  client_http.endpoint(connection),
  definition,
  "hello",
  request.options("my-application", "1") |> request.with_timeout(5000),
)
```

The result is `client.Complete(output)`, `ToolFailed(result)`, or
`InputRequired(continuation)`. A continuation retains the exact endpoint,
arguments, output decoder, version, and latest opaque state. Supply explicit
input responses with `mrtr.responses`, then call `client.resume`; there is no
endpoint or decoder argument to replace during resumption. An interrupted
exchange never automatically repeats an effect.

For modern native stdio, use `client.start_modern` with a `PortTransport` and
pass `client.endpoint(native_client)` to the same typed API. For existing
initialized clients, `client.start(transport, client.options(version))`
retains the legacy handshake and raw `list_tools`/`call_tool` interface.
Raw non-text content stays in `protocol.Other(kind, raw)` for the consumer to
interpret. Applications own the isolation policy for executables they select.

## Serve stdio or HTTP

`server_stdio.run` reads bounded newline-delimited JSON-RPC and writes only
protocol frames to stdout. Compile before attaching a client. EOF stops
admission and drains admitted work; cancellation joins owned handler scopes.
The modern runtime keeps subscriptions live while other requests complete.

For HTTP, construct `server_http.new(port, "/mcp", allowed_origins, admission)`
and call `server_http.start_server`. The listener binds `127.0.0.1`; choose
`Authenticate(check)` or explicitly select `LocalUnauthenticated`. Every
present Origin must match the allowlist. Remote TLS deployments use a front
proxy with their host admission policy. The client supports HTTPS with peer
and hostname verification. Server request bodies require unambiguous
`Content-Length` framing and are limited to eight MiB; chunked uploads are
refused before body collection.

Requests use a single POST endpoint and accept JSON or request-scoped SSE.
Mirrored metadata and `x-mcp-header` bindings validate before tool effects.
Gun retries are disabled; socket loss cancels the local scope without claiming
rollback of a remote operation. HTTP subscriptions have a retained
`client_http.listen`/`poll`/`cancel` lifetime. Session ids, event replay, and
legacy GET event channels aren't implemented.

See [protocol and ownership contracts](docs/protocol.md) for the exact spec
pin, profiles, typed boundaries, continuation semantics, and transport custody.
The [JSON Schema corpus record](test/fixtures/json_schema/UPSTREAM.md) lists
required-suite coverage, optional coverage and supported regex forms. Schemas
compile offline; references don't trigger automatic network access.

## Development

`make check` runs formatting, warning-free application compilation, unit and
conformance tests, the copied custom linter and its tests, source-boundary and
documentation gates, and independent native stdio and HTTP peers. CI uses the
same gate on Linux and macOS. `make fmt` formats both packages. Read
[the inherited style guide](docs/gleam-style.md), [execution notes](docs/execution.md),
and [the current handoff](docs/next.md) before changing the package.
