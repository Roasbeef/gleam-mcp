//// Deterministic, Unicode-heavy JSON generation for roundtrip properties.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/json.{type JsonValue}

/// Pseudo-random generator state.
pub type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

/// Builds a seed from any integer.
pub fn seed(n: Int) -> Seed {
  Seed(state: int.bitwise_and(n, mask_64))
}

/// Draws the next 64-bit value.
pub fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, Seed(state:))
}

/// An inclusive integer range as a list. Requires `start <= stop`.
pub fn range(from start: Int, to stop: Int) -> List(Int) {
  int.range(from: start, to: stop + 1, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}

/// Draws an integer in `[min, max]`, both inclusive.
pub fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

/// Draws a boolean.
pub fn bool(seed: Seed) -> #(Bool, Seed) {
  let #(n, seed) = int_between(seed, 0, 1)
  #(n == 1, seed)
}

/// Draws `Some` of the generated value half the time.
pub fn option_of(
  seed: Seed,
  generate: fn(Seed) -> #(a, Seed),
) -> #(Option(a), Seed) {
  let #(present, seed) = bool(seed)
  case present {
    True -> {
      let #(value, seed) = generate(seed)
      #(Some(value), seed)
    }
    False -> #(None, seed)
  }
}

/// Draws a list of `count` generated values.
pub fn list_of(
  seed: Seed,
  count: Int,
  generate: fn(Seed) -> #(a, Seed),
) -> #(List(a), Seed) {
  list_of_loop(seed, count, generate, [])
}

fn list_of_loop(
  seed: Seed,
  remaining: Int,
  generate: fn(Seed) -> #(a, Seed),
  accumulator: List(a),
) -> #(List(a), Seed) {
  case remaining <= 0 {
    True -> #(list.reverse(accumulator), seed)
    False -> {
      let #(value, seed) = generate(seed)
      list_of_loop(seed, remaining - 1, generate, [value, ..accumulator])
    }
  }
}

/// Picks one element of a non-empty list; the first is the fallback.
pub fn one_of(seed: Seed, choices: List(a), fallback: a) -> #(a, Seed) {
  let #(index, seed) = int_between(seed, 0, list.length(choices) - 1)
  case list.drop(choices, index) {
    [chosen, ..] -> #(chosen, seed)
    [] -> #(fallback, seed)
  }
}

// Deliberately unicode-heavy: ascii, escapes, accents, combining marks,
// CJK, and astral-plane emoji all appear in generated strings.
const palette = [
  "a", "Z", "0", "_", " ", "\"", "\\", "/", "\n", "\t", "\u{0001}", "é", "ß",
  "Ħ", "Ж", "š", "\u{0301}", "€", "こ", "漢", "中", "🌀", "😀", "🦊", "𝄞",
]

/// Draws a short string mixing ascii, escapes, and multi-byte codepoints.
pub fn small_string(seed: Seed) -> #(String, Seed) {
  let #(length, seed) = int_between(seed, 0, 12)
  let #(chunks, seed) =
    list_of(seed, length, fn(seed) { one_of(seed, palette, "a") })
  #(string.concat(chunks), seed)
}

/// Draws a finite float across many magnitudes.
pub fn float(seed: Seed) -> #(Float, Seed) {
  let #(mantissa, seed) = int_between(seed, -1_000_000_000, 1_000_000_000)
  let #(scale, seed) =
    one_of(seed, [1.0, 0.001, 1000.0, 0.0000001, 1.0e12], 1.0)
  #(int.to_float(mantissa) *. scale, seed)
}

/// Draws an arbitrary `JsonValue` with nesting bounded by `depth`.
pub fn json_value(seed: Seed, depth: Int) -> #(JsonValue, Seed) {
  let #(kind, seed) = case depth <= 0 {
    True -> int_between(seed, 0, 4)
    False -> int_between(seed, 0, 6)
  }
  case kind {
    0 -> #(json.Null, seed)
    1 -> {
      let #(flag, seed) = bool(seed)
      #(json.Bool(flag), seed)
    }
    2 -> {
      let #(value, seed) =
        int_between(seed, -9_007_199_254_740_991, 9_007_199_254_740_991)
      #(json.Int(value), seed)
    }
    3 -> {
      let #(value, seed) = float(seed)
      #(json.Float(value), seed)
    }
    4 -> {
      let #(value, seed) = small_string(seed)
      #(json.String(value), seed)
    }
    5 -> {
      let #(length, seed) = int_between(seed, 0, 4)
      let #(items, seed) =
        list_of(seed, length, fn(seed) { json_value(seed, depth - 1) })
      #(json.Array(items), seed)
    }
    _ -> {
      let #(length, seed) = int_between(seed, 0, 4)
      let #(fields, seed) =
        list_of(seed, length, fn(seed) {
          let #(name, seed) = small_string(seed)
          let #(value, seed) = json_value(seed, depth - 1)
          #(#(name, value), seed)
        })
      #(json.Object(unique_by_key(fields)), seed)
    }
  }
}

// Keeps the first entry per key: parsed documents never carry duplicate
// keys (`gleam_mcp/json.parse` reject them), so
// generated containers must not either, or roundtrips would fail.
fn unique_by_key(pairs: List(#(k, v))) -> List(#(k, v)) {
  unique_by_key_loop(pairs, [], [])
}

fn unique_by_key_loop(
  pairs: List(#(k, v)),
  seen: List(k),
  accumulator: List(#(k, v)),
) -> List(#(k, v)) {
  case pairs {
    [] -> list.reverse(accumulator)
    [#(key, value), ..rest] ->
      case list.contains(seen, key) {
        True -> unique_by_key_loop(rest, seen, accumulator)
        False ->
          unique_by_key_loop(rest, [key, ..seen], [#(key, value), ..accumulator])
      }
  }
}
