//// Multi round-trip results suspend one explicit request rather than replay it.
//// Request state is an opaque server string. Input requests remain caller-owned
//// work, and resumption requires responses with exactly the requested map keys.
//// Optional sampling, roots and elicitation providers are not executed here.
////
//// ## Flow
////
//// input_request admits a supported provider method and object parameters;
//// required checks presence and unique input keys. decode rebuilds those invariants
//// from a peer result. responses checks exact keys and object values before resume
//// can serialize responses_value. context decodes incoming server resume fields.
////
//// Required and Responses are opaque, so callers use checked constructors. A
//// server Context remains untrusted input: checking its shape doesn't prove which
//// suspension produced it. Provider execution and state integrity belong to the
//// application, and a state-only suspension never triggers an automatic retry.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/json.{type JsonValue}

/// A server's input request, preserved for an explicit caller decision.
pub opaque type InputRequest {
  /// The admitted provider method and object parameters.
  InputRequest(
    /// The specification-defined input method.
    method: String,
    /// Provider-specific parameters preserved as an object.
    params: JsonValue,
  )
}

/// A validated suspension with at least input requests or request state.
pub opaque type Required {
  /// The checked suspension returned to the explicit resumption path.
  Required(
    /// Optional input requests with unique keys and at most 32 entries.
    requests: Option(List(#(String, InputRequest))),
    /// Optional server-authored bytes, preserved without authentication.
    state: Option(String),
  )
}

/// Responses tied to the exact keys of a suspended request.
pub opaque type Responses {
  /// The checked response map tied to a suspension's exact keys.
  Responses(
    /// Exactly one object-valued response per requested key.
    values: List(#(String, JsonValue)),
  )
}

/// Input supplied on an explicitly resumed server request.
pub type Context {
  /// The admitted Context value.
  Context(
    /// Opaque state returned by the previous response, without interpretation.
    request_state: Option(String),
    /// Provider results, interpreted only by the caller-owned handler.
    input_responses: Option(JsonValue),
  )
}

/// Builds a validated input request without executing a provider.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.input_request("roots/list", json.Object([])) |> result.is_ok
/// assert mrtr.input_request("unknown/provider", json.Object([])) |> result.is_error
/// ```
pub fn input_request(
  method: String,
  params: JsonValue,
) -> Result(InputRequest, String) {
  use Nil <- result.try(case method {
    "elicitation/create" | "sampling/createMessage" | "roots/list" -> Ok(Nil)
    _ -> Error("unsupported MRTR input method")
  })
  case params {
    json.Object(_) -> Ok(InputRequest(method, params))
    _ -> Error("MRTR input params must be an object")
  }
}

/// Constructs a suspension with unique input keys and a finite input-map bound.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.required(None, None) |> result.is_error
/// assert mrtr.required(None, Some("opaque-state")) |> result.is_ok
/// ```
pub fn required(
  requests: Option(List(#(String, InputRequest))),
  state: Option(String),
) -> Result(Required, String) {
  use Nil <- result.try(case requests, state {
    None, None -> Error("input_required needs inputRequests or requestState")
    _, _ -> Ok(Nil)
  })
  use Nil <- result.try(case requests {
    None -> Ok(Nil)
    Some(values) -> validate_keys(list.map(values, fn(pair) { pair.0 }))
  })
  Ok(Required(requests, state))
}

/// Suspends a request with only an opaque state token.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.request_state(mrtr.load_shed("token")) == Some("token")
/// ```
pub fn load_shed(state: String) -> Required {
  Required(None, Some(state))
}

/// Returns input requests for a caller's explicit provider handling.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.input_requests(mrtr.load_shed("token")) == None
/// ```
pub fn input_requests(
  required: Required,
) -> Option(List(#(String, InputRequest))) {
  required.requests
}

/// Returns the exact opaque state that a resumed request must carry.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.request_state(mrtr.load_shed("token")) == Some("token")
/// ```
pub fn request_state(required: Required) -> Option(String) {
  required.state
}

/// Validates response keys against this suspension before resumption.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.responses(mrtr.load_shed("token"), []) |> result.is_ok
/// ```
pub fn responses(
  required: Required,
  values: List(#(String, JsonValue)),
) -> Result(Responses, String) {
  // Exact key membership ties the provider results to this suspension. Matching
  // count alone would let one requested input be replaced by an unrelated key.

  let expected = case required.requests {
    None -> []
    Some(requests) -> list.map(requests, fn(pair) { pair.0 })
  }
  let keys = list.map(values, fn(pair) { pair.0 })
  use Nil <- result.try(validate_keys(keys))
  use Nil <- result.try(
    case
      list.length(keys) == list.length(expected)
      && list.all(keys, list.contains(expected, _))
    {
      True -> Ok(Nil)
      False ->
        Error("input response keys must match the suspended input requests")
    },
  )
  use Nil <- result.try(
    list.try_each(values, fn(pair) {
      case pair.1 {
        json.Object(_) -> Ok(Nil)
        _ -> Error("input responses must be objects")
      }
    }),
  )
  Ok(Responses(values))
}

/// Encodes validated responses as the inputResponses object.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(responses) = mrtr.responses(mrtr.load_shed("token"), [])
/// assert mrtr.responses_value(responses) == json.Object([])
/// ```
pub fn responses_value(responses: Responses) -> JsonValue {
  json.Object(responses.values)
}

/// Encodes the required modern result discriminator and suspension payload.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.value(mrtr.load_shed("token")) == json.Object([
///   #("resultType", json.String("input_required")),
///   #("requestState", json.String("token")),
/// ])
/// ```
pub fn value(required: Required) -> JsonValue {
  let fields = [#("resultType", json.String("input_required"))]
  let fields = case required.requests {
    None -> fields
    Some(values) ->
      list.append(fields, [
        #(
          "inputRequests",
          json.Object(
            list.map(values, fn(pair) {
              #(
                pair.0,
                json.Object([
                  #("method", json.String(pair.1.method)),
                  #("params", pair.1.params),
                ]),
              )
            }),
          ),
        ),
      ])
  }
  json.Object(case required.state {
    None -> fields
    Some(state) -> list.append(fields, [#("requestState", json.String(state))])
  })
}

/// Decodes a suspension before constructing a continuation.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.decode(json.Object([#("resultType", json.String("input_required"))])) |> result.is_error
/// ```
pub fn decode(value: JsonValue) -> Result(Required, String) {
  use fields <- result.try(object(value))
  use Nil <- result.try(case list.key_find(fields, "resultType") {
    Ok(json.String("input_required")) -> Ok(Nil)
    _ -> Error("MRTR resultType must be input_required")
  })
  use requests <- result.try(case list.key_find(fields, "inputRequests") {
    Error(Nil) -> Ok(None)
    Ok(value) -> {
      use entries <- result.try(object(value))
      list.try_map(entries, decode_input) |> result.map(Some)
    }
  })
  use state <- result.try(optional_state(fields))
  required(requests, state)
}

/// Decodes requestState and inputResponses from a resumed request object.
///
/// ## Examples
///
/// ```gleam
/// assert mrtr.context(json.Object([])) == Ok(mrtr.Context(None, None))
/// ```
pub fn context(params: JsonValue) -> Result(Context, String) {
  // A resumed server request supplies untrusted bytes. Shape admission leaves
  // state integrity, freshness and provider-result meaning with the handler.

  use fields <- result.try(object(params))
  use state <- result.try(optional_state(fields))
  use responses <- result.try(case list.key_find(fields, "inputResponses") {
    Error(Nil) -> Ok(None)
    Ok(json.Object(values) as value) -> {
      use Nil <- result.try(
        validate_keys(list.map(values, fn(pair) { pair.0 })),
      )
      use Nil <- result.try(
        list.try_each(values, fn(pair) {
          case pair.1 {
            json.Object(_) -> Ok(Nil)
            _ -> Error("input responses must be objects")
          }
        }),
      )
      Ok(Some(value))
    }
    Ok(_) -> Error("inputResponses must be an object")
  })
  Ok(Context(state, responses))
}

fn decode_input(
  entry: #(String, JsonValue),
) -> Result(#(String, InputRequest), String) {
  use fields <- result.try(object(entry.1))
  use method <- result.try(case list.key_find(fields, "method") {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("input request method must be a string")
  })
  use params <- result.try(
    list.key_find(fields, "params")
    |> result.replace_error("input request params are missing"),
  )
  input_request(method, params) |> result.map(fn(input) { #(entry.0, input) })
}

fn optional_state(
  fields: List(#(String, JsonValue)),
) -> Result(Option(String), String) {
  case list.key_find(fields, "requestState") {
    Error(Nil) -> Ok(None)
    Ok(json.String(state)) -> Ok(Some(state))
    _ -> Error("requestState must be a string")
  }
}

fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("MRTR payload must be an object")
  }
}

fn validate_keys(keys: List(String)) -> Result(Nil, String) {
  case list.length(keys) > 32 {
    True -> Error("MRTR input map exceeds 32 entries")
    False ->
      case list.length(list.unique(keys)) == list.length(keys) {
        True -> Ok(Nil)
        False -> Error("duplicate MRTR input key")
      }
  }
}

/// Returns the optional provider method without permitting invalid construction.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(input) = mrtr.input_request("roots/list", json.Object([]))
/// assert mrtr.method(input) == "roots/list"
/// ```
pub fn method(input: InputRequest) -> String {
  input.method
}

/// Returns preserved provider parameters for explicit caller handling.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(input) = mrtr.input_request("roots/list", json.Object([]))
/// assert mrtr.params(input) == json.Object([])
/// ```
pub fn params(input: InputRequest) -> JsonValue {
  input.params
}
