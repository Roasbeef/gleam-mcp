//// Discovery describes installed server behavior without opening a session.
//// Cache hints are data for caller-owned caches. A private hint never permits
//// reuse across authorization contexts, and a zero TTL is immediately stale.
////
//// ## Flow
////
//// cache_hint and stale construct freshness values; cache_fields serializes them.
//// decode -> decode_cache validates a peer's discovery result, preserving optional
//// instructions and raw capabilities. No clock or cache lives here: the consumer
//// chooses storage, expiry and separation between authenticated principals.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/json.{type JsonValue}

/// The authorization scope in which a response may be reused.
pub type CacheScope {
  /// The response is suitable for reuse across authorization contexts.
  Public

  /// The response may be reused only in its original authorization context.
  Private
}

/// A nonnegative freshness hint paired with an explicit cache scope.
pub opaque type CacheHint {
  /// The validated freshness hint; it stores no clock or cached response.
  CacheHint(
    /// The admitted nonnegative freshness duration, preserving fractional wire values.
    ttl_ms: Float,
    /// The authorization contexts in which a consumer may reuse this result.
    scope: CacheScope,
  )
}

/// A modern discovery result with optional server-authored guidance.
pub type Discovery {
  /// The validated discovery result with caller-owned caching hints.
  Discovery(
    /// Protocol contracts the server implements.
    supported_versions: List(String),
    /// Advertised behavior derived from installed handlers.
    capabilities: JsonValue,
    /// Caller-owned guidance; receiving it does not grant trust.
    instructions: Option(String),
    /// Freshness and authorization scope for this result.
    cache: CacheHint,
  )
}

/// Builds a cache hint, refusing negative TTLs.
///
/// ## Examples
///
/// ```gleam
/// assert discovery.cache_hint(0, discovery.Private) |> result.is_ok
/// ```
pub fn cache_hint(ttl_ms: Int, scope: CacheScope) -> Result(CacheHint, String) {
  case ttl_ms >= 0 && ttl_ms <= 9_007_199_254_740_991 {
    True -> Ok(CacheHint(int.to_float(ttl_ms), scope))
    False -> Error("ttlMs must be a nonnegative safely representable duration")
  }
}

/// Returns a conservative hint that requires fresh reads within one principal.
///
/// ## Examples
///
/// ```gleam
/// assert discovery.ttl_ms(discovery.stale()) == 0.0
/// ```
pub fn stale() -> CacheHint {
  CacheHint(0.0, Private)
}

/// Returns the freshness lifetime in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// assert discovery.ttl_ms(discovery.stale()) == 0.0
/// ```
pub fn ttl_ms(hint: CacheHint) -> Float {
  hint.ttl_ms
}

/// Returns the authorization boundary attached to this cache hint.
///
/// ## Examples
///
/// ```gleam
/// assert discovery.cache_scope(discovery.stale()) == discovery.Private
/// ```
pub fn cache_scope(hint: CacheHint) -> CacheScope {
  hint.scope
}

/// Encodes the mandatory modern cache fields.
///
/// ## Examples
///
/// ```gleam
/// assert discovery.cache_fields(discovery.stale()) == [
///   #("ttlMs", json.Float(0.0)),
///   #("cacheScope", json.String("private")),
/// ]
/// ```
pub fn cache_fields(hint: CacheHint) -> List(#(String, JsonValue)) {
  [
    #("ttlMs", json.Float(hint.ttl_ms)),
    #(
      "cacheScope",
      json.String(case hint.scope {
        Public -> "public"
        Private -> "private"
      }),
    ),
  ]
}

/// Decodes both mandatory cache fields without assigning an implicit scope.
///
/// ## Examples
///
/// ```gleam
/// assert discovery.decode_cache(json.Object([])) |> result.is_error
/// ```
pub fn decode_cache(value: JsonValue) -> Result(CacheHint, String) {
  use fields <- result.try(object(value))
  use ttl <- result.try(case list.key_find(fields, "ttlMs") {
    Ok(json.Int(value)) if value >= 0 && value <= 9_007_199_254_740_991 ->
      Ok(int.to_float(value))
    Ok(json.Float(value)) if value >=. 0.0 -> Ok(value)
    _ -> Error("ttlMs must be a nonnegative number")
  })
  use scope <- result.try(case list.key_find(fields, "cacheScope") {
    Ok(json.String("public")) -> Ok(Public)
    Ok(json.String("private")) -> Ok(Private)
    _ -> Error("cacheScope must be public or private")
  })
  Ok(CacheHint(ttl, scope))
}

/// Decodes a modern discovery result and its required result discriminator.
///
/// ## Examples
///
/// ```gleam
/// // discovery.decode(result) refuses absent resultType on a modern response.
/// ```
pub fn decode(value: JsonValue) -> Result(Discovery, String) {
  use fields <- result.try(object(value))
  use Nil <- result.try(case list.key_find(fields, "resultType") {
    Ok(json.String("complete")) -> Ok(Nil)
    _ -> Error("discovery resultType must be complete")
  })
  use versions <- result.try(case list.key_find(fields, "supportedVersions") {
    Ok(json.Array(values)) ->
      list.try_map(values, fn(value) {
        case value {
          json.String(value) -> Ok(value)
          _ -> Error("supportedVersions must contain strings")
        }
      })
    _ -> Error("supportedVersions must be an array")
  })
  use capabilities <- result.try(case list.key_find(fields, "capabilities") {
    Ok(json.Object(_) as value) -> Ok(value)
    _ -> Error("capabilities must be an object")
  })
  use instructions <- result.try(case list.key_find(fields, "instructions") {
    Error(Nil) -> Ok(None)
    Ok(json.String(value)) -> Ok(Some(value))
    _ -> Error("instructions must be a string")
  })
  use cache <- result.try(decode_cache(value))
  Ok(Discovery(versions, capabilities, instructions, cache))
}

fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("result must be an object")
  }
}
