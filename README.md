# Gleam MCP

A Gleam MCP client and tools server, extracted from
[Loom](https://github.com/Roasbeef/loom). Wire decoding, tool registration and
server lifecycle are typed boundaries. Callers provide tool handlers; the
included Erlang runtime connects them to standard input and output.

The first release supports MCP `2025-06-18` and `2024-11-05` over stdio.
The server implements initialization, ping, tool discovery and tool calls.
The client also accepts a caller-owned channel transport. HTTP/SSE, OAuth,
resources, prompts, sampling, roots and elicitation are outside this release.

## Use the library

Add an exact Git commit to your `gleam.toml`:

```toml
[dependencies]
gleam_mcp = { git = "https://github.com/Roasbeef/gleam-mcp.git", ref = "acb4d70c55be05983bff8857090bf23dbab00d8e" }
```

The package targets Erlang. Use Gleam >= 1.18 and Erlang/OTP >= 29.

## Define a server

Tools register an object input schema and a handler. The handler validates
arguments before starting effects. Return `InvalidArguments` for a bad call
and `ExecutionFailed` for an operation that ran and failed.

```gleam
import gleam/result
import gleam_mcp/server

pub fn definition() -> Result(server.Server, server.ConfigurationError) {
  use echo <- result.try(server.tool(
    "echo",
    "Returns the supplied object.",
    server.object_schema([], []),
    fn(arguments) { Ok(server.structured(arguments)) },
  ))
  use instance <- result.try(server.new("echo", "0.1.0", [echo]))
  Ok(instance)
}
```

Pass the resulting server to `server_stdio.run`. It reads bounded input,
writes only newline-delimited JSON-RPC to stdout and exits on EOF. Compile
before attaching an MCP client: compiler status output does not belong on
the protocol stream. A complete executable consumer is
[Jevelin MCP](https://github.com/Roasbeef/jevelin-mcp).

`server.handle_line` exposes the same lifecycle without native transport.
An immutable registry rejects duplicate names before input is admitted.
Initialization negotiates the protocol version; discovery and calls require
the initialized notification. Malformed envelopes return errors with a
null id; handler argument failures retain the request id. Completed tool failures use
`isError`, and structured results also include their JSON text representation.

## Connect a client

```gleam
import gleam_mcp/client
import gleam_mcp/transport

pub fn connect(executable: String) -> Result(client.Client, client.StartError) {
  client.start(
    transport.PortTransport(transport.spawn(executable, [])),
    client.options("0.1.0") |> client.with_client_name("my-application"),
  )
}
```

Use `client.list_tools` and `client.call_tool` with explicit timeouts. Raw
non-text content stays in `protocol.Other(kind, raw)` for the caller to
interpret. Optional structured results retain the original JSON value.

For supervised startup, use `prepare_owned`, publish the cleanup census,
then `connect`. Retirement requires native process-exit evidence and normal
actor termination under one deadline. A termination request is not evidence
that the resource exited. The stdio transport runs operator-selected
executables without a sandbox; applications own their isolation policy.

## Development

`make check` runs formatting, a warning-free build, all application and
custom-linter tests, house lint, source-boundary checks and documentation
mirrors. `make fmt` formats both packages. CI runs the same gate on Linux and
macOS. See [the inherited style guide](docs/gleam-style.md) and
[the current handoff](docs/next.md).

The strict JSON parser and existing client/custody tests come from Loom at
`f399a07cf`. The parser preserves integer precision, rejects duplicate keys,
validates Unicode and bounds nesting. The development linter is copied under
`packages/lint`; it is not a runtime dependency. Loom's capability source
generator and MessagePack adapter remain in Loom.
