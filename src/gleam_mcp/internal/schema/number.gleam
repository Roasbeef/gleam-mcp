//// Decimal arithmetic preserves JSON Schema's mathematical number semantics.
//// Floats are interpreted through their shortest decimal rendering, so a
//// decimal multiple such as 0.0075 / 0.0001 does not acquire a binary remainder.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam_mcp/json.{type JsonValue}

/// A decimal numerator divided by a positive power of ten.
pub type Decimal {
  /// The exact rational representation of a rendered JSON number.
  Decimal(
    /// The signed integer coefficient.
    numerator: Int,
    /// A positive power of ten.
    denominator: Int,
  )
}

/// Converts JSON numbers to their decimal ratio.
///
/// ## Examples
///
/// ```gleam
/// assert number.from_json(json.Int(2)) == Ok(number.Decimal(2, 1))
/// ```
pub fn from_json(value: JsonValue) -> Result(Decimal, Nil) {
  case value {
    json.Int(value) -> Ok(Decimal(value, 1))
    json.Float(value) -> from_text(float.to_string(value))
    _ -> Error(Nil)
  }
}

fn from_text(text: String) -> Result(Decimal, Nil) {
  let parts = string.split(string.lowercase(text), "e")
  let mantissa = list.first(parts) |> result.unwrap("0")
  let exponent =
    list.first(list.drop(parts, 1)) |> result.try(int.parse) |> result.unwrap(0)
  let digits = string.replace(mantissa, ".", "")
  let fraction =
    string.split(mantissa, ".")
    |> list.drop(1)
    |> list.first
    |> result.unwrap("")
  use numerator <- result.try(int.parse(digits))
  let scale = string.length(fraction) - exponent
  case scale >= 0 {
    True -> Ok(Decimal(numerator, power10(scale)))
    False -> Ok(Decimal(numerator * power10(0 - scale), 1))
  }
}

fn power10(exponent: Int) -> Int {
  case exponent {
    0 -> 1
    _ -> 10 * power10(exponent - 1)
  }
}

/// Compares numbers without rounding integer magnitudes through floating point.
///
/// ## Examples
///
/// ```gleam
/// assert number.compare(json.Int(1), json.Float(1.0)) == Ok(0)
/// ```
pub fn compare(left: JsonValue, right: JsonValue) -> Result(Int, Nil) {
  use left <- result.try(from_json(left))
  use right <- result.try(from_json(right))
  let difference =
    left.numerator * right.denominator - right.numerator * left.denominator
  case difference {
    0 -> Ok(0)
    n if n < 0 -> Ok(-1)
    _ -> Ok(1)
  }
}

/// Tests mathematical integrality, including floating point representations.
///
/// ## Examples
///
/// ```gleam
/// assert number.is_integer(json.Float(2.0))
/// ```
pub fn is_integer(value: JsonValue) -> Bool {
  case from_json(value) {
    Ok(Decimal(n, d)) -> n % d == 0
    Error(_) -> False
  }
}

/// Tests exact decimal divisibility by a positive divisor.
///
/// ## Examples
///
/// ```gleam
/// assert number.multiple(json.Float(0.0075), json.Float(0.0001))
/// ```
pub fn multiple(value: JsonValue, divisor: JsonValue) -> Bool {
  case from_json(value), from_json(divisor) {
    Ok(Decimal(n, d)), Ok(Decimal(m, e)) if m > 0 -> n * e % { d * m } == 0
    _, _ -> False
  }
}
