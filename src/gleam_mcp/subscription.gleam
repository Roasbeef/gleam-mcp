//// Tools subscriptions opt in to notifications independently of a session.
//// An immutable registry has no list-change source, so its acknowledgement
//// contains an empty subset. The subscription remains open until cancellation,
//// graceful shutdown or transport closure, even when that subset is empty.
////
//// ## Flow
////
//// decode constructs a requested tools filter. stream starts without an accepted
//// subset; accept requires the matching acknowledgement first, then allows only
//// notifications from that accepted subset. complete requires an acknowledged
//// stream and matching id before admitting a final complete result. acknowledge
//// and closed construct the server's corresponding control messages.
////
//// | Stream state | Input | Result |
//// | --- | --- | --- |
//// | Unacknowledged | Matching acknowledgement with a requested subset | Store the subset. |
//// | Unacknowledged | Other notification or completion | Refuse. |
//// | Acknowledged | Matching admitted tool-list notification | Preserve state. |
//// | Acknowledged | Matching complete result | Permit transport retirement. |
////
//// The Stream validates values; the transport owns whether a worker is still live.
//// An empty accepted filter keeps that same lifetime without allowing tool events.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/jsonrpc.{type Id}

/// The notification source requested by a tools-only subscriber.
pub type ToolChanges {
  /// No tool-list notifications were requested.
  Omitted

  /// The client opted in to tool-list notifications.
  Requested
}

/// A validated tools filter, with other standardized filters unimplemented.
pub opaque type Filter {
  /// The tools notification subset admitted by this module.
  Filter(
    /// Whether tool-list change notifications were requested.
    tools: ToolChanges,
  )
}

/// Decodes notification opt-in while checking the shapes of known filters.
///
/// ## Examples
///
/// ```gleam
/// assert subscription.decode(json.Object([])) == Ok(subscription.empty())
/// ```
pub fn decode(value: JsonValue) -> Result(Filter, String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("notifications must be an object")
  })
  use Nil <- result.try(
    list.try_each(["promptsListChanged", "resourcesListChanged"], fn(name) {
      case list.key_find(fields, name) {
        Error(Nil) | Ok(json.Bool(_)) -> Ok(Nil)
        _ -> Error(name <> " must be a boolean")
      }
    }),
  )
  use Nil <- result.try(case list.key_find(fields, "resourceSubscriptions") {
    Error(Nil) -> Ok(Nil)
    Ok(json.Array(values)) ->
      list.try_each(values, fn(value) {
        case value {
          json.String(_) -> Ok(Nil)
          _ -> Error("resourceSubscriptions must contain strings")
        }
      })
    _ -> Error("resourceSubscriptions must be an array")
  })
  case list.key_find(fields, "toolsListChanged") {
    Error(Nil) | Ok(json.Bool(False)) -> Ok(Filter(Omitted))
    Ok(json.Bool(True)) -> Ok(Filter(Requested))
    _ -> Error("toolsListChanged must be a boolean")
  }
}

/// Returns a filter that opts in to tool-list changes.
///
/// ## Examples
///
/// ```gleam
/// assert subscription.value(subscription.tools()) == json.Object([#("toolsListChanged", json.Bool(True))])
/// ```
pub fn tools() -> Filter {
  Filter(Requested)
}

/// Returns a filter that requests no notification sources.
///
/// ## Examples
///
/// ```gleam
/// assert subscription.value(subscription.empty()) == json.Object([])
/// ```
pub fn empty() -> Filter {
  Filter(Omitted)
}

/// Encodes the caller's requested subset.
///
/// ## Examples
///
/// ```gleam
/// assert subscription.value(subscription.empty()) == json.Object([])
/// ```
pub fn value(filter: Filter) -> JsonValue {
  case filter.tools {
    Omitted -> json.Object([])
    Requested -> json.Object([#("toolsListChanged", json.Bool(True))])
  }
}

/// Encodes the first notification of an admitted subscription.
///
/// ## Examples
///
/// ```gleam
/// let id = jsonrpc.IdInt(1)
/// let pending = subscription.stream(id, subscription.tools())
/// assert subscription.accept(pending, subscription.acknowledge(id, subscription.empty()))
///   |> result.is_ok
/// ```
pub fn acknowledge(id: Id, accepted: Filter) -> JsonValue {
  jsonrpc.notification(
    "notifications/subscriptions/acknowledged",
    Some(
      json.Object([
        #("_meta", identity(id)),
        #("notifications", value(accepted)),
      ]),
    ),
  )
}

/// Encodes graceful subscription closure with the required id metadata.
///
/// ## Examples
///
/// ```gleam
/// // subscription.closed(id) is sent only after acknowledgement.
/// ```
pub fn closed(id: Id) -> JsonValue {
  jsonrpc.response(
    id,
    json.Object([
      #("resultType", json.String("complete")),
      #("_meta", identity(id)),
    ]),
  )
}

/// Decodes the stream identifier required on every subscription notification.
///
/// ## Examples
///
/// ```gleam
/// // subscription.notification_id(params) refuses notifications without stream identity.
/// ```
pub fn notification_id(params: JsonValue) -> Result(Id, String) {
  use fields <- result.try(case params {
    json.Object(fields) -> Ok(fields)
    _ -> Error("notification params must be an object")
  })
  use meta <- result.try(case list.key_find(fields, "_meta") {
    Ok(json.Object(fields)) -> Ok(fields)
    _ -> Error("subscription notification metadata is missing")
  })
  case list.key_find(meta, "io.modelcontextprotocol/subscriptionId") {
    Ok(json.Int(id)) -> Ok(jsonrpc.IdInt(id))
    Ok(json.String(id)) -> Ok(jsonrpc.IdString(id))
    _ -> Error("subscriptionId must be an integer or string")
  }
}

fn identity(id: Id) -> JsonValue {
  json.Object([
    #("io.modelcontextprotocol/subscriptionId", case id {
      jsonrpc.IdInt(value) -> json.Int(value)
      jsonrpc.IdString(value) -> json.String(value)
    }),
  ])
}

