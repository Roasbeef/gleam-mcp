//// Regression tests exercise admission, annotation ownership, and resource-safe
//// composition through the public schema boundary. The upstream suite is a
//// separate all-vector assertion; unsupported documents count as failures.

import gleam/list
import gleam/result
import gleam_mcp/json
import gleam_mcp/schema
import gleam_mcp/schema_conformance
import gleeunit/should

fn compile(source: String) -> schema.Schema {
  let assert Ok(value) = json.parse(source) as "test schema must parse"
  let assert Ok(compiled) = schema.new(value) as "test schema must compile"
  compiled
}

pub fn required_draft_2020_12_conformance_test() {
  let #(total, failures) = schema_conformance.run()
  total |> should.equal(1301)
  failures |> should.equal([])
}

pub fn admission_rejects_invalid_keyword_shapes_test() {
  [
    "{\"type\":\"strnig\"}",
    "{\"required\":[\"x\",\"x\"]}",
    "{\"items\":[{}]}",
    "{\"minimum\":\"zero\"}",
    "{\"multipleOf\":0}",
    "{\"properties\":{\"bad\":12}}",
    "{\"pattern\":\"[\"}",
    "{\"$id\":\"https://example.com/schema#anchor\"}",
  ]
  |> list.each(fn(source) {
    let assert Ok(value) = json.parse(source)
      as "malformed schema is valid JSON"
    schema.new(value) |> result.is_error |> should.be_true
  })
}

