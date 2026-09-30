//// Shared JSON operations keep schema and instance equality independent of
//// textual property order and the parser's integer-versus-float representation.

import gleam/list
import gleam/result
import gleam_mcp/internal/schema/number
import gleam_mcp/json.{type JsonValue}

/// Reads an object's field without inventing an absent value.
///
/// ## Examples
///
/// ```gleam
/// assert value.get(json.Object([]), "type") == Error(Nil)
/// ```
pub fn get(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields) -> list.key_find(fields, key)
    _ -> Error(Nil)
  }
}

/// Reads an object field with a default chosen by its keyword semantics.
///
/// ## Examples
///
/// ```gleam
/// assert value.field(json.Object([]), "items", json.Bool(True)) == json.Bool(True)
/// ```
pub fn field(value: JsonValue, key: String, fallback: JsonValue) -> JsonValue {
  get(value, key) |> result.unwrap(fallback)
}

/// Compares JSON data structurally, including mathematical number equality.
///
/// ## Examples
///
/// ```gleam
/// assert value.equal(json.Int(1), json.Float(1.0))
/// ```
pub fn equal(left: JsonValue, right: JsonValue) -> Bool {
  case left, right {
    json.Object(a), json.Object(b) -> {
      list.length(a) == list.length(b)
      && list.all(a, fn(pair) {
        list.key_find(b, pair.0)
        |> result.map(fn(v) { equal(pair.1, v) })
        |> result.unwrap(False)
      })
    }
    json.Array(a), json.Array(b) -> {
      list.length(a) == list.length(b)
      && list.zip(a, b) |> list.all(fn(pair) { equal(pair.0, pair.1) })
    }
    json.Int(_), json.Float(_) | json.Float(_), json.Int(_) ->
      number.compare(left, right) == Ok(0)
    _, _ -> left == right
  }
}

/// Detects duplicates under JSON data equality.
///
/// ## Examples
///
/// ```gleam
/// assert value.unique([json.Int(1), json.Float(1.0)]) == False
/// ```
pub fn unique(values: List(JsonValue)) -> Bool {
  case values {
    [] -> True
    [first, ..rest] -> !list.any(rest, equal(first, _)) && unique(rest)
  }
}

/// Returns the entries of an object or an empty collection.
///
/// ## Examples
///
/// ```gleam
/// assert value.fields(json.Null) == []
/// ```
pub fn fields(value: JsonValue) -> List(#(String, JsonValue)) {
  case value {
    json.Object(fields) -> fields
    _ -> []
  }
}

/// Returns the members of an array or an empty collection.
///
/// ## Examples
///
/// ```gleam
/// assert value.items(json.Null) == []
/// ```
pub fn items(value: JsonValue) -> List(JsonValue) {
  case value {
    json.Array(items) -> items
    _ -> []
  }
}

/// Reads a zero-based list member.
///
/// ## Examples
///
/// ```gleam
/// assert value.at([10, 20], 1) == Ok(20)
/// ```
pub fn at(items: List(a), index: Int) -> Result(a, Nil) {
  case index < 0 {
    True -> Error(Nil)
    False -> items |> list.drop(index) |> list.first
  }
}
