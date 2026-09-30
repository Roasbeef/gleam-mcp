//// A tool definition binds its wire name, schemas and typed codecs once.
//// Clients obtain result decoding from the same definition as argument
//// encoding. A result decoder may additionally capture the original arguments,
//// so request-specific invariants survive MRTR continuation unchanged.

import gleam/list as gleam_list
import gleam/result
import gleam/string
import gleam_mcp/codec.{type Codec}
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/schema.{type Schema}

/// One wire method's argument and output types, tied to its schemas.
pub opaque type Tool(args, output) {
  Tool(
    name: String,
    description: String,
    arguments: Codec(args),
    output: Codec(output),
    decode_for: fn(args, JsonValue) -> Result(output, String),
  )
}

/// Why a definition cannot become a tools/call target.
pub type DefinitionError {
  /// A tool name was empty, too long, or contained forbidden characters.
  InvalidName

  /// A tools/call input schema did not declare an object at its root.
  InvalidInputSchema
}

/// Constructs a definition with one argument codec and one output codec.
///
/// ## Examples
///
/// ```gleam
/// // tool.new("echo", "Echoes text.", arguments_codec, output_codec)
/// ```
pub fn new(
  name: String,
  description: String,
  arguments: Codec(args),
  output: Codec(output),
) -> Result(Tool(args, output), DefinitionError) {
  use Nil <- result.try(validate_name(name))
  use Nil <- result.try(case schema.value(codec.schema(arguments)) {
    json.Object(fields) ->
      case gleam_list.key_find(fields, "type") {
        Ok(json.String("object")) -> Ok(Nil)
        _ -> Error(InvalidInputSchema)
      }
    _ -> Error(InvalidInputSchema)
  })
  Ok(
    Tool(name, description, arguments, output, fn(_, value) {
      codec.decode(output, value)
    }),
  )
}

/// Binds output-domain validation to the exact original typed arguments.
///
/// The output schema is checked before this callback in both ordinary calls
/// and resumed calls. The callback cannot replace the output encoder or schema.
///
/// ## Examples
///
/// ```gleam
/// // definition |> tool.with_result_decoder(fn(args, result) { decode_choice(args.choices, result) })
/// ```
pub fn with_result_decoder(
  tool: Tool(args, output),
  decode: fn(args, JsonValue) -> Result(output, String),
) -> Tool(args, output) {
  Tool(..tool, decode_for: decode)
}

/// Returns the validated wire name.
///
/// ## Examples
///
/// ```gleam
/// // tool.name(definition) is used by both client and server.
/// ```
pub fn name(tool: Tool(args, output)) -> String {
  tool.name
}

/// Returns the caller-authored tool description.
///
/// ## Examples
///
/// ```gleam
/// // tool.description(definition) is included in tools/list.
/// ```
pub fn description(tool: Tool(args, output)) -> String {
  tool.description
}

/// Returns the input schema tied to argument encoding and decoding.
///
/// ## Examples
///
/// ```gleam
/// // tool.input_schema(definition) is passed to HTTP header admission.
/// ```
pub fn input_schema(tool: Tool(args, output)) -> Schema {
  codec.schema(tool.arguments)
}

/// Returns the output schema tied to output encoding and decoding.
///
/// ## Examples
///
/// ```gleam
/// // tool.output_schema(definition) may describe any JSON type.
/// ```
pub fn output_schema(tool: Tool(args, output)) -> Schema {
  codec.schema(tool.output)
}

/// Encodes arguments while enforcing the input schema.
///
/// ## Examples
///
/// ```gleam
/// // tool.encode_arguments(definition, args) runs before an HTTP request.
/// ```
pub fn encode_arguments(
  tool: Tool(args, output),
  args: args,
) -> Result(JsonValue, String) {
  codec.encode(tool.arguments, args)
}

/// Decodes admitted input into the handler's argument type.
///
/// ## Examples
///
/// ```gleam
/// // tool.decode_arguments(definition, raw) cannot return another tool's args.
/// ```
pub fn decode_arguments(
  tool: Tool(args, output),
  raw: JsonValue,
) -> Result(args, String) {
  codec.decode(tool.arguments, raw)
}

/// Encodes handler output while enforcing its declared output schema.
///
/// ## Examples
///
/// ```gleam
/// // tool.encode_output(definition, output) refuses a lying custom encoder.
/// ```
pub fn encode_output(
  tool: Tool(args, output),
  output: output,
) -> Result(JsonValue, String) {
  codec.encode(tool.output, output)
}

/// Returns the result codec bound to the original arguments.
///
/// ## Examples
///
/// ```gleam
/// // tool.result_codec(definition, args) is retained inside an opaque continuation.
/// ```
pub fn result_codec(tool: Tool(args, output), args: args) -> Codec(output) {
  codec.with_decoder(tool.output, tool.decode_for(args, _))
}

fn validate_name(name: String) -> Result(Nil, DefinitionError) {
  let valid_characters =
    string.to_graphemes(name)
    |> gleam_list.all(fn(character) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
        character,
      )
    })
  case
    string.length(name) > 0 && string.length(name) <= 128 && valid_characters
  {
    True -> Ok(Nil)
    False -> Error(InvalidName)
  }
}
