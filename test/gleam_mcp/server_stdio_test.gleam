import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/json
import gleam_mcp/jsonrpc
import gleam_mcp/protocol
import gleam_mcp/server
import gleam_mcp/server_stdio
import weft

type InputMessage {
  Read(reply: process.Subject(Option(String)))
}

fn input(
  lines: List(String),
) -> #(process.Pid, fn() -> Result(Option(String), server_stdio.StdioError)) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      input_loop(subject, lines)
    })
  let assert Ok(subject) = process.receive(ready, 1000)
    as "reader publishes its own subject"
  #(pid, fn() { Ok(process.call(subject, waiting: 1000, sending: Read)) })
}

fn input_loop(
  subject: process.Subject(InputMessage),
  lines: List(String),
) -> Nil {
  let assert Ok(Read(reply)) = process.receive(subject, 5000)
    as "fixture read arrives"
  case lines {
    [] -> {
      process.send(reply, None)
      input_loop(subject, [])
    }
    [line, ..rest] -> {
      process.send(reply, Some(line))
      input_loop(subject, rest)
    }
  }
}

fn initialized_lines() -> List(String) {
  [
    json.to_string(protocol.initialize_request(jsonrpc.IdInt(1), "1")),
    json.to_string(protocol.initialized()),
  ]
}

fn echo_server(
  handler: fn(json.JsonValue) ->
    Result(protocol.CallToolResult, server.ToolError),
) -> server.Server {
  let assert Ok(tool) =
    server.tool("echo", "", server.object_schema([], []), handler)
    as "definition is valid"
  let assert Ok(server) = server.new("fixture", "1", [tool])
    as "server is valid"
  server
}

