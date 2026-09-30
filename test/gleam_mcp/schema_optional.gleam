//// Optional conformance is a visible capability probe, separate from the required
//// suite gate. Every unsupported schema remains in the failure list.

import gleam/int
import gleam/io
import gleam/list
import gleam_mcp/schema_conformance

/// Prints all optional-suite refusals and verdict mismatches.
///
/// ## Examples
///
/// ```sh
/// gleam run -m gleam_mcp/schema_optional
/// ```
pub fn main() {
  let #(total, failures) = schema_conformance.run_optional()
  io.println(
    "Draft 2020-12 optional: "
    <> int.to_string(total - list.length(failures))
    <> "/"
    <> int.to_string(total)
    <> " passed",
  )
  list.each(failures, io.println)
}