pub fn unsupported_dialect_is_explicit_test() {
  let data =
    json.Object([#("$schema", json.String("https://example.com/dialect"))])
  schema.new(data)
  |> should.equal(
    Error(schema.UnsupportedDialect("https://example.com/dialect")),
  )
}

pub fn unresolved_reference_is_not_fetched_test() {
  let data =
    json.Object([#("$ref", json.String("https://unreachable.invalid/schema"))])
  schema.new(data) |> result.is_error |> should.be_true
}

pub fn schema_round_trip_preserves_annotations_test() {
  let source =
    json.Object([
      #("x-vendor", json.Object([#("type", json.Int(123))])),
      #("type", json.String("integer")),
    ])
  let assert Ok(compiled) = schema.new(source)
    as "unknown annotations are permitted"
  schema.value(compiled) |> should.equal(source)
  schema.validate(compiled, json.Int(3)) |> should.equal(Ok(Nil))
}

pub fn decimal_multiple_is_mathematical_test() {
  let compiled = compile("{\"multipleOf\":0.0001}")
  schema.validate(compiled, json.Float(0.0075)) |> should.equal(Ok(Nil))
  schema.validate(compiled, json.Float(0.00751))
  |> result.is_error
  |> should.be_true
}

pub fn unicode_length_counts_codepoints_test() {
  let compiled = compile("{\"maxLength\":1}")
  schema.validate(compiled, json.String("😀")) |> should.equal(Ok(Nil))
  schema.validate(compiled, json.String("é"))
  |> result.is_error
  |> should.be_true
}

pub fn array_composition_preserves_local_refs_test() {
  let element =
    compile(
      "{\"$defs\":{\"scalar\":{\"type\":\"integer\"}},\"$ref\":\"#/$defs/scalar\"}",
    )
  let assert Ok(array) = schema.list(element)
    as "array wrapper must preserve local references"
  schema.validate(array, json.Array([json.Int(3)])) |> should.equal(Ok(Nil))
  schema.validate(array, json.Array([json.String("3")]))
  |> result.is_error
  |> should.be_true
  let assert Ok(nested) = schema.list(array) as "array wrapping must compose"
  schema.validate(nested, json.Array([json.Array([json.Int(3)])]))
  |> should.equal(Ok(Nil))
  schema.validate(nested, json.Array([json.Array([json.String("3")])]))
  |> result.is_error
  |> should.be_true
  schema.new(schema.value(nested)) |> result.is_ok |> should.be_true
}

pub fn array_composition_preserves_relative_root_id_test() {
  let element =
    compile(
      "{\"$id\":\"element\",\"$defs\":{\"scalar\":{\"type\":\"integer\"}},\"$ref\":\"#/$defs/scalar\"}",
    )
  let assert Ok(array) = schema.list(element)
    as "relative root identifiers must be resolved before nesting"
  schema.validate(array, json.Array([json.Int(3)])) |> should.equal(Ok(Nil))
  schema.validate(array, json.Array([json.String("3")]))
  |> result.is_error
  |> should.be_true
}

pub fn failed_alternatives_do_not_contribute_annotations_test() {
  let compiled =
    compile(
      "{\"anyOf\":[{\"properties\":{\"x\":true},\"required\":[\"missing\"]},{\"properties\":{\"y\":true}}],\"unevaluatedProperties\":false}",
    )
  schema.validate(compiled, json.Object([#("y", json.Int(3))]))
  |> should.equal(Ok(Nil))
  schema.validate(compiled, json.Object([#("x", json.Int(3))]))
  |> result.is_error
  |> should.be_true
}

pub fn reference_cycle_exhausts_allowance_test() {
  let compiled = compile("{\"$ref\":\"#\"}")
  schema.validate(compiled, json.Null)
  |> should.equal(Error(schema.ValidationLimitExceeded))
}

pub fn oversized_schema_is_refused_test() {
  let deep =
    list.repeat(Nil, 140)
    |> list.fold(json.Bool(True), fn(child, _) {
      json.Object([#("items", child)])
    })
  schema.new(deep) |> should.equal(Error(schema.SchemaLimitExceeded))
}

pub fn oversized_instance_is_refused_test() {
  let compiled = compile("true")
  let deep =
    list.repeat(Nil, 140)
    |> list.fold(json.Null, fn(child, _) { json.Array([child]) })
  schema.validate(compiled, deep)
  |> should.equal(Error(schema.ValidationLimitExceeded))
}

pub fn object_field_order_and_numeric_encoding_do_not_change_equality_test() {
  let compiled = compile("{\"const\":{\"a\":1,\"b\":2}}")
  schema.validate(
    compiled,
    json.Object([#("b", json.Float(2.0)), #("a", json.Float(1.0))]),
  )
  |> should.equal(Ok(Nil))
}

pub fn reference_targets_are_checked_even_in_unknown_annotation_locations_test() {
  let assert Ok(data) =
    json.parse("{\"$ref\":\"#/custom\",\"custom\":{\"type\":123}}")
    as "test schema must parse"
  schema.new(data) |> result.is_error |> should.be_true
}

pub fn nested_reference_targets_are_compiled_before_validation_test() {
  let compiled =
    compile(
      "{\"$ref\":\"#/custom\",\"custom\":{\"$ref\":\"#/other\"},\"other\":{\"type\":\"integer\"}}",
    )
  schema.validate(compiled, json.Int(3)) |> should.equal(Ok(Nil))
  schema.validate(compiled, json.String("3"))
  |> result.is_error
  |> should.be_true
}

pub fn duplicate_resource_identifiers_are_refused_test() {
  let assert Ok(data) =
    json.parse(
      "{\"$defs\":{\"a\":{\"$id\":\"https://example.com/a\",\"type\":\"string\"},\"b\":{\"$id\":\"https://example.com/a\",\"type\":\"integer\"}}}",
    )
    as "test schema must parse"
  schema.new(data) |> result.is_error |> should.be_true
}

pub fn quadratic_comparisons_spend_the_evaluation_allowance_test() {
  let compiled = compile("{\"uniqueItems\":true}")
  let items =
    list.repeat(Nil, 1000) |> list.index_map(fn(_, index) { json.Int(index) })
  schema.validate(compiled, json.Array(items))
  |> should.equal(Error(schema.ValidationLimitExceeded))
}

pub fn malformed_pointer_escape_is_refused_test() {
  let assert Ok(data) =
    json.parse("{\"$ref\":\"#/$defs/a~2b\",\"$defs\":{\"a~2b\":true}}")
    as "test schema must parse"
  schema.new(data) |> result.is_error |> should.be_true
}

pub fn dialect_declaration_requires_a_resource_root_test() {
  let assert Ok(data) =
    json.parse(
      "{\"items\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\"}}",
    )
    as "test schema must parse"
  schema.new(data) |> result.is_error |> should.be_true
}

fn regex(pattern: String) -> schema.Schema {
  let assert Ok(compiled) =
    schema.new(json.Object([#("pattern", json.String(pattern))]))
    as "supported pattern must compile"
  compiled
}

pub fn regex_shorthands_keep_ecmascript_ascii_meaning_test() {
  schema.validate(regex("^\\d$"), json.String("߀"))
  |> result.is_error
  |> should.be_true
  schema.validate(regex("^\\d$"), json.String("0")) |> should.equal(Ok(Nil))
  schema.validate(regex("^\\D$"), json.String("߀")) |> should.equal(Ok(Nil))
  schema.validate(regex("^\\w$"), json.String("é"))
  |> result.is_error
  |> should.be_true
  schema.validate(regex("^\\W$"), json.String("é")) |> should.equal(Ok(Nil))
  schema.validate(regex("^[\\d_]+$"), json.String("12_3"))
  |> should.equal(Ok(Nil))
}

pub fn regex_line_boundaries_and_unicode_whitespace_are_explicit_test() {
  schema.validate(regex("^abc$"), json.String("abc\n"))
  |> result.is_error
  |> should.be_true
  schema.validate(regex("^.$"), json.String("\r"))
  |> result.is_error
  |> should.be_true
  schema.validate(regex("^.$"), json.String("\u{2028}"))
  |> result.is_error
  |> should.be_true
  schema.validate(regex("^\\s$"), json.String("\u{FEFF}"))
  |> should.equal(Ok(Nil))
  schema.validate(regex("^\\S$"), json.String("\u{FEFF}"))
  |> result.is_error
  |> should.be_true
  schema.validate(regex("es"), json.String("expression"))
  |> should.equal(Ok(Nil))
}

pub fn regex_unicode_escapes_and_literal_backslashes_preserve_meaning_test() {
  schema.validate(regex("^\\u0061$"), json.String("a")) |> should.equal(Ok(Nil))
  schema.validate(regex("^\\u{1f600}$"), json.String("😀"))
  |> should.equal(Ok(Nil))
  schema.validate(regex("^\\\\p\\{Letter\\}$"), json.String("\\p{Letter}"))
  |> should.equal(Ok(Nil))
  schema.validate(regex("^\\p{Letter}+$"), json.String("π"))
  |> should.equal(Ok(Nil))
}

pub fn unsupported_regex_forms_fail_during_schema_construction_test() {
  [
    "(?i)word",
    "(?>atomic)",
    "(*SKIP)",
    "a++",
    "(a)\\1",
    "(?<name>a)",
    "[\\D_]",
    "\\p{Script=Greek}",
    "\\p{digit}",
    "\\A",
    "\\01",
    "\\u{+41}",
  ]
  |> list.each(fn(pattern) {
    schema.new(json.Object([#("pattern", json.String(pattern))]))
    |> result.is_error
    |> should.be_true
  })
}
