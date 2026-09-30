//// A real standalone stdio fixture driven by the native pipe tests.

import gleam/erlang/process
import gleam/option
import gleam_mcp/protocol
import gleam_mcp/server
import gleam_mcp/server_stdio

/// Constructs the checked-in fixture using the library's production server.
///
/// ## Examples
///
/// ```gleam
/// // server_fixture.run()
/// ```
pub fn run() -> Result(Nil, server_stdio.StdioError) {
  let assert Ok(echo_tool) =
    server.tool(
      "echo",
      "Echoes arguments.",
      server.object_schema([], []),
      fn(arguments) { Ok(server.structured(arguments)) },
    )
    as "fixture definition is valid"
  let assert Ok(failed) =
    server.tool("failed", "Fails.", server.object_schema([], []), fn(_) {
      Error(server.ExecutionFailed("fixture failed"))
    })
    as "fixture definition is valid"
  let assert Ok(blocked) =
    server.tool(
      "blocked",
      "Exceeds its deadline.",
      server.object_schema([], []),
      fn(_) {
        process.sleep(5000)
        Ok(protocol.CallToolResult(
          content: [],
          is_error: False,
          structured_content: option.None,
        ))
      },
    )
    as "fixture definition is valid"
  let assert Ok(server) =
    server.new("fixture", "1", [echo_tool, failed, blocked])
    as "fixture server is valid"
  let options = server_stdio.options() |> server_stdio.with_request_timeout(200)
  server_stdio.run_with_options(server, options)
}
