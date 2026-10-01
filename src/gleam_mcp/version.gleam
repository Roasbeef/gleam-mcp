//// Protocol revisions select a wire contract independently of the transport.
//// Legacy revisions retain initialization; the modern revision carries its
//// contract on each request and never needs connection-scoped negotiation.
////
//// ## Flow
////
//// decode maps a wire string to one supported Version; name maps it back without
//// losing the selected contract. supported lists both initialized compatibility
//// profiles and the modern per-request profile. is_modern selects lifecycle shape,
//// while the transport still controls which profiles it admits.

import gleam/list

/// Revisions for which this package implements the tools wire contract.
pub type Version {
  /// The original initialized tools protocol.
  V20241105

  /// The June initialized tools protocol used by existing consumers.
  V20250618

  /// The request-oriented protocol with discovery, MRTR and subscriptions.
  V20260728
}

/// Returns the exact revision label carried on the wire.
///
/// ## Examples
///
/// ```gleam
/// assert version.name(version.V20260728) == "2026-07-28"
/// ```
pub fn name(version: Version) -> String {
  case version {
    V20241105 -> "2024-11-05"
    V20250618 -> "2025-06-18"
    V20260728 -> "2026-07-28"
  }
}

/// Decodes a supported revision without silently substituting another contract.
///
/// ## Examples
///
/// ```gleam
/// assert version.decode("next") == Error("next")
/// ```
pub fn decode(value: String) -> Result(Version, String) {
  case value {
    "2024-11-05" -> Ok(V20241105)
    "2025-06-18" -> Ok(V20250618)
    "2026-07-28" -> Ok(V20260728)
    value -> Error(value)
  }
}

/// Lists supported contracts in preference order.
///
/// ## Examples
///
/// ```gleam
/// assert version.supported() |> list.first == Ok("2026-07-28")
/// ```
pub fn supported() -> List(String) {
  [V20260728, V20250618, V20241105] |> list.map(name)
}

/// Determines whether a revision carries metadata on every request.
///
/// ## Examples
///
/// ```gleam
/// assert version.is_modern(version.V20260728)
/// ```
pub fn is_modern(version: Version) -> Bool {
  version == V20260728
}
