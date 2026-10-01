//// Validated JSON Schema documents form the boundary around untrusted tool data.
//// Construction checks the dialect and compiles an offline resource registry.
//// Validation evaluates assertions and annotation coverage under a finite budget;
//// neither operation retrieves references from the network.
////
//// ## Flow
////
//// new -> document.new validates the schema and indexes offline resources.
//// validate -> evaluate.validate checks one instance under a fresh allowance.
//// list -> document.array_schema -> new embeds a compiled element without changing
//// the identity its local references address. Errors preserve construction refusal
//// versus instance refusal; formatting helpers omit the rejected instance value.
////
//// Schema is opaque so external callers cannot replace the admitted registry.
//// Logical work and recursion bounds constrain this evaluator; they don't imply a
//// native regex wall-clock deadline or support for every optional vocabulary.

import gleam/result
import gleam_mcp/internal/schema/document
import gleam_mcp/internal/schema/evaluate
import gleam_mcp/json.{type JsonValue}

/// A document admitted by the schema compiler and its offline reference registry.
pub opaque type Schema {
  /// The complete compiled document, hidden from external replacement.
  Schema(
    /// The schema and offline resources admitted together by compilation.
    document: document.Document,
  )
}

/// Why a schema could not be admitted.
pub type SchemaError {
  /// A keyword or reference violated the declared schema contract.
  InvalidSchema(
    /// The schema keyword or reference contract that failed.
    reason: String,
  )

  /// The document requires a dialect this validator does not implement.
  UnsupportedDialect(
    /// The unsupported schema dialect URI.
    dialect: String,
  )

  /// Compilation exceeded the bounded schema work allowance.
  SchemaLimitExceeded
}

/// Why an instance could not be admitted by a compiled schema.
pub type ValidationError {
  /// An assertion failed at the named instance path.
  InvalidInstance(
    /// The JSON pointer identifying the rejected instance location.
    path: String,
    /// The instance assertion that failed, without rejected payload data.
    reason: String,
  )

  /// Evaluation exhausted its work allowance or recursion bound.
  ValidationLimitExceeded
}

/// Compiles a Draft 2020-12 schema without network access.
///
/// ## Examples
///
/// ```gleam
/// assert schema.new(json.Bool(True)) |> result.is_ok
/// ```
pub fn new(value: JsonValue) -> Result(Schema, SchemaError) {
  document.new(value)
  |> result.map(Schema)
  |> result.map_error(fn(error) {
    case error {
      document.Invalid(reason) -> InvalidSchema(reason)
      document.Dialect(dialect) -> UnsupportedDialect(dialect)
      document.Limit -> SchemaLimitExceeded
    }
  })
}

/// Returns the original document, preserving annotations and unknown keywords.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(shape) = schema.new(json.Bool(True))
/// assert schema.value(shape) == json.Bool(True)
/// ```
pub fn value(schema: Schema) -> JsonValue {
  schema.document.root
}

/// Validates one JSON value under a bounded evaluation budget.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(shape) = schema.new(json.Bool(False))
/// assert schema.validate(shape, json.Null) |> result.is_error
/// ```
pub fn validate(
  schema: Schema,
  value: JsonValue,
) -> Result(Nil, ValidationError) {
  evaluate.validate(schema.document, value)
  |> result.map_error(fn(error) {
    case error {
      evaluate.Mismatch(path, reason) -> InvalidInstance(path, reason)
      evaluate.Limit -> ValidationLimitExceeded
    }
  })
}

/// Describes a schema refusal without including instance data.
///
/// ## Examples
///
/// ```gleam
/// assert schema.schema_error_message(schema.SchemaLimitExceeded)
///   == "schema complexity limit exceeded"
/// ```
pub fn schema_error_message(error: SchemaError) -> String {
  case error {
    InvalidSchema(reason) -> reason
    UnsupportedDialect(dialect) -> "unsupported schema dialect: " <> dialect
    SchemaLimitExceeded -> "schema complexity limit exceeded"
  }
}

/// Describes an instance refusal without echoing the rejected value.
///
/// ## Examples
///
/// ```gleam
/// assert schema.validation_error_message(schema.ValidationLimitExceeded)
///   == "schema evaluation limit exceeded"
/// ```
pub fn validation_error_message(error: ValidationError) -> String {
  case error {
    InvalidInstance(path, reason) -> path <> ": " <> reason
    ValidationLimitExceeded -> "schema evaluation limit exceeded"
  }
}

/// Wraps a schema in an array while preserving its reference resource identity.
/// The embedded root receives its compiled absolute identifier before nesting,
/// so document-local references continue to address the element schema.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = schema.new(json.Object([#("type", json.String("string"))]))
/// let assert Ok(texts) = schema.list(text)
/// assert schema.validate(texts, json.Array([json.String("hello")])) == Ok(Nil)
/// assert schema.validate(texts, json.Array([json.Int(1)])) |> result.is_error
/// ```
pub fn list(element: Schema) -> Result(Schema, SchemaError) {
  new(document.array_schema(element.document))
}
