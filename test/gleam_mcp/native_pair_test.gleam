import gleam/list
import gleam/option.{Some}
import gleam_mcp/client
import gleam_mcp/json
import gleam_mcp/protocol
import gleam_mcp/transport

pub fn standalone_client_and_server_exchange_over_real_stdio_test() {
  // The shell expands only the checked-in build's library paths. exec leaves
  // the native server as the exact child whose retirement the client proves.
  let spawn =
    transport.spawn("/bin/sh", [
      "-c",
      "exec erl -noshell -pa build/dev/erlang/*/ebin -eval 'case support@server_fixture:run() of {ok,nil} -> erlang:halt(0); {error,_} -> erlang:halt(2) end.'",
    ])
  let assert Ok(peer) =
    client.start(
      transport.PortTransport(spawn),
      client.options("1") |> client.with_client_name("native-client"),
    )
    as "production server completes the client initialize exchange"
  let tools = client.list_tools(peer, 3000)
  let answer =
    client.call_tool(peer, "echo", json.Object([#("n", json.Int(7))]), 3000)
  let failed = client.call_tool(peer, "failed", json.Object([]), 3000)
  let retirement = client.shutdown(peer, within: 3000)

  let assert Ok(tools) = tools as "production listing completes"
  assert list.map(tools, fn(tool) { tool.name })
    == ["echo", "failed", "blocked"]
  let assert Ok(answer) = answer as "production tools/call completes"
  assert answer.structured_content == Some(json.Object([#("n", json.Int(7))]))
  assert answer.content == [protocol.Text("{\"n\":7}")]
  let assert Ok(failed) = failed
    as "tool failure remains a successful protocol result"
  assert failed.is_error
  assert retirement == Ok(Nil)
}