/// A stream's admitted notification subset and acknowledgement state.
pub opaque type Stream {
  /// The correlation identity, requested filter and acknowledgement state.
  Stream(
    /// The wire identity every acknowledgement, event and completion must match.
    id: Id,
    /// The caller's opt-in filter, fixed for this stream.
    requested: Filter,
    /// None before acknowledgement; afterwards the admitted subset of requested sources.
    accepted: Option(Filter),
  )
}

/// Starts validation before any notification observer can be invoked.
///
/// ## Examples
///
/// ```gleam
/// let pending = subscription.stream(jsonrpc.IdInt(1), subscription.tools())
/// assert subscription.complete(pending, json.Object([])) |> result.is_error
/// ```
pub fn stream(id: Id, requested: Filter) -> Stream {
  Stream(id, requested, None)
}

/// Validates ordering, correlation and the acknowledged notification subset.
///
/// ## Examples
///
/// ```gleam
/// // subscription.accept(stream, acknowledgement) admits its first notification.
/// ```
pub fn accept(
  stream: Stream,
  notification: JsonValue,
) -> Result(Stream, String) {
  // Correlation precedes every state change. None means no acknowledgement has
  // been admitted yet, while Some(filter) fixes the notification sources for
  // the remainder of this stream.

  use envelope <- result.try(
    jsonrpc.decode_value(notification)
    |> result.map_error(fn(_) { "invalid subscription notification" }),
  )
  use #(method, params) <- result.try(case envelope {
    jsonrpc.Correlated(jsonrpc.Notification(method, Some(params))) ->
      Ok(#(method, params))
    _ -> Error("subscription notification needs params")
  })
  use actual <- result.try(notification_id(params))
  use Nil <- result.try(case actual == stream.id {
    True -> Ok(Nil)
    False -> Error("subscription notification has another stream id")
  })
  case stream.accepted {
    None -> {
      use Nil <- result.try(case method {
        "notifications/subscriptions/acknowledged" -> Ok(Nil)
        _ -> Error("subscription notification preceded acknowledgement")
      })
      use raw <- result.try(case params {
        json.Object(fields) ->
          list.key_find(fields, "notifications")
          |> result.replace_error("acknowledgement has no notification subset")
        _ -> Error("acknowledgement must be an object")
      })
      use accepted <- result.try(acknowledged(raw))
      case accepted.tools == Requested && stream.requested.tools != Requested {
        True -> Error("subscription acknowledged an unrequested source")
        False -> Ok(Stream(..stream, accepted: Some(accepted)))
      }
    }
    Some(accepted) ->
      case
        method == "notifications/tools/list_changed"
        && accepted.tools == Requested
      {
        True -> Ok(stream)
        False -> Error("subscription emitted an unacknowledged source")
      }
  }
}

/// Validates graceful closure after acknowledgement with the same stream id.
///
/// ## Examples
///
/// ```gleam
/// // subscription.complete(stream, result) refuses closure before acknowledgement.
/// ```
pub fn complete(stream: Stream, result: JsonValue) -> Result(Nil, String) {
  use Nil <- result.try(case stream.accepted {
    None -> Error("subscription closed before acknowledgement")
    Some(_) -> Ok(Nil)
  })
  use actual <- result.try(notification_id(result))
  use Nil <- result.try(case result {
    json.Object(fields) ->
      case list.key_find(fields, "resultType") {
        Ok(json.String("complete")) -> Ok(Nil)
        _ -> Error("subscription closure resultType must be complete")
      }
    _ -> Error("subscription closure must be an object")
  })
  case actual == stream.id {
    True -> Ok(Nil)
    False -> Error("subscription closed with another stream id")
  }
}

/// Decodes the acknowledged tools-only subset without hiding other sources.
///
/// Unsupported optional sources cannot become live by appearing in an ack.
/// Their omitted, false and empty forms remain valid protocol subsets.
///
/// ## Examples
///
/// ```gleam
/// assert subscription.acknowledged(json.Object([])) == Ok(subscription.empty())
/// ```
pub fn acknowledged(value: JsonValue) -> Result(Filter, String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("acknowledged notifications must be an object")
  })
  use Nil <- result.try(
    list.try_each(["promptsListChanged", "resourcesListChanged"], fn(name) {
      case list.key_find(fields, name) {
        Error(Nil) | Ok(json.Bool(False)) -> Ok(Nil)
        _ ->
          Error("acknowledgement includes an unsupported notification source")
      }
    }),
  )
  use Nil <- result.try(case list.key_find(fields, "resourceSubscriptions") {
    Error(Nil) | Ok(json.Array([])) -> Ok(Nil)
    _ -> Error("acknowledgement includes unsupported resource subscriptions")
  })
  decode(value)
}
