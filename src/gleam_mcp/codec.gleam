//// A codec couples typed values to one compiled schema in both directions.
//// Custom callbacks cannot bypass that schema: encoding validates the emitted
//// JSON, and decoding validates JSON before the typed callback sees it.
////
//// ## Flow
////
//// new stores a compiled schema with both callbacks. encode invokes the encoder,
//// then schema.validate checks its JSON. decode checks schema.validate first, then
//// invokes the decoder. with_decoder changes only the domain conversion; map wraps
//// both conversions while retaining the schema. list embeds the element schema
//// with its resource identity and maps the element callbacks.
////
//// Codec(a)'s type parameter ties both callbacks to the same Gleam value type. It
//// cannot prove that an application callback is pure, total or an inverse of the
//// other callback. Callers supply those properties; the wrapper checks JSON shape.

import gleam/list
import gleam/result
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/schema.{type Schema, type SchemaError}

/// A typed, schema-checked encoder and decoder.
pub opaque type Codec(a) {
  /// The schema and callbacks admitted as one typed boundary.
  Codec(
    /// The admitted structural contract used in both directions.
    schema: Schema,
    /// The caller's typed encoder; its emitted JSON still undergoes validation.
    encoder: fn(a) -> JsonValue,
    /// The caller's domain decoder, invoked only after schema admission.
    decoder: fn(JsonValue) -> Result(a, String),
  )
}

/// Constructs a codec whose custom callbacks remain inside the schema boundary.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(shape) = schema.new(json.Bool(True))
/// let raw = codec.new(shape, fn(value) { value }, Ok)
/// assert codec.decode(raw, json.Null) == Ok(json.Null)
/// ```
pub fn new(
  schema: Schema,
  encoder: fn(a) -> JsonValue,
  decoder: fn(JsonValue) -> Result(a, String),
) -> Codec(a) {
  Codec(schema, encoder, decoder)
}

/// Returns the compiled schema tied to this codec.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = codec.string()
/// assert schema.value(codec.schema(text)) == json.Object([#("type", json.String("string"))])
/// ```
pub fn schema(codec: Codec(a)) -> Schema {
  codec.schema
}

/// Encodes a typed value and validates the callback's emitted JSON.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = codec.string()
/// assert codec.encode(text, "hello") == Ok(json.String("hello"))
/// ```
pub fn encode(codec: Codec(a), value: a) -> Result(JsonValue, String) {
  let encoded = codec.encoder(value)
  use Nil <- result.try(
    schema.validate(codec.schema, encoded)
    |> result.map_error(schema.validation_error_message),
  )
  Ok(encoded)
}

/// Validates JSON before invoking the total typed decoder.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = codec.string()
/// assert codec.decode(text, json.String("hello")) == Ok("hello")
/// assert codec.decode(text, json.Int(1)) |> result.is_error
/// ```
pub fn decode(codec: Codec(a), value: JsonValue) -> Result(a, String) {
  use Nil <- result.try(
    schema.validate(codec.schema, value)
    |> result.map_error(schema.validation_error_message),
  )
  codec.decoder(value)
}

/// Replaces only typed decoding while preserving schema and emitted validation.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = codec.string()
/// let refused = codec.with_decoder(text, fn(_) { Error("outside the domain") })
/// assert codec.decode(refused, json.String("hello")) == Error("outside the domain")
/// assert codec.encode(refused, "hello") == Ok(json.String("hello"))
/// ```
pub fn with_decoder(
  codec: Codec(a),
  decoder: fn(JsonValue) -> Result(a, String),
) -> Codec(a) {
  Codec(..codec, decoder:)
}

/// Maps a codec through a caller's total domain conversion.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(integer) = codec.int()
/// let counted = codec.map(integer, fn(text) { int.parse(text) |> result.unwrap(0) }, fn(n) { Ok(int.to_string(n)) })
/// assert codec.decode(counted, json.Int(4)) == Ok("4")
/// ```
pub fn map(
  codec: Codec(a),
  encode: fn(b) -> a,
  decode: fn(a) -> Result(b, String),
) -> Codec(b) {
  // The mapped callbacks stay behind the original schema. The outer encode and
  // decode entry points still validate JSON before admitting it across the codec.

  new(codec.schema, fn(value) { codec.encoder(encode(value)) }, fn(value) {
    use decoded <- result.try(codec.decoder(value))
    decode(decoded)
  })
}

/// Constructs a JSON-preserving codec for an already compiled schema.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(shape) = schema.new(json.Bool(True))
/// assert codec.decode(codec.json(shape), json.Null) == Ok(json.Null)
/// ```
pub fn json(schema: Schema) -> Codec(JsonValue) {
  new(schema, fn(value) { value }, Ok)
}

/// Constructs the built-in string codec.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = codec.string()
/// assert codec.encode(text, "hello") == Ok(json.String("hello"))
/// ```
pub fn string() -> Result(Codec(String), SchemaError) {
  schema.new(json.Object([#("type", json.String("string"))]))
  |> result.map(fn(schema) {
    new(schema, json.String, fn(value) {
      case value {
        json.String(text) -> Ok(text)
        _ -> Error("expected a string")
      }
    })
  })
}

/// Constructs the built-in arbitrary-precision integer codec.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(integer) = codec.int()
/// assert codec.decode(integer, json.Int(4)) == Ok(4)
/// ```
pub fn int() -> Result(Codec(Int), SchemaError) {
  schema.new(json.Object([#("type", json.String("integer"))]))
  |> result.map(fn(schema) {
    new(schema, json.Int, fn(value) {
      case value {
        json.Int(number) -> Ok(number)
        _ -> Error("expected an integer")
      }
    })
  })
}

/// Constructs a list codec whose elements preserve their codec's contract.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = codec.string()
/// let assert Ok(texts) = codec.list(text)
/// assert codec.decode(texts, json.Array([json.String("hello")])) == Ok(["hello"])
/// ```
pub fn list(element: Codec(a)) -> Result(Codec(List(a)), SchemaError) {
  // The element's resource identity must survive array nesting or a local $ref
  // would address the new array root. schema.list performs that construction.

  schema.list(element.schema)
  |> result.map(fn(schema) {
    new(
      schema,
      fn(values) { json.Array(list.map(values, element.encoder)) },
      fn(value) {
        case value {
          json.Array(values) -> list.try_map(values, element.decoder)
          _ -> Error("expected an array")
        }
      },
    )
  })
}
