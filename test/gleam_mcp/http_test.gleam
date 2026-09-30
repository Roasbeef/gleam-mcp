import gleam/bit_array
import gleam/option.{None}
import gleam/result
import gleam_mcp/client_http
import gleam_mcp/http
import gleam_mcp/http_headers as headers
import gleam_mcp/json
import gleam_mcp/request
import gleam_mcp/sse

pub fn unsafe_header_values_round_trip_test() {
  assert headers.encode_value(" padded ") == "=?base64?IHBhZGRlZCA=?="
  assert headers.encode_value("=?base64?literal?=")
    == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="
  assert headers.decode_value(headers.encode_value("漢😀\t\n")) == Ok("漢😀\t\n")
  assert headers.decode_value("=?base64?not-base64!?=") |> result.is_error
  assert headers.decode_value("bad\r\nheader") |> result.is_error
}

pub fn plan_rejects_ambiguous_paths_and_tokens_test() {
  let primitive = fn(name) {
    json.Object([
      #("type", json.String("string")),
      #("x-mcp-header", json.String(name)),
    ])
  }
  assert headers.compile(
      json.Object([
        #(
          "properties",
          json.Object([#("a", primitive("Tenant")), #("b", primitive("tenant"))]),
        ),
      ]),
    )
    |> result.is_error
  assert headers.compile(json.Object([#("items", primitive("Tenant"))]))
    |> result.is_error
  assert headers.compile(
      json.Object([#("oneOf", json.Array([primitive("Tenant")]))]),
    )
    |> result.is_error
  assert headers.compile(
      json.Object([
        #("properties", json.Object([#("a", primitive("Bad Name"))])),
      ]),
    )
    |> result.is_error
}

pub fn nested_plan_preserves_body_header_coupling_test() {
  let schema =
    json.Object([
      #(
        "properties",
        json.Object([
          #(
            "nested",
            json.Object([
              #(
                "properties",
                json.Object([
                  #(
                    "tenant",
                    json.Object([
                      #("type", json.String("integer")),
                      #("x-mcp-header", json.String("Tenant")),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ])
  let assert Ok(plan) = headers.compile(schema)
  let args =
    json.Object([#("nested", json.Object([#("tenant", json.Int(42))]))])
  assert headers.headers(plan, args) == Ok([#("mcp-param-Tenant", "42")])
  assert headers.validate(plan, args, [#("MCP-PARAM-TENANT", "42")]) == Ok(Nil)
  assert headers.validate(plan, args, []) |> result.is_error
  assert headers.validate(plan, args, [#("mcp-param-tenant", "43")])
    |> result.is_error
  assert headers.headers(
      plan,
      json.Object([
        #("nested", json.Object([#("tenant", json.Int(9_007_199_254_740_992))])),
      ]),
    )
    |> result.is_error
}

pub fn sse_handles_every_utf8_and_crlf_fragment_boundary_test() {
  let bytes = <<": comment\r\ndata: 漢😀\r\ndata: tail\r\n\r\n":utf8>>
  let assert Ok(decoder) = sse.new(100)
  let assert Ok(#(decoder, events)) = one_byte(decoder, bytes, [])
  assert events == ["漢😀\ntail"]
  assert sse.finish(decoder) == Ok(Nil)
}

fn one_byte(decoder, bytes, events) {
  case bytes {
    <<>> -> Ok(#(decoder, events))
    <<byte:8, rest:bytes>> -> {
      use #(decoder, emitted) <- result.try(sse.feed(decoder, <<byte:8>>))
      one_byte(decoder, rest, case emitted {
        [] -> events
        [event] -> [event, ..events]
        _ -> events
      })
    }
    _ -> Error("invalid fixture")
  }
}

pub fn sse_bounds_and_truncation_are_errors_test() {
  let assert Ok(decoder) = sse.new(12)
  assert sse.feed(decoder, <<"data: thirteen!\n\n":utf8>>) |> result.is_error
  let assert Ok(#(decoder, [])) = sse.feed(decoder, <<"data: x\n":utf8>>)
  assert sse.finish(decoder) |> result.is_error
  let assert Ok(decoder) = sse.new(100)
  assert sse.feed(decoder, <<"data: ":utf8, 255, 10>>) |> result.is_error
  assert bit_array.byte_size(<<"é":utf8>>) == 2
}

pub fn header_constructor_rejects_metadata_injection_test() {
  let envelope =
    json.Object([
      #("method", json.String("tools/list")),
      #(
        "params",
        json.Object([
          #(
            "_meta",
            json.Object([
              #(
                "io.modelcontextprotocol/protocolVersion",
                json.String("2026-07-28\r\nInjected: value"),
              ),
            ]),
          ),
        ]),
      ),
    ])
  assert http.headers(envelope) |> result.is_error
}

pub fn mirrored_integer_admits_only_safe_integral_values_test() {
  let schema =
    json.Object([
      #(
        "properties",
        json.Object([
          #(
            "n",
            json.Object([
              #("type", json.String("integer")),
              #("x-mcp-header", json.String("N")),
            ]),
          ),
        ]),
      ),
    ])
  let assert Ok(plan) = headers.compile(schema)
  assert headers.headers(plan, json.Object([#("n", json.Float(42.0))]))
    == Ok([#("mcp-param-N", "42")])
  assert headers.headers(plan, json.Object([#("n", json.Float(42.5))]))
    |> result.is_error
  assert headers.validate(plan, json.Object([]), [
      #("mcp-param-n", "1"),
      #("MCP-PARAM-N", "2"),
    ])
    |> result.is_error
}

pub fn direct_outbound_invalid_timeout_is_refused_before_http_effects_test() {
  let assert Ok(config) = client_http.new("http://127.0.0.1:1/mcp", [])
  let invalid = fn(timeout) {
    request.Outbound(json.Null, None, timeout, fn(_) { Nil })
  }
  assert client_http.exchange(config, invalid(0))
    == Error(request.InvalidArguments(
      "timeout is outside the supported timer range",
    ))
  assert client_http.exchange(config, invalid(4_294_966_296))
    == Error(request.InvalidArguments(
      "timeout is outside the supported timer range",
    ))
}