pub fn pipelined_input_is_retained_and_eof_drains_final_request_test() {
  let lines =
    list.append(initialized_lines(), [
      json.to_string(protocol.call_tool_request(
        jsonrpc.IdInt(2),
        "echo",
        json.Object([#("n", json.Int(2))]),
      )),
      json.to_string(protocol.call_tool_request(
        jsonrpc.IdInt(3),
        "echo",
        json.Object([#("n", json.Int(3))]),
      )),
    ])
  let #(reader, read) = input(lines)
  let output = process.new_subject()
  let write = fn(line) {
    process.send(output, line)
    Ok(Nil)
  }
  let server =
    echo_server(fn(arguments) {
      process.sleep(20)
      Ok(server.structured(arguments))
    })
  let result =
    server_stdio.run_with_io(server, server_stdio.options(), read, write)
  process.kill(reader)
  assert result == Ok(Nil)

  let ids =
    list.map([1, 2, 3], fn(expected) {
      let assert Ok(line) = process.receive(output, 1000)
        as "every admitted request responds"
      let assert Ok(jsonrpc.Response(jsonrpc.IdInt(id), Ok(_))) =
        jsonrpc.decode(line)
        as "stdout carries a correlated response"
      assert id == expected
      id
    })
  assert ids == [1, 2, 3]
  assert process.receive(output, 0) == Error(Nil)
}

pub fn eof_during_blocked_handler_observes_request_deadline_and_joins_worker_test() {
  let entered = process.new_subject()
  let lines =
    list.append(initialized_lines(), [
      json.to_string(protocol.call_tool_request(
        jsonrpc.IdInt(2),
        "echo",
        json.Object([]),
      )),
    ])
  let #(reader, read) = input(lines)
  let server =
    echo_server(fn(_) {
      process.send(entered, process.self())
      process.sleep(5000)
      Ok(server.text("too late"))
    })
  let options = server_stdio.options() |> server_stdio.with_request_timeout(100)
  let result =
    server_stdio.run_with_io(server, options, read, fn(_) { Ok(Nil) })
  process.kill(reader)
  assert result == Error(server_stdio.RequestTimedOut)

  let assert Ok(handler) = process.receive(entered, 1000)
    as "handler started before deadline"
  let watch = process.monitor(handler)
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "runner returned only after the handler exited"
}

pub fn output_failure_cancels_and_joins_the_lookahead_reader_test() {
  let handler_entered = process.new_subject()
  let reader_entered = process.new_subject()
  let server =
    echo_server(fn(_) {
      let gate = process.new_subject()
      process.send(handler_entered, gate)
      let assert Ok(Nil) = process.receive(gate, 1000)
        as "test releases handler after the reader blocks"
      Ok(server.text("done"))
    })
  let #(server, _) =
    server.handle_line(
      server,
      json.to_string(protocol.initialize_request(jsonrpc.IdInt(1), "1")),
    )
  let #(server, _) =
    server.handle_line(server, json.to_string(protocol.initialized()))
  let #(reader, read) =
    input([
      json.to_string(protocol.call_tool_request(
        jsonrpc.IdInt(2),
        "echo",
        json.Object([]),
      )),
    ])
  let read = fn() {
    case read() {
      Ok(None) -> {
        let block: process.Subject(Nil) = process.new_subject()
        process.send(reader_entered, process.self())
        let _ = process.receive(block, 5000)
        Ok(None)
      }
      result -> result
    }
  }
  let run =
    weft.new([
      fn() {
        Ok(
          server_stdio.run_with_io(server, server_stdio.options(), read, fn(_) {
            Error(Nil)
          }),
        )
      },
    ])
    |> weft.start_detached

  let assert Ok(blocked_reader) = process.receive(reader_entered, 1000)
    as "actual lookahead worker entered its blocked read"
  let watch = process.monitor(blocked_reader)
  let assert Ok(gate) = process.receive(handler_entered, 1000)
    as "handler is awaiting test release"
  process.send(gate, Nil)
  let assert weft.PulledOutcome(weft.Completed(_, verdict)) =
    weft.pull(run, within: 1000)
    as "runner returns after write refusal"
  assert verdict == Error(server_stdio.WriteFailed)
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "actual lookahead worker exited before runner returned"
  assert weft.pull(run, within: 1000) == weft.AllDelivered
  process.kill(reader)
}

pub fn read_failure_is_an_explicit_verdict_test() {
  assert server_stdio.run_with_io(
      echo_server(fn(_) { Ok(server.text("ok")) }),
      server_stdio.options(),
      fn() { Error(server_stdio.ReadFailed) },
      fn(_) { Ok(Nil) },
    )
    == Error(server_stdio.ReadFailed)
}

pub fn lookahead_read_fault_joins_the_handler_before_return_test() {
  list.each([server_stdio.ReadFailed, server_stdio.LineTooLong], fn(fault) {
    // Repeating the synchronized interruption exercises scheduler order without
    // substituting a timing threshold for the actual process-liveness witness.
    int.range(from: 1, to: 21, with: Nil, run: fn(_, _) {
      interrupted_handler(
        fault,
        fn(registry) { registry },
        protocol.call_tool_request(jsonrpc.IdInt(2), "echo", json.Object([])),
      )
    })
  })
}

fn interrupted_handler(
  fault: server_stdio.StdioError,
  profile: fn(server.Server) -> server.Server,
  envelope: json.JsonValue,
) -> Nil {
  let handler_entered = process.new_subject()
  let reader_entered = process.new_subject()
  let #(reader, read) = input([json.to_string(envelope)])
  let read = fn() {
    case read() {
      Ok(None) -> {
        let fail = process.new_subject()
        process.send(reader_entered, fail)
        Error(process.receive_forever(fail))
      }
      result -> result
    }
  }
  let run =
    weft.new([
      fn() {
        // This subject belongs to the runner, so liveness is measured at its
        // return boundary before any outer test scope can join descendants.
        let handler_record = process.new_subject()
        let server =
          echo_server(fn(_) {
            let block: process.Subject(Nil) = process.new_subject()
            process.send(handler_record, process.self())
            process.send(handler_entered, process.self())
            let Nil = process.receive_forever(block)
            Ok(server.text("unreachable"))
          })
        let #(server, _) =
          server.handle_line(
            server,
            json.to_string(protocol.initialize_request(jsonrpc.IdInt(1), "1")),
          )
        let #(server, _) =
          server.handle_line(server, json.to_string(protocol.initialized()))
        let server = profile(server)
        let verdict =
          server_stdio.run_with_io(server, server_stdio.options(), read, fn(_) {
            Ok(Nil)
          })
        let assert Ok(handler) = process.receive(handler_record, 0)
          as "handler published its exact worker before read failure"
        Ok(#(verdict, process.is_alive(handler)))
      },
    ])
    |> weft.start_detached

  let assert Ok(handler) = process.receive(handler_entered, 1000)
    as "admitted handler is blocked before the reader fails"
  let watch = process.monitor(handler)
  let assert Ok(fail) = process.receive(reader_entered, 1000)
    as "lookahead is waiting to return its exact fault"
  process.send(fail, fault)
  let assert weft.PulledOutcome(weft.Completed(_, #(verdict, alive))) =
    weft.pull(run, within: 1000)
    as "runner completes the read-failure cancellation"
  assert verdict == Error(fault)
  assert !alive
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(0)
    as "handler DOWN is already observable at runner return"
  assert weft.pull(run, within: 1000) == weft.AllDelivered
  process.kill(reader)
}

pub fn modern_read_fault_joins_live_handler_before_return_test() {
  list.each([server_stdio.ReadFailed, server_stdio.LineTooLong], fn(fault) {
    let envelope =
      jsonrpc.request(
        jsonrpc.IdInt(2),
        "tools/call",
        Some(
          json.Object([
            #(
              "_meta",
              json.Object([
                #(
                  "io.modelcontextprotocol/protocolVersion",
                  json.String("2026-07-28"),
                ),
                #("io.modelcontextprotocol/clientCapabilities", json.Object([])),
              ]),
            ),
            #("name", json.String("echo")),
            #("arguments", json.Object([])),
          ]),
        ),
      )
    interrupted_handler(fault, server.modern, envelope)
  })
}

pub fn modern_write_failure_joins_blocked_handler_before_return_test() {
  let entered = process.new_subject()
  let reader_waiting = process.new_subject()
  let meta =
    json.Object([
      #("io.modelcontextprotocol/protocolVersion", json.String("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.Object([])),
    ])
  let call =
    jsonrpc.request(
      jsonrpc.IdInt(1),
      "tools/call",
      Some(
        json.Object([
          #("_meta", meta),
          #("name", json.String("echo")),
          #("arguments", json.Object([])),
        ]),
      ),
    )
  let discover =
    jsonrpc.request(
      jsonrpc.IdInt(2),
      "server/discover",
      Some(json.Object([#("_meta", meta)])),
    )
  let discover_line = json.to_string(discover)
  let #(reader, read) = input([json.to_string(call), discover_line])
  let read = fn() {
    let answer = read()
    case answer {
      Ok(Some(line)) if line == discover_line -> {
        let gate = process.new_subject()
        process.send(reader_waiting, gate)
        let Nil = process.receive_forever(gate)
        answer
      }
      _ -> answer
    }
  }
  let run =
    weft.new([
      fn() {
        let record = process.new_subject()
        let registry =
          echo_server(fn(_) {
            let blocked: process.Subject(Nil) = process.new_subject()
            process.send(record, process.self())
            process.send(entered, process.self())
            let Nil = process.receive_forever(blocked)
            Ok(server.text("unreachable"))
          })
          |> server.modern
        let verdict =
          server_stdio.run_with_io(
            registry,
            server_stdio.options(),
            read,
            fn(_) { Error(Nil) },
          )
        let assert Ok(handler) = process.receive(record, 0)
          as "admitted worker identity is retained"
        Ok(#(verdict, process.is_alive(handler)))
      },
    ])
    |> weft.start_detached
  let assert Ok(handler) = process.receive(entered, 1000)
    as "tool is blocked before control response fails"
  let monitor = process.monitor(handler)
  let assert Ok(gate) = process.receive(reader_waiting, 1000)
    as "discovery admission waits for blocked handler"
  process.send(gate, Nil)
  let assert weft.PulledOutcome(weft.Completed(_, #(verdict, alive))) =
    weft.pull(run, within: 1000)
    as "write-failure owner returns after draining"
  assert verdict == Error(server_stdio.WriteFailed)
  assert !alive
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(0)
    as "worker DOWN already exists at public return"
  assert weft.pull(run, within: 1000) == weft.AllDelivered
  process.kill(reader)
}
