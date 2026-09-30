//// A codec couples typed values to one compiled schema in both directions.
//// Custom callbacks cannot bypass that schema: encoding validates the emitted
//// JSON, and decoding validates JSON before the typed callback sees it.

import gleam/list
import gleam/result
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/schema.{type Schema, type SchemaError}

/// A typed, schema-checked encoder and decoder.
pub opaque type Codec(a) {
  Codec(
    schema: Schema,
    encoder: fn(a) -> JsonValue,
    decoder: fn(JsonValue) -> Result(a, String),
  )
}

/// Constructs a codec whose custom callbacks remain inside the schema boundary.
///
/// ## Examples
///
/// ```gleam
/// // codec.new(compiled, encode_record, decode_record)
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
/// // codec.schema(arguments) is the tool input schema.
/// ```
pub fn schema(codec: Codec(a)) -> Schema {
  codec.schema
}

/// Encodes a typed value and validates the callback's emitted JSON.
///
/// ## Examples
///
/// ```gleam
/// // codec.encode(arguments, input) fails before transport admission on mismatch.
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
/// // codec.decode(result_codec, received) checks schema and domain invariants.
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
/// // codec.with_decoder(output, fn(value) { decode_selected_label(original_args, value) })
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
/// // codec.map(text, unwrap_name, validated_name)
/// ```
pub fn map(
  codec: Codec(a),
  encode: fn(b) -> a,
  decode: fn(a) -> Result(b, String),
) -> Codec(b) {
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
/// // codec.json(compiled) preserves arbitrary JSON while checking the schema.
/// ```
pub fn json(schema: Schema) -> Codec(JsonValue) {
  new(schema, fn(value) { value }, Ok)
}

/// Constructs the built-in string codec.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(text) = codec.string()
/// // assert codec.encode(text, "hello") == Ok(json.String("hello"))
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
/// // let assert Ok(integer) = codec.int()
/// // assert codec.decode(integer, json.Int(4)) == Ok(4)
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
/// // codec.list(text) accepts only arrays of strings.
/// ```
pub fn list(element: Codec(a)) -> Result(Codec(List(a)), SchemaError) {
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
