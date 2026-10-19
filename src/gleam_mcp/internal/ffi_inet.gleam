//// Glisten panics on an unparsable interface, and its own parser is private.
//// Neither stdlib nor gleam_erlang decodes textual IPv4 or IPv6 addresses.
//// This binding exposes OTP's strict literal parser so server_http can refuse
//// syntactically malformed address as a value before any listener starts. It
//// can't tell whether the host owns the address; start reports that failure.
////
//// ## Flow
////
//// is_literal passes the text to inet:parse_strict_address and reports only
//// whether it names one IPv4 or IPv6 address. Host names and abbreviated IPv4
//// forms are refused, and no name resolution or socket effect occurs.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/charlist.{type Charlist}
import gleam/result

@external(erlang, "inet", "parse_strict_address")
fn parse_strict_address(address: Charlist) -> Result(Dynamic, Dynamic)

/// Reports whether the text is a literal IPv4 or IPv6 address.
///
/// ## Examples
///
/// `is_literal("10.0.0.5")` is True; `is_literal("localhost")` is False.
pub fn is_literal(address: String) -> Bool {
  charlist.from_string(address)
  |> parse_strict_address
  |> result.is_ok
}
