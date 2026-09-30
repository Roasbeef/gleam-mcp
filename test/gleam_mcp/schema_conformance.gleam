//// Runs every required upstream Draft 2020-12 vector against an offline registry.
//// Refusals are recorded as failures, including unsupported schemas: a skipped
//// dialect cannot silently turn into a conformance success.

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam_mcp/internal/schema/document
import gleam_mcp/internal/schema/evaluate
import gleam_mcp/internal/schema/value
import gleam_mcp/json
import simplifile

/// Prints a complete required-suite result without omitting rejected schemas.
///
/// ## Examples
///
/// ```sh
/// gleam run -m gleam_mcp/schema_conformance
/// ```
pub fn main() {
  let #(total, failures) = run()
  io.println(
    "Draft 2020-12: "
    <> int.to_string(total - list.length(failures))
    <> "/"
    <> int.to_string(total)
    <> " passed",
  )
  list.each(failures, io.println)
}

/// Returns the vector count and every failure for the ordinary test gate.
///
/// ## Examples
///
/// ```gleam
/// assert schema_conformance.run() == #(1301, [])
/// ```
pub fn run() -> #(Int, List(String)) {
  run_corpus("draft2020-12")
}

/// Probes optional capabilities without representing unsupported cases as passes.
///
/// ## Examples
///
/// ```gleam
/// // schema_conformance.run_optional() reports every optional vector verdict.
/// ```
pub fn run_optional() -> #(Int, List(String)) {
  run_corpus("optional")
}

fn run_corpus(corpus: String) -> #(Int, List(String)) {
  let base = "test/fixtures/json_schema/"
  let resources =
    files(base <> "remotes")
    |> list.filter_map(fn(path) {
      let relative = string.replace(path, base <> "remotes/", "")
      case
        string.starts_with(relative, "draft2020-12/")
        || !string.contains(relative, "/")
      {
        False -> Error(Nil)
        True ->
          load(path)
          |> result.map(fn(schema) {
            #("http://localhost:1234/" <> relative, schema)
          })
      }
    })
  let resources =
    list.filter(resources, fn(pair) {
      case value.get(pair.1, "$schema") {
        Ok(json.String("https://json-schema.org/draft/2020-12/schema"))
        | Error(_) -> True
        _ -> False
      }
    })
  files(base <> corpus)
  |> list.fold(#(0, []), fn(state, path) {
    let assert Ok(groups) = load(path) as "upstream fixture must parse"
    value.items(groups)
    |> list.fold(state, fn(state, group) {
      run_group(path, group, resources, state)
    })
  })
}

fn run_group(path, group, resources, state) {
  let schema = value.field(group, "schema", json.Bool(False))
  let compiled = document.new_with_resources(schema, resources)
  let title = label(group)
  value.field(group, "tests", json.Array([]))
  |> value.items
  |> list.fold(state, fn(state, vector) {
    let #(total, failures) = state
    let expected =
      value.field(vector, "valid", json.Bool(False)) == json.Bool(True)
    let instance = value.field(vector, "data", json.Null)
    let actual =
      compiled
      |> result.map(fn(schema) {
        evaluate.validate(schema, instance) |> result.is_ok
      })
    let prefix = path <> ": " <> title <> " / " <> label(vector)
    case actual {
      Ok(actual) if actual == expected -> #(total + 1, failures)
      Ok(_) -> #(total + 1, [prefix <> " [wrong verdict]", ..failures])
      Error(error) -> #(total + 1, [
        prefix <> " [compile: " <> string.inspect(error) <> "]",
        ..failures
      ])
    }
  })
}

fn label(object) {
  case value.get(object, "description") {
    Ok(json.String(label)) -> label
    _ -> "unnamed"
  }
}

fn load(path) {
  simplifile.read(path)
  |> result.map_error(fn(_) { Nil })
  |> result.try(fn(text) { json.parse(text) |> result.map_error(fn(_) { Nil }) })
}

fn files(path) {
  simplifile.read_directory(path)
  |> result.unwrap([])
  |> list.flat_map(fn(name) {
    let child = path <> "/" <> name
    case simplifile.is_directory(child) {
      Ok(True) -> files(child)
      _ ->
        case string.ends_with(child, ".json") {
          True -> [child]
          False -> []
        }
    }
  })
}
