//// A tool definition binds its wire name, schemas and typed codecs once.
//// Clients obtain result decoding from the same definition as argument
//// encoding. A result decoder may additionally capture the original arguments,
//// so request-specific invariants survive MRTR continuation unchanged.
////
//// ## Flow
////
//// new -> validate_name admits a wire name and an object argument schema, retaining
//// both typed codecs together. encode_arguments and decode_arguments use the input
//// codec; encode_output uses the output codec. result_codec binds decode_for to
//// this call's original typed arguments before the client starts an exchange.
////
//// with_result_decoder installs domain checks that a static schema cannot express,
//// such as an answer belonging to this request's allowed labels. It preserves the
//// output schema and encoder. A Tool(args, output) cannot be paired with another
//// argument type at a call site; opaque construction protects its name and codecs.

import gleam/list as gleam_list
import gleam/result
import gleam/string
import gleam_mcp/codec.{type Codec}
import gleam_mcp/json.{type JsonValue}
import gleam_mcp/schema.{type Schema}

/// One wire method's argument and output types, tied to its schemas.
pub opaque type Tool(args, output) {
  /// The admitted tool definition and callbacks retained as one value.
  Tool(
    /// The validated wire target, shared by client and server.
    name: String,
    /// Caller-authored discovery text; it carries no execution authority.
    description: String,
    /// The single schema-bound argument codec for args.
    arguments: Codec(args),
    /// The single schema-bound output codec for output.
    output: Codec(output),
    /// The domain decoder that receives this call's original typed arguments.
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
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert tool.name(definition) == "echo"
/// assert tool.new("bad name", "", codec.json(input), text) == Error(tool.InvalidName)
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
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// let checked = tool.with_result_decoder(definition, fn(_, value) {
///   case value {
///     json.String("allowed") -> Ok("allowed")
///     _ -> Error("answer is outside this request's domain")
///   }
/// })
/// assert codec.decode(tool.result_codec(checked, json.Object([])), json.String("other"))
///   == Error("answer is outside this request's domain")
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
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert tool.name(definition) == "echo"
/// ```
pub fn name(tool: Tool(args, output)) -> String {
  tool.name
}

/// Returns the caller-authored tool description.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert tool.description(definition) == "Echoes text."
/// ```
pub fn description(tool: Tool(args, output)) -> String {
  tool.description
}

/// Returns the input schema tied to argument encoding and decoding.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert schema.value(tool.input_schema(definition)) == schema.value(input)
/// ```
pub fn input_schema(tool: Tool(args, output)) -> Schema {
  codec.schema(tool.arguments)
}

/// Returns the output schema tied to output encoding and decoding.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert schema.value(tool.output_schema(definition)) == schema.value(codec.schema(text))
/// ```
pub fn output_schema(tool: Tool(args, output)) -> Schema {
  codec.schema(tool.output)
}

/// Encodes arguments while enforcing the input schema.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert tool.encode_arguments(definition, json.Object([])) == Ok(json.Object([]))
/// assert tool.encode_arguments(definition, json.Null) |> result.is_error
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
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert tool.decode_arguments(definition, json.Object([])) == Ok(json.Object([]))
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
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert tool.encode_output(definition, "hello") == Ok(json.String("hello"))
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
/// let assert Ok(input) = schema.new(json.Object([#("type", json.String("object"))]))
/// let assert Ok(text) = codec.string()
/// let assert Ok(definition) = tool.new("echo", "Echoes text.", codec.json(input), text)
/// assert codec.decode(tool.result_codec(definition, json.Object([])), json.String("hello")) == Ok("hello")
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
